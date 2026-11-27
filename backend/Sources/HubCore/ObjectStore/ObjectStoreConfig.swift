import Foundation
import SQLKit

/// Objektspeicher-Konfiguration aus der Umgebung (`OBJECT_STORE`, `OBJECT_STORE_FS_PATH`, `HUB_REPLICAS`; jeweils auch `_FILE`).
public struct ObjectStoreConfig: Sendable, Equatable {
    public var kind: ObjectStoreKind
    public var fsPath: String?
    public var replicas: Int

    public init(kind: ObjectStoreKind, fsPath: String? = nil, replicas: Int = 1) {
        self.kind = kind; self.fsPath = fsPath; self.replicas = replicas
    }

    /// Standard ohne Angabe: `db` (kleinste Installation; keine Container-Dateisystem-Zustände).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> ObjectStoreConfig {
        let raw = (try HubConfig.value("OBJECT_STORE", env) ?? "db").lowercased()
        guard let kind = ObjectStoreKind(rawValue: raw) else { throw ConfigError(description: "OBJECT_STORE muss fs, db oder s3 sein") }
        let reps = try HubConfig.value("HUB_REPLICAS", env).map { Int($0) } ?? 1
        guard let reps, reps >= 1 else { throw ConfigError(description: "HUB_REPLICAS ungültig") }
        return ObjectStoreConfig(kind: kind, fsPath: try HubConfig.value("OBJECT_STORE_FS_PATH", env), replicas: reps)
    }

    /// Wirft bei unbrauchbarer Konfiguration; liefert Warnungen für riskante, aber erlaubte Konfigurationen.
    public func validate() throws -> [String] {
        var warnings: [String] = []
        switch kind {
        case .fs:
            guard let p = fsPath, p.hasPrefix("/") else { throw ConfigError(description: "OBJECT_STORE=fs braucht OBJECT_STORE_FS_PATH (absoluter Pfad eines Volumes)") }
            if replicas > 1 {
                warnings.append("OBJECT_STORE=fs mit \(replicas) Repliken: Dateisystem-Speicher ist nur für einen einzelnen Host mit gemeinsamem Volume geeignet (ADR 0003); für Swarm S3 verwenden.")
            }
        case .db:
            break
        case .s3:
            throw ConfigError(description: "OBJECT_STORE=s3 ist noch nicht implementiert (WP-D1 offener Punkt)")
        }
        return warnings
    }

    public func makeStore(db: (any SQLDatabase)?) throws -> any ObjectStore {
        _ = try validate()
        switch kind {
        case .fs: return FilesystemObjectStore(root: URL(fileURLWithPath: fsPath!, isDirectory: true))
        case .db:
            guard let db else { throw ConfigError(description: "OBJECT_STORE=db braucht eine Datenbank") }
            return PostgresObjectStore(db)
        case .s3: throw ConfigError(description: "OBJECT_STORE=s3 ist noch nicht implementiert")
        }
    }
}
