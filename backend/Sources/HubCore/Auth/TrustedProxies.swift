import Vapor
import Foundation

// WP-H6: Vertrauensstellung zu Reverse Proxys für das Rate-Limit (K1-Befund 4). Standard: keine; dann zählt allein die Adresse der TCP-Verbindung.
// `X-Forwarded-For` wird nur ausgewertet, wenn die Verbindung von einer vertrauten Adresse (`TRUSTED_PROXIES`) kommt, und dann von rechts gelesen:
// der erste nicht vertraute Eintrag ist der Client (ein Angreifer kann nur links anhängen, nie rechts von einem vertrauten Proxy).

/// Liste vertrauter Proxy-Adressen/-Netze (`TRUSTED_PROXIES`, kommagetrennt, z. B. `10.0.0.0/8,fd00::/8,192.0.2.7`).
public struct TrustedProxies: Sendable, Equatable {
    struct Net: Sendable, Equatable { let bytes: [UInt8]; let prefix: Int }
    let nets: [Net]
    public static let none = TrustedProxies(nets: [])
    public var isEmpty: Bool { nets.isEmpty }

    /// Ungültige Einträge sind ein Konfigurationsfehler (kein stilles Ignorieren: sonst läuft das Rate-Limit unbemerkt mit falscher Vertrauensbasis).
    public static func parse(_ raw: String?) throws -> TrustedProxies {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        var nets: [Net] = []
        for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2, let bytes = addressBytes(pieces[0]) else { throw ConfigError(description: "TRUSTED_PROXIES: ungültiger Eintrag") }
            var prefix = bytes.count * 8
            if pieces.count == 2 {
                guard let p = Int(pieces[1]), (0...prefix).contains(p) else { throw ConfigError(description: "TRUSTED_PROXIES: ungültige Präfixlänge") }
                prefix = p
            }
            nets.append(Net(bytes: bytes, prefix: prefix))
        }
        return TrustedProxies(nets: nets)
    }

    /// Rohbytes einer IPv4-/IPv6-Adresse; IPv4-mapped IPv6 (`::ffff:a.b.c.d`) zählt als IPv4.
    static func addressBytes(_ s: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, s, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return Array(b[12...]) }
            return b
        }
        return nil
    }

    public func contains(_ address: String) -> Bool {
        guard let b = Self.addressBytes(address) else { return false }
        return nets.contains { net in
            guard net.bytes.count == b.count else { return false }
            let full = net.prefix / 8, rest = net.prefix % 8
            if full > 0, Array(b[0..<full]) != Array(net.bytes[0..<full]) { return false }
            if rest == 0 { return true }
            let mask = UInt8(truncatingIfNeeded: 0xff << (8 - rest))
            return (b[full] & mask) == (net.bytes[full] & mask)
        }
    }

    /// Client-Adresse für Limits: `peer` ist die Adresse der Verbindung. Nicht vertraute oder unbekannte Verbindung: immer `peer` (Header ignoriert).
    /// Vertraute Verbindung: `forwardedFor` (alle Werte des Headers) von rechts lesen, vertraute Proxys überspringen, erster anderer gültiger Eintrag gewinnt.
    /// Ungültiger Eintrag oder fehlender Header: `peer` (nie ein frei erfundener Schlüssel).
    public func client(peer: String?, forwardedFor: [String]) -> String {
        guard let peer else { return "unknown" }
        guard !nets.isEmpty, contains(peer) else { return peer }
        let hops = forwardedFor.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
        for hop in hops.reversed() {
            guard Self.addressBytes(hop) != nil else { return peer }
            if !contains(hop) { return hop }
        }
        return hops.first.flatMap { Self.addressBytes($0) != nil ? $0 : nil } ?? peer
    }
}

extension Request {
    /// Adresse des Clients unter Berücksichtigung vertrauter Proxys (`AuthSettings.trustedProxies`).
    var clientAddress: String {
        let trusted = application.authSettings?.trustedProxies ?? .none
        return trusted.client(peer: remoteAddress?.ipAddress, forwardedFor: headers[.xForwardedFor])
    }
}

extension HTTPHeaders.Name {
    static let xForwardedFor = HTTPHeaders.Name("X-Forwarded-For")
}
