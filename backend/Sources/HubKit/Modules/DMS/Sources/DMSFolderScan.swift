import Vapor
import Fluent
import SQLKit
import Foundation
import NIOCore

// WP-D4: Job `dms.folder.scan` (Payload `{source_id, tenant_id}`). Der Ordner ist ein eingebundenes Volume NUR im Worker-Container (ADR 0003: kein Zustand im
// Backend-Container). Wurzel: `DMS_FOLDER_ROOT`; der Ordner einer Quelle liegt unter `<Wurzel>/<mandanten-uuid>/<config.path>` (ein Mandant erreicht so nie den Ordner
// eines anderen; Symlinks werden weder verfolgt noch aufgenommen; der aufgelöste Pfad muss unter der Mandantenwurzel liegen).
// Stabilitätsprüfung (MODUL-DMS AK-D3): Größe und mtime werden je Lauf gemessen und in `dms_folder_observations` festgehalten; eine Datei wird erst gelesen, wenn zwei
// aufeinanderfolgende Messungen gleich sind und die erste gleiche Messung mindestens `stable_seconds` (Datenbankzeit) zurückliegt. Während des Lesens wird erneut gemessen.
// Nach dem Commit wird die Datei nach `processed/` verschoben, nicht verarbeitbare (Typ, Größe) nach `failed/`; Quota-/Datenbankfehler lassen sie liegen (nächster Lauf).
// Absturz zwischen Commit und Verschieben: die Wiederholung findet den Idempotenz-Eintrag (Inhalts-Hash) und verschiebt nur noch.

enum DMSFolderScan {
    static let kind = "dms.folder.scan"
    static let maxFilesPerRun = 100
    static let reserved: Set<String> = ["processed", "failed"]

    static func handler(storeConfig: @escaping @Sendable () throws -> ObjectStoreConfig, root: String?, limits: DMSSourceLimits) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(DMSSources.SourcePayload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            guard let db = s as? any Database else { throw PermanentJobError(code: "database_unavailable") }
            let tenant = payload.tenant_id
            guard let source = try await DMSSources.row(payload.source_id, tenant: tenant, on: s), source.kind == .folder, source.enabled,
                  try await DMSSources.dmsActive(tenant: tenant, on: s) else { return }
            let config = try source.decode(FolderSourceConfig.self)
            var stats: [String: Int] = ["files": 0, "ingested": 0, "duplicates": 0, "waiting": 0, "failed": 0]
            var failure: String?
            do {
                guard let root, root.hasPrefix("/") else { throw ScanError("folder_root_missing") }
                try await scan(source: source, config: config, root: root, limits: limits, objectStore: try storeConfig(), db: db, s: s, stats: &stats, requestID: "folder-\(job.id.uuidString.prefix(8).lowercased())")
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as ScanError { failure = e.code
            } catch let e as HubError { failure = e.code == "storage_quota_exceeded" ? e.code : "ingest_failed"
            } catch { failure = "scan_failed" }
            let finalStats = stats, finalFailure = failure
            _ = try await dmsTransaction(db) { _, t in
                try await DMSSources.record(source.id, tenant: tenant, stats: finalStats, error: finalFailure, on: t)
                try await DMSSources.schedule(source: source.id, tenant: tenant, delaySeconds: finalFailure == nil ? config.interval_seconds : min(3600, config.interval_seconds * 4),
                                              expedite: false, afterJob: job.id, on: t)
                return 0
            }
        }
    }

    struct ScanError: Error { let code: String; init(_ c: String) { code = c } }

    /// Der Ordner der Quelle; nil, wenn er nicht existiert, kein Verzeichnis ist oder (nach Auflösen von Links) die Mandantenwurzel verlässt.
    static func resolve(root: String, tenant: UUID, path: String) -> URL? {
        let tenantRoot = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(tenant.uuidString.lowercased(), isDirectory: true).resolvingSymlinksInPath()
        let dir = tenantRoot.appendingPathComponent(path, isDirectory: true).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard dir.path.hasPrefix(tenantRoot.path + "/"), FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return dir
    }

    private struct Measure { let size: Int64; let mtimeMicros: Int64 }

