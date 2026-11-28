import Foundation
import SQLKit

/// Karte 3 (WP-D5b): Ergebnis der Suche nach Objekten ohne `files`-Zeile.
package struct UnreferencedObjects: Sendable, Equatable {
    /// Hashes, deren letztes Schreiben (oder Dedup-`put`) länger als die Schonfrist zurückliegt.
    package var stale: [String]
    /// Jüngere Objekte ohne `files`-Zeile (laufende Uploads zwischen `put` und Commit, oder frisch verwaist).
    package var young: Int
}

/// Speicher, die verwaiste Objekte nach einem Absturz finden und löschen können. Zeit ist immer DB-Zeit (`now()`, ADR 0003); der Dateisystem-Speicher
/// vergleicht die Änderungszeit der Datei mit ihr (bei 24 h Schonfrist spielt Uhrabweichung keine Rolle). Ein Dedup-`put` frischt die Zeit auf, damit ein
/// laufender Upload, der auf einen alten verwaisten Blob trifft, ihn nicht verliert.
package protocol OrphanSweepableStore: ObjectStore {
    /// Objekte des Mandanten ohne `files`-Zeile (`tmp:`-Teile ausgenommen).
    func unreferencedObjects(tenant: UUID, graceSeconds: Int, on db: any SQLDatabase) async throws -> UnreferencedObjects
    /// Nur in der Transaktion des Aufrufers, nachdem er die Blob-Sperre genommen und geprüft hat, dass keine `files`-Zeile existiert: löscht das Objekt,
    /// wenn es noch älter als die Schonfrist ist. `true` = gelöscht.
    func deleteIfStale(_ key: ObjectKey, graceSeconds: Int, on db: any SQLDatabase) async throws -> Bool
    /// Löscht Staging-Teile, deren letztes Schreiben älter als die Schonfrist ist; liefert ihre Anzahl.
    func sweepStaging(tenant: UUID, graceSeconds: Int, on db: any SQLDatabase) async throws -> Int
}

extension PostgresObjectStore: OrphanSweepableStore {
    package func unreferencedObjects(tenant: UUID, graceSeconds: Int, on db: any SQLDatabase) async throws -> UnreferencedObjects {
        let rows = try await db.raw("""
            SELECT c.sha256, c.created_at < now() - \(bind: graceSeconds) * interval '1 second' AS stale FROM object_chunks c
            WHERE c.tenant_id = \(bind: tenant) AND c.seq = 0 AND c.sha256 NOT LIKE 'tmp:%'
              AND NOT EXISTS (SELECT 1 FROM files f WHERE f.tenant_id = c.tenant_id AND f.sha256 = c.sha256)
            ORDER BY c.sha256
            """).all()
        var out = UnreferencedObjects(stale: [], young: 0)
        for r in rows {
            if try r.decode(column: "stale", as: Bool.self) { out.stale.append(try r.decode(column: "sha256", as: String.self)) } else { out.young += 1 }
        }
        return out
    }

    package func deleteIfStale(_ key: ObjectKey, graceSeconds: Int, on db: any SQLDatabase) async throws -> Bool {
        // Zeilensperre auf Teil 0: ein gleichzeitiger Dedup-`put` (Auffrischen der Zeit) wartet und findet danach keine Zeile, schreibt also neu.
        guard let row = try await db.raw("""
            SELECT created_at < now() - \(bind: graceSeconds) * interval '1 second' AS stale FROM object_chunks
            WHERE tenant_id = \(bind: key.tenantID) AND sha256 = \(bind: key.sha256) AND seq = 0 FOR UPDATE
            """).first(), try row.decode(column: "stale", as: Bool.self) else { return false }
        try await db.raw("DELETE FROM object_chunks WHERE tenant_id = \(bind: key.tenantID) AND sha256 = \(bind: key.sha256)").run()
        return true
    }

