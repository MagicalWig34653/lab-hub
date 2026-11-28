import Vapor
import Fluent
import SQLKit
import HubCore

// Karte 3 (WP-D5b): Aufräumlauf für Objekte, die ein Absturz zwischen `put` und Commit (Upload, Import, Quelle, OCR, Export) ohne `files`-Zeile
// zurückließ, und für `tmp:`-Staging-Teile eines abgebrochenen `put`. Läuft als Teil von `dms.verify` je Mandant.
enum DMSOrphanSweep {
    /// Schonfrist in DB-Zeit: so lange gilt ein Objekt ohne `files`-Zeile als laufender Upload.
    static let graceSeconds = 24 * 3600

    struct Result: Codable, Sendable, Equatable {
        let blobs_removed: Int
        let staging_removed: Int
        /// Objekte ohne `files`-Zeile innerhalb der Schonfrist (oder nicht löschbar, weil inzwischen referenziert oder aufgefrischt).
        let pending: Int
    }

    /// `nil`, wenn der Speicher kein Aufräumen kennt. Jeder Kandidat wird in einer eigenen kurzen Transaktion unter der Blob-Sperre (dieselbe wie beim Anlegen
    /// der `files`-Zeile) erneut geprüft: keine `files`-Zeile und immer noch älter als die Schonfrist. Ein Upload, der gerade schreibt, ist jünger und bleibt.
    static func run(tenant: UUID, store: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore, on database: any Database) async throws -> Result? {
        let s = try sql(database)
        guard let sweepable = try store(s) as? any OrphanSweepableStore else { return nil }
        let found = try await sweepable.unreferencedObjects(tenant: tenant, graceSeconds: graceSeconds, on: s)
        var removed = 0
        for sha in found.stale {
            try Task.checkCancellation()
            let key = try ObjectKey(tenantID: tenant, sha256: sha)
            if try await dmsTransaction(database, { _, tx -> Bool in
                try await DMSUpload.lockBlob(tenant: tenant, sha256: sha, on: tx)
                guard try await tx.raw("SELECT 1 AS x FROM files WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: sha)").first() == nil,
                      let txStore = try store(tx) as? any OrphanSweepableStore else { return false }
                return try await txStore.deleteIfStale(key, graceSeconds: graceSeconds, on: tx)
            }) { removed += 1 }
        }
        let staging = try await sweepable.sweepStaging(tenant: tenant, graceSeconds: graceSeconds, on: s)
        return Result(blobs_removed: removed, staging_removed: staging, pending: found.young + found.stale.count - removed)
    }
}
