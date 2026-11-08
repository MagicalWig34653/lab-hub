import Foundation
import NIOCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// WP-H10 (Befund 3): gemeinsame Zieladress-Prüfung für alle ausgehenden Verbindungen des Hubs zu vom Nutzer konfigurierten Zielen (Mail-Quelle D4, Paperless-Import D6).
// Regeln (SSRF-/Port-Scan-Schutz):
// - Standard „blockiere intern“: Loopback, private Netze (10/8, 172.16/12, 192.168/16), Link-Local inkl. Metadaten (169.254/16, fe80::/10), CGNAT (100.64/10), „this network“ (0/8),
//   Multicast/Reserviert, IPv6 ULA (fc00::/7), `::`, `::1` und IPv4-in-IPv6 (`::ffff:a.b.c.d`, NAT64 `64:ff9b::/96`, 6to4 `2002::/16`, IPv4-kompatibel) werden über die eingebettete IPv4-Adresse geprüft.
// - IP-Literale in jeder Schreibweise (`127.1`, Dezimal `2130706433`, Hex `0x7f000001`, Oktal, IPv6) werden von `inet_aton`/`inet_pton` normalisiert und dann geprüft.
// - Vor JEDEM Connect (auch im Worker, nicht nur beim Speichern) wird der Name aufgelöst und ALLE Adressen werden gegen die Sperrliste geprüft; verbunden wird mit einer geprüften IP
//   (DNS-Rebinding-Schutz: kein zweiter Lookup zwischen Prüfung und Connect), der TLS-Servername bleibt der DNS-Name.
// - Betreiber erlauben interne Ziele ausdrücklich per `DMS_ALLOW_INTERNAL_TARGETS=true` (Test/Heim-Setups). Alle Verstöße melden denselben Code `target_not_allowed`
//   (kein Orakel, ob ein interner Host/Port existiert).

struct NetworkTargetError: Error, Equatable, CustomStringConvertible {
    let code: String
    var description: String { code }
    static let notAllowed = NetworkTargetError(code: "target_not_allowed")
    static let unresolvable = NetworkTargetError(code: "target_unresolvable")
}

struct NetworkTargetPolicy: Sendable, Equatable {
    var allowInternal = false

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> NetworkTargetPolicy {
        NetworkTargetPolicy(allowInternal: env["DMS_ALLOW_INTERNAL_TARGETS"]?.lowercased() == "true")
    }
}

enum NetworkTarget {
    enum IP: Sendable, Equatable, Hashable {
        case v4([UInt8])    // 4 Bytes
        case v6([UInt8])    // 16 Bytes