    package func sweepStaging(tenant: UUID, graceSeconds: Int, on db: any SQLDatabase) async throws -> Int {
        let rows = try await db.raw("""
            DELETE FROM object_chunks c USING (
              SELECT sha256 FROM object_chunks WHERE tenant_id = \(bind: tenant) AND sha256 LIKE 'tmp:%'
              GROUP BY sha256 HAVING max(created_at) < now() - \(bind: graceSeconds) * interval '1 second') s
            WHERE c.tenant_id = \(bind: tenant) AND c.sha256 = s.sha256 RETURNING c.sha256
            """).all()
        return Set(try rows.map { try $0.decode(column: "sha256", as: String.self) }).count
    }
}

extension FilesystemObjectStore: OrphanSweepableStore {
    private func dbNow(_ db: any SQLDatabase) async throws -> Double {
        try await db.raw("SELECT extract(epoch FROM now())::float8 AS t").first()?.decode(column: "t", as: Double.self) ?? Date().timeIntervalSince1970
    }

    private func modified(_ path: String) -> Double? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }

    package func unreferencedObjects(tenant: UUID, graceSeconds: Int, on db: any SQLDatabase) async throws -> UnreferencedObjects {
        let dir = root.appendingPathComponent(tenant.uuidString.lowercased(), isDirectory: true)
        let cutoff = try await dbNow(db) - Double(graceSeconds)
        let referenced = Set(try await db.raw("SELECT sha256 FROM files WHERE tenant_id = \(bind: tenant)").all().map { try $0.decode(column: "sha256", as: String.self) })
        var out = UnreferencedObjects(stale: [], young: 0)
        let fm = FileManager.default
        for prefix in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
            for name in ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(prefix).path)) ?? []).sorted()
            where ObjectKey.isValidHash(name) && name.hasPrefix(prefix) && !referenced.contains(name) {
                guard let m = modified(dir.appendingPathComponent(prefix).appendingPathComponent(name).path) else { continue }
                if m < cutoff { out.stale.append(name) } else { out.young += 1 }
            }
        }
        return out
    }

    /// Ohne Zeilensperre: die Datei wird erst in den Staging-Ordner umbenannt und dort erneut geprüft. Ein Dedup-`put` vor dem Umbenennen hat die Zeit
    /// aufgefrischt (die Datei kommt zurück), eines danach findet keine Datei und legt die Bytes neu ab. Stirbt der Prozess dazwischen, räumt `sweepStaging` auf.
    package func deleteIfStale(_ key: ObjectKey, graceSeconds: Int, on db: any SQLDatabase) async throws -> Bool {
        let path = root.appendingPathComponent(key.path).path
        let cutoff = try await dbNow(db) - Double(graceSeconds)
        guard let m = modified(path), m < cutoff else { return false }
        try await beforeSweepRemoval?()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let removal = staging.appendingPathComponent("sweep-" + UUID().uuidString).path
        guard rename(path, removal) == 0 else { return false }
        if let now = modified(removal), now >= cutoff {
            // `rename` ersetzt eine inzwischen neu abgelegte Datei durch dieselben Bytes (inhaltsadressiert)
            guard rename(removal, path) == 0 else { throw ObjectStoreError.io("restore") }
            return false
        }
        try FileManager.default.removeItem(atPath: removal)
        return true
    }

    /// Der Staging-Ordner ist mandantenübergreifend (Namen ohne Mandant); alte Teile sind in jedem Fall tot und werden von jedem Lauf entfernt.
    package func sweepStaging(tenant: UUID, graceSeconds: Int, on db: any SQLDatabase) async throws -> Int {
        let dir = root.appendingPathComponent(".staging", isDirectory: true)
        let cutoff = try await dbNow(db) - Double(graceSeconds)
        var removed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let path = dir.appendingPathComponent(name).path
            guard let m = modified(path), m < cutoff else { continue }
            if (try? FileManager.default.removeItem(atPath: path)) != nil { removed += 1 }
        }
        return removed
    }
}