    private static func measure(_ url: URL) -> Measure? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }   // nur reguläre Dateien, keine Links
        #if canImport(Darwin)
        let mtime = st.st_mtimespec
        #else
        let mtime = st.st_mtim
        #endif
        return Measure(size: Int64(st.st_size), mtimeMicros: Int64(mtime.tv_sec) * 1_000_000 + Int64(mtime.tv_nsec) / 1000)
    }

    private static func scan(source: DMSSourceRow, config: FolderSourceConfig, root: String, limits: DMSSourceLimits, objectStore: ObjectStoreConfig, db: any Database,
                             s: any SQLDatabase, stats: inout [String: Int], requestID: String) async throws {
        let tenant = source.tenant
        guard let dir = resolve(root: root, tenant: tenant, path: config.path) else { throw ScanError("folder_not_found") }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") && !reserved.contains($0) && $0.utf8.count <= 255 }.sorted()
        // Messungen von verschwundenen Dateien entfernen
        if names.isEmpty {
            try await s.raw("DELETE FROM dms_folder_observations WHERE tenant_id = \(bind: tenant) AND source_id = \(bind: source.id)").run()
        } else {
            try await s.raw("DELETE FROM dms_folder_observations WHERE tenant_id = \(bind: tenant) AND source_id = \(bind: source.id) AND rel_name NOT IN (\(binds: names))").run()
        }
        var handled = 0
        for name in names {
            try Task.checkCancellation()
            let url = dir.appendingPathComponent(name)
            guard let m = measure(url) else { continue }
            stats["files", default: 0] += 1
            // Messung vergleichen und festhalten (Zeit aus der Datenbank)
            let stable = try await s.raw("""
                WITH prev AS (SELECT size_bytes, mtime_us, first_seen_at FROM dms_folder_observations WHERE source_id = \(bind: source.id) AND rel_name = \(bind: name)),
                up AS (INSERT INTO dms_folder_observations (tenant_id, source_id, rel_name, size_bytes, mtime_us) VALUES (\(bind: tenant), \(bind: source.id), \(bind: name), \(bind: m.size), \(bind: m.mtimeMicros))
                       ON CONFLICT (source_id, rel_name) DO UPDATE SET size_bytes = EXCLUDED.size_bytes, mtime_us = EXCLUDED.mtime_us,
                         first_seen_at = CASE WHEN dms_folder_observations.size_bytes = EXCLUDED.size_bytes AND dms_folder_observations.mtime_us = EXCLUDED.mtime_us
                                              THEN dms_folder_observations.first_seen_at ELSE now() END
                       RETURNING 1)
                SELECT COALESCE((SELECT size_bytes = \(bind: m.size) AND mtime_us = \(bind: m.mtimeMicros) AND first_seen_at <= now() - make_interval(secs => \(bind: config.stable_seconds)) FROM prev), false) AS stable
                FROM (SELECT count(*) FROM up) forced
                """).first()?.decode(column: "stable", as: Bool.self) ?? false
            guard stable else { stats["waiting", default: 0] += 1; continue }
            guard handled < maxFilesPerRun else { stats["waiting", default: 0] += 1; continue }
            handled += 1

            if m.size > limits.maxUploadBytes { try move(url, into: dir, "failed"); stats["failed", default: 0] += 1; try await forget(name, source, s); continue }
            // O_NOFOLLOW: wird die Datei zwischen Messung und Öffnen durch einen Link ersetzt, scheitert das Öffnen (kein Lesen außerhalb des Ordners)
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { stats["waiting", default: 0] += 1; continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var head = Data()
            if let first = try? handle.read(upToCount: DMSFileKind.sniffLength) { head = first }
            guard let kind = DMSFileKind.sniff(Array(head)) else {
                try? handle.close()
                try move(url, into: dir, "failed"); stats["failed", default: 0] += 1; try await forget(name, source, s); continue
            }
            try? handle.seek(toOffset: 0)
            let box = UnsafeSendableBox(handle)
            let stream = ByteStream(unfolding: {
                guard let d = try box.value.read(upToCount: objectStoreChunkSize), !d.isEmpty else { try? box.value.close(); return nil }
                return ByteBuffer(data: d)
            })
            let cleaned = DMSSourceIngest.cleanName(name)
            let outcome: SourceIngestOutcome
            do {
                outcome = try await DMSSourceIngest.ingest(stream: stream, kind: kind, filename: cleaned, title: DMSSourceIngest.title(fromFilename: cleaned, fallback: "Dokument"),
                                                           itemKey: { DMSSourceIngest.itemKey("folder", $0) }, sender: nil, originRef: "folder:\(name)", source: source,
                                                           ingestSource: .folder, limits: limits, config: objectStore, requestID: requestID, db: db)
            } catch {
                try? box.value.close()
                throw error   // Quota, Datenbank: Datei bleibt liegen, nächster Lauf
            }
            try? box.value.close()
            // Hat sich die Datei während des Lesens verändert, wurde sie womöglich unvollständig gelesen: Messung zurücksetzen, nicht verschieben
            guard let after = measure(url), after.size == m.size, after.mtimeMicros == m.mtimeMicros else {
                try await s.raw("DELETE FROM dms_folder_observations WHERE source_id = \(bind: source.id) AND rel_name = \(bind: name)").run()
                stats["waiting", default: 0] += 1
                continue
            }
            switch outcome {
            case .ingested: stats["ingested", default: 0] += 1
            case .duplicate: stats["duplicates", default: 0] += 1
            case .unsupportedType, .tooLarge: stats["failed", default: 0] += 1; try move(url, into: dir, "failed"); try await forget(name, source, s); continue
            }
            try move(url, into: dir, "processed")
            try await forget(name, source, s)
        }
    }

    private static func forget(_ name: String, _ source: DMSSourceRow, _ s: any SQLDatabase) async throws {
        try await s.raw("DELETE FROM dms_folder_observations WHERE source_id = \(bind: source.id) AND rel_name = \(bind: name)").run()
    }

    /// Verschiebt in `processed/` oder `failed/` (Name bei Kollision mit Zeitstempel und Zufall ergänzt, nie überschreiben).
    private static func move(_ url: URL, into dir: URL, _ sub: String) throws {
        let fm = FileManager.default
        let target = dir.appendingPathComponent(sub, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var dest = target.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            let ext = url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            dest = target.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8).lowercased())" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        try fm.moveItem(at: url, to: dest)
    }
}
