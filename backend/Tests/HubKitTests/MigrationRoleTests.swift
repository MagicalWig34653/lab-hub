import XCTVapor
import Fluent
import FluentPostgresDriver
import SQLKit
@testable import HubKit

/// WP-H8: Alle Migrationen müssen mit einer normalen, nicht-privilegierten Einzelrolle laufen (so legt `deploy/setup.sh` die Datenbankrolle an:
/// `CREATE ROLE … LOGIN`, Eigentümerin einer leeren Datenbank). Die übrigen Datenbank-Tests laufen als Superuser und würden Rechtefehler nie zeigen
/// (Befund aus WP-F5: `dms_021_revision` scheiterte an `permission denied for table audit_log`, weil `018_audit_hardening` TRIGGER entzogen hatte).
/// Der Test legt Rolle und Datenbank selbst an (zufällige Namen und Passwort) und entfernt beides wieder. Er überspringt nur, wenn der Test-Benutzer
/// keine Rollen und Datenbanken anlegen darf. Nur synthetische Daten.
final class MigrationRoleTests: XCTestCase {
    private var admin: Application!
    private var adminSQL: (any SQLDatabase)!
    private var role = "", dbName = "", password = ""

    override func setUp() async throws {
        let suffix = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
        role = "lh_h8_role_\(suffix)"; dbName = "lh_h8_db_\(suffix)"
        password = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased()
        admin = try await Application.make(.testing)
        try configure(admin, environment: HubTestDB.env)
        adminSQL = (admin.db(.psql) as! any SQLDatabase)
        do { _ = try await adminSQL.raw("SELECT 1").all() } catch {
            try await admin.asyncShutdown(); admin = nil
            throw XCTSkip("Keine Postgres-Datenbank erreichbar")
        }
        let priv = try await adminSQL.raw("SELECT rolsuper AS su, rolcreaterole AS cr, rolcreatedb AS cdb FROM pg_roles WHERE rolname = current_user").first()
        let su = try priv?.decode(column: "su", as: Bool.self) ?? false
        let cr = try priv?.decode(column: "cr", as: Bool.self) ?? false
        let cdb = try priv?.decode(column: "cdb", as: Bool.self) ?? false
        guard su || (cr && cdb) else {
            try await admin.asyncShutdown(); admin = nil
            throw XCTSkip("Test-Benutzer darf keine Rollen/Datenbanken anlegen (CREATEROLE und CREATEDB nötig): Einzelrollen-Migrationstest übersprungen")
        }
        try await adminSQL.raw("CREATE ROLE \(unsafeRaw: role) LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '\(unsafeRaw: password)'").run()
        if !su { try await adminSQL.raw("GRANT \(unsafeRaw: role) TO CURRENT_USER").run() }
        try await adminSQL.raw("CREATE DATABASE \(unsafeRaw: dbName) OWNER \(unsafeRaw: role)").run()
    }

    override func tearDown() async throws {
        guard let admin else { return }
        _ = try? await adminSQL.raw("DROP DATABASE IF EXISTS \(unsafeRaw: dbName) WITH (FORCE)").run()
        _ = try? await adminSQL.raw("DROP ROLE IF EXISTS \(unsafeRaw: role)").run()
        try await admin.asyncShutdown()
    }

    private var roleEnv: [String: String] {
        var e = HubTestDB.env
        e["DB_NAME"] = dbName; e["DB_USER"] = role; e["DB_PASSWORD"] = password
        return e
    }

    /// Anwendung wie im Betrieb (alle Kern- und Modulmigrationen) mit der nicht-privilegierten Rolle.
    private func makeRoleApp() async throws -> (Application, any SQLDatabase) {
        let app = try await Application.make(.testing)
        try configure(app, environment: roleEnv)
        return (app, app.db(.psql) as! any SQLDatabase)
    }

    private func privilege(_ db: any SQLDatabase, _ p: String) async throws -> Bool {
        let row = try await db.raw("SELECT has_table_privilege(current_user, 'audit_log', \(literal: p)) AS v").first()
        return try XCTUnwrap(row).decode(column: "v", as: Bool.self)
    }

