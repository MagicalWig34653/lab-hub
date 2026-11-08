import Foundation

public enum DBTLS: String, Sendable { case disable, require }

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
}

/// Konfiguration ausschließlich aus der Umgebung. Für jede Variable `NAME` gilt auch `NAME_FILE` (Docker-Secret);
/// `NAME_FILE` hat Vorrang. Werte von Geheimnissen erscheinen nie in Fehlermeldungen.
public struct HubConfig: Sendable {
    public var dbHost: String
    public var dbPort: Int
    public var dbName: String
    public var dbUser: String
    public var dbPassword: String
    public var dbTLS: DBTLS
    public var secretKey: String?
    public var autoMigrate: Bool
    public var publicURL: String?
    public var webAuthnRPID: String?
    /// Einmaliges Geheimnis für den ersten Nutzer (WP-K1). Ohne Wert gibt es kein Bootstrap-Fenster.
    public var setupToken: String?
    /// Vertraute Reverse Proxys für `X-Forwarded-For` (WP-H6, `TRUSTED_PROXIES`). Standard: keine.
    public var trustedProxies: TrustedProxies = .none

    public static func value(_ name: String, _ env: [String: String]) throws -> String? {
        if let path = env[name + "_FILE"], !path.isEmpty {
            guard let data = FileManager.default.contents(atPath: path), var s = String(data: data, encoding: .utf8) else {
                throw ConfigError(description: "\(name)_FILE nicht lesbar")
            }
            while s.last == "\n" || s.last == "\r" { s.removeLast() }
            return s
        }
        if let v = env[name], !v.isEmpty { return v }
        return nil
    }

    /// Gibt `nil` zurück, wenn `DB_HOST` fehlt (keine Datenbank konfiguriert).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> HubConfig? {
        guard let host = try value("DB_HOST", env) else { return nil }
        let port = try value("DB_PORT", env).map { Int($0) } ?? 5432
        guard let port, (1...65535).contains(port) else { throw ConfigError(description: "DB_PORT ungültig") }
        guard let password = try value("DB_PASSWORD", env) else { throw ConfigError(description: "DB_PASSWORD oder DB_PASSWORD_FILE fehlt") }
        let tlsRaw = try value("DB_TLS", env) ?? "require"
        let tls: DBTLS
        switch tlsRaw.lowercased() {
        case "disable", "off": tls = .disable
        case "require", "required": tls = .require
        default: throw ConfigError(description: "DB_TLS muss disable oder require sein")
        }
        let auto = (try value("AUTO_MIGRATE", env) ?? "false").lowercased()
        // WP-H10 (Befund 7): ein gesetzter, aber zu kurzer Schlüssel verhindert den Start (kein stiller Betrieb ohne Mail-/Import-Zugangsdaten, kein schwacher Schlüssel)
        if SecretBox.isTooShort(try value("SECRET_KEY", env)) { throw ConfigError(description: SecretBox.tooShortMessage) }
        var config = HubConfig(
            dbHost: host, dbPort: port,
            dbName: try value("DB_NAME", env) ?? "labhub",
            dbUser: try value("DB_USER", env) ?? "labhub",
            dbPassword: password, dbTLS: tls,
            secretKey: try value("SECRET_KEY", env),
            autoMigrate: ["1", "true", "yes"].contains(auto),
            publicURL: try value("PUBLIC_URL", env),
            webAuthnRPID: try value("WEBAUTHN_RP_ID", env),
            setupToken: try value("SETUP_TOKEN", env))
        config.trustedProxies = try TrustedProxies.parse(try value("TRUSTED_PROXIES", env))
        return config
    }
}