        var text: String {
            var buffer = [CChar](repeating: 0, count: 64)
            switch self {
            case .v4(let b): _ = b.withUnsafeBytes { inet_ntop(AF_INET, $0.baseAddress, &buffer, 64) }
            case .v6(let b): _ = b.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &buffer, 64) }
            }
            return String(cString: buffer)
        }

        func socketAddress(port: Int) throws -> SocketAddress {
            switch self {
            case .v4(let b): try SocketAddress(packedIPAddress: ByteBuffer(bytes: b), port: port)
            case .v6(let b): try SocketAddress(packedIPAddress: ByteBuffer(bytes: b), port: port)
            }
        }
    }

    /// Auflösung eines DNS-Namens in alle Adressen (austauschbar für Tests).
    typealias Resolver = @Sendable (_ host: String) async throws -> [IP]

    // MARK: Literale

    /// IP-Literal in jeder von `inet_aton`/`inet_pton` verstandenen Schreibweise (`127.1`, `2130706433`, `0x7f.0.0.1`, `[::1]`, `::ffff:127.0.0.1`), sonst `nil` (DNS-Name).
    static func parseLiteral(_ host: String) -> IP? {
        var h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty, !h.contains(where: { $0.isWhitespace }), !h.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) else { return nil }
        if h.contains(":") {
            if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }   // Zonen-ID (fe80::1%en0): Adresse bleibt Link-Local
            var addr = in6_addr()
            guard inet_pton(AF_INET6, h, &addr) == 1 else { return nil }
            return .v6(withUnsafeBytes(of: &addr) { Array($0) })
        }
        var a = in_addr()
        guard inet_aton(h, &a) != 0 else { return nil }
        return .v4(withUnsafeBytes(of: &a) { Array($0) })
    }

    // MARK: Sperrliste

    static func isInternal(_ ip: IP) -> Bool {
        switch ip {
        case .v4(let b): return internalV4(b)
        case .v6(let b):
            if b.allSatisfy({ $0 == 0 }) { return true }                                       // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }                 // ::1
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return internalV4(Array(b[12..<16])) }   // ::ffff:a.b.c.d
            if b[0..<12].allSatisfy({ $0 == 0 }) { return internalV4(Array(b[12..<16])) }      // IPv4-kompatibel (veraltet)
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) { return internalV4(Array(b[12..<16])) }   // NAT64 64:ff9b::/96
            if b[0] == 0x20, b[1] == 0x02 { return internalV4(Array(b[2..<6])) }               // 6to4
            if b[0] & 0xfe == 0xfc { return true }                                             // fc00::/7
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }                               // fe80::/10
            if b[0] == 0xfe, b[1] & 0xc0 == 0xc0 { return true }                               // fec0::/10 (veraltet, site-local)
            if b[0] == 0xff { return true }                                                    // Multicast
            if b[0] == 0x01, b[1] == 0x00, b[2..<8].allSatisfy({ $0 == 0 }) { return true }    // 100::/64 Discard
            if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return true }          // 2001:db8::/32 Dokumentation
            return false
        }
    }

    private static func internalV4(_ b: [UInt8]) -> Bool {
        let (a, c) = (b[0], b[1])
        if a == 0 || a == 10 || a == 127 { return true }
        if a == 100, c & 0xc0 == 64 { return true }                 // 100.64/10 CGNAT
        if a == 169, c == 254 { return true }                       // Link-Local, Metadaten
        if a == 172, c & 0xf0 == 16 { return true }                 // 172.16/12
        if a == 192, c == 168 { return true }
        if a == 192, c == 0, b[2] == 0 { return true }              // 192.0.0.0/24
        if a == 192, c == 0, b[2] == 2 { return true }              // 192.0.2.0/24 Dokumentation
        if a == 198, c & 0xfe == 18 { return true }                 // 198.18/15 Benchmark
        if a == 198, c == 51, b[2] == 100 { return true }           // 198.51.100/24
        if a == 203, c == 0, b[2] == 113 { return true }            // 203.0.113/24
        if a >= 224 { return true }                                 // Multicast, Reserviert, Broadcast
        return false
    }

    /// Namen, die ohne DNS als intern gelten (Schnellprüfung beim Speichern; die maßgebliche Prüfung ist die Auflösung vor dem Connect).
    static func isInternalName(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        if h == "localhost" || h == "metadata.google.internal" || h == "metadata" { return true }
        for suffix in [".localhost", ".local", ".internal", ".localdomain", ".home.arpa", ".lan", ".intranet", ".corp"] where h.hasSuffix(suffix) { return true }
        return false
    }

    // MARK: Auflösen

    /// Prüft und liefert die Adressen, mit denen verbunden werden darf. Literal: ohne DNS. Name: Auflösung, dann ALLE Adressen gegen die Sperrliste (eine interne Adresse genügt zur Ablehnung).
    static func resolve(host: String, policy: NetworkTargetPolicy, resolver: Resolver = systemResolver) async throws -> [IP] {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty else { throw NetworkTargetError.notAllowed }
        if let literal = parseLiteral(h) {
            guard policy.allowInternal || !isInternal(literal) else { throw NetworkTargetError.notAllowed }
            return [literal]
        }
        if !policy.allowInternal, isInternalName(h) { throw NetworkTargetError.notAllowed }
        var seen = Set<IP>(), ips: [IP] = []
        for ip in (try await resolver(h)) where seen.insert(ip).inserted { ips.append(ip) }
        guard !ips.isEmpty else { throw NetworkTargetError.unresolvable }
        if !policy.allowInternal, ips.contains(where: isInternal) { throw NetworkTargetError.notAllowed }
        return ips
    }

    /// Systemauflösung (`getaddrinfo`), außerhalb des Cooperative-Pools, damit ein langsamer DNS-Server keinen Worker-Thread blockiert.
    static let systemResolver: Resolver = { host in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[IP], any Error>) in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                #if canImport(Darwin)
                hints.ai_socktype = SOCK_STREAM
                #else
                hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
                #endif
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { continuation.resume(throwing: NetworkTargetError.unresolvable); return }
                defer { freeaddrinfo(first) }
                var out: [IP] = []
                var node: UnsafeMutablePointer<addrinfo>? = first
                while let n = node {
                    if n.pointee.ai_family == AF_INET, let sa = n.pointee.ai_addr {
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in out.append(.v4(withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) })) }
                    } else if n.pointee.ai_family == AF_INET6, let sa = n.pointee.ai_addr {
                        sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in out.append(.v6(withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) })) }
                    }
                    node = n.pointee.ai_next
                }
                continuation.resume(returning: out)
            }
        }
    }
}