    func testRoleIsUnprivileged() async throws {
        let (app, db) = try await makeRoleApp()
        let first = try await db.raw("SELECT rolsuper AS su, rolcreatedb AS cdb, rolcreaterole AS cr FROM pg_roles WHERE rolname = current_user").first()
        let row = try XCTUnwrap(first)
        let flags = [try row.decode(column: "su", as: Bool.self), try row.decode(column: "cdb", as: Bool.self), try row.decode(column: "cr", as: Bool.self)]
        XCTAssertEqual(flags, [false, false, false], "Testrolle muss normal (nicht privilegiert) sein")
        try await app.asyncShutdown()
    }

    /// Frische Installation: alle Migrationen (Kern + DMS + …) mit einer Einzelrolle; Härtung bleibt für UPDATE/DELETE/TRUNCATE bestehen.
    func testFullMigrationRunsWithUnprivilegedSingleRole() async throws {
        let (app, db) = try await makeRoleApp()
        try await migrateWithLock(app)
        let current = await schemaIsCurrent(app); XCTAssertTrue(current)
        let upd = try await privilege(db, "UPDATE"), del = try await privilege(db, "DELETE"), trunc = try await privilege(db, "TRUNCATE")
        let trig = try await privilege(db, "TRIGGER"), ins = try await privilege(db, "INSERT"), sel = try await privilege(db, "SELECT")
        XCTAssertEqual([upd, del, trunc], [false, false, false], "H6-Härtung: kein UPDATE/DELETE/TRUNCATE auf audit_log")
        XCTAssertEqual([trig, ins, sel], [true, true, true])
        // zweite Schicht: der Trigger aus 011 und der DMS-Kettentrigger existieren
        let rows = try await db.raw("SELECT tgname FROM pg_trigger WHERE tgrelid = 'audit_log'::regclass AND NOT tgisinternal").all()
        let triggers = try rows.map { try $0.decode(column: "tgname", as: String.self) }
        XCTAssertTrue(triggers.contains("audit_log_no_change") && triggers.contains("audit_log_dms_chain"), "\(triggers)")
        // zweiter Lauf ist ein No-op
        try await migrateWithLock(app)
        try await app.asyncShutdown()
    }

    /// Bestehende Installation im Zustand nach `018_audit_hardening` (TRIGGER entzogen, nur Kernmigrationen bis 018): die Folgemigration repariert.
    func testInstallationAfter018MigratesWithUnprivilegedRole() async throws {
        let old = try await Application.make(.testing)
        let c = try XCTUnwrap(try HubConfig.fromEnvironment(roleEnv))
        old.databases.use(.postgres(configuration: SQLPostgresConfiguration(hostname: c.dbHost, port: c.dbPort, username: c.dbUser, password: c.dbPassword,
                                                                            database: c.dbName, tls: .disable)), as: .psql)
        let upToHardening = Array(HubMigrations.all.prefix { $0.name != "019_audit_trigger_privilege" })
        XCTAssertEqual(upToHardening.last?.name, "018_audit_hardening")
        old.migrations.add(upToHardening, to: .psql)
        try await old.autoMigrate()
        let oldDB = old.db(.psql) as! any SQLDatabase
        let hadTrigger = try await privilege(oldDB, "TRIGGER")
        XCTAssertFalse(hadTrigger, "Ausgangszustand nach 018 muss TRIGGER-los sein")
        try await old.asyncShutdown()

        let (app, db) = try await makeRoleApp()
        try await migrateWithLock(app)
        let current = await schemaIsCurrent(app); XCTAssertTrue(current)
        let trig = try await privilege(db, "TRIGGER"), upd = try await privilege(db, "UPDATE")
        XCTAssertTrue(trig); XCTAssertFalse(upd)
        try await app.asyncShutdown()
    }

    /// Revert von 019 stellt den Zustand nach 018 wieder her.
    func testRevertOf019RestoresState() async throws {
        let (app, db) = try await makeRoleApp()
        try await migrateWithLock(app)
        try await RestoreAuditTriggerPrivilege().revert(on: app.db(.psql))
        let trig = try await privilege(db, "TRIGGER"); XCTAssertFalse(trig)
        try await RestoreAuditTriggerPrivilege().prepare(on: app.db(.psql))
        let again = try await privilege(db, "TRIGGER"); XCTAssertTrue(again)
        try await app.asyncShutdown()
    }
}
