import Foundation
import AsyncHTTPClient
import NIOCore
import NIOSSL

// WP-D6: Quelle `api`: REST-API einer Paperless-ngx-Instanz, nur lesend (GET), Token im Header `Authorization`. Schutzmaßnahmen (SSRF, Geheimnis):
// - nur https (TLS ab 1.2 mit voller Zertifikatsprüfung); `http` und Loopback nur mit `DMS_IMPORT_INSECURE_DEV=true` (Entwicklung/Test),
// - Host-Allowlist `DMS_IMPORT_HOST_ALLOWLIST` (Komma, `host` oder `host:port`; Standard keine Einschränkung, wie bei der Mail-Quelle D4). WP-H10: interne Ziele (Loopback, private Netze,
//   Link-Local inkl. Metadaten, ULA, IPv4-in-IPv6, alle IP-Schreibweisen) sind ohne `DMS_ALLOW_INTERNAL_TARGETS=true` (oder den Entwicklungsschalter) gesperrt; vor jedem Lauf wird der Host
//   aufgelöst, ALLE Adressen werden geprüft und die geprüfte IP wird für den Connect festgelegt (`dnsOverride`, TLS-Servername bleibt der Host: Schutz vor DNS-Rebinding),
// - keine Weiterleitungen (das Token geht nur an den eingetragenen Host), keine URL mit Zugangsdaten, Query oder Fragment,
// - Antworten und Fehler tragen nie URL, Token oder Servertext, nur Fehlercodes.

struct PaperlessEndpoint: Sendable, Equatable {
    let base: String        // z. B. https://paperless.example.org (ohne Schrägstrich am Ende)
    let host: String
    let port: Int
    var key: String { "api:" + (URL(string: base).map { ($0.host ?? "") + ":\($0.port ?? (base.hasPrefix("https") ? 443 : 80))" + $0.path } ?? base).lowercased() }

    struct Policy: Sendable {
        var insecureDev = false
        var allowlist: [String]?
        /// Interne Ziele ausdrücklich erlaubt (`DMS_ALLOW_INTERNAL_TARGETS=true`, Test/Heim-Setups) oder Entwicklungsschalter.
        var allowInternalTargets = false
        var allowInternal: Bool { insecureDev || allowInternalTargets }
        var resolver: NetworkTarget.Resolver = NetworkTarget.systemResolver
        static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Policy {
            var p = Policy()
            p.insecureDev = env["DMS_IMPORT_INSECURE_DEV"] == "true"
            p.allowInternalTargets = NetworkTargetPolicy.fromEnvironment(env).allowInternal
            if let l = env["DMS_IMPORT_HOST_ALLOWLIST"], !l.isEmpty { p.allowlist = l.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
            return p
        }
    }

    /// Fehlercodes: `invalid_url`, `scheme_not_allowed`, `host_not_allowed`.
    static func parse(_ raw: String, policy: Policy) throws -> PaperlessEndpoint {
        guard raw.count <= 300, raw.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }),
              let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw ImportError("invalid_url") }
        guard scheme == "https" || (scheme == "http" && policy.insecureDev) else { throw ImportError("scheme_not_allowed") }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw ImportError("invalid_url") }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        guard path.isEmpty || (path.hasPrefix("/") && !path.contains("..") && path.count <= 100) else { throw ImportError("invalid_url") }
        if !policy.allowInternal, isInternal(host) { throw ImportError("host_not_allowed") }
        if let list = policy.allowlist, !list.contains(host), !list.contains("\(host):\(port)") { throw ImportError("host_not_allowed") }
        return PaperlessEndpoint(base: "\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")\(path)", host: host, port: port)
    }

    /// Interner Host nach der gemeinsamen Sperrliste (`NetworkTarget`): jedes IP-Literal (auch `127.1`, Dezimal, Hex, `::ffff:127.0.0.1`) und interne Namen.
    static func isInternal(_ host: String) -> Bool {
        if let ip = NetworkTarget.parseLiteral(host) { return NetworkTarget.isInternal(ip) }
        return NetworkTarget.isInternalName(host)
    }

    /// Auflösung und Prüfung vor dem Lauf. Rückgabe: IP, auf die der Connect festgelegt wird (`nil` bei IP-Literal: dort gibt es nichts umzulenken).
    /// Fehler: `host_not_allowed` (eine aufgelöste Adresse ist intern), `source_unreachable` (nicht auflösbar).
    static func vetTarget(_ endpoint: PaperlessEndpoint, policy: Policy) async throws -> String? {
        let ips: [NetworkTarget.IP]
        do { ips = try await NetworkTarget.resolve(host: endpoint.host, policy: NetworkTargetPolicy(allowInternal: policy.allowInternal), resolver: policy.resolver) }
        catch let e as NetworkTargetError { throw ImportError(e == .notAllowed ? "host_not_allowed" : "source_unreachable") }
        if NetworkTarget.parseLiteral(endpoint.host) != nil { return nil }
        let preferred = ips.first { if case .v4 = $0 { true } else { false } } ?? ips[0]
        return preferred.text
    }
}

struct PaperlessAPISource: PaperlessSource {
    let endpoint: PaperlessEndpoint
    let token: String
    let tempRoot: URL
    let client: HTTPClient
    var key: String { endpoint.key }

    /// `pinnedIP`: Ergebnis von `PaperlessEndpoint.vetTarget`; der Connect geht an genau diese IP, der TLS-Servername bleibt der Host (kein zweiter DNS-Lookup).
    static func makeClient(host: String? = nil, pinnedIP: String? = nil) -> HTTPClient {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = .fullVerification
        var config = HTTPClient.Configuration(tlsConfiguration: tls, redirectConfiguration: .disallow)
        config.timeout = .init(connect: .seconds(15), read: .seconds(60))
        if let host, let pinnedIP { config.dnsOverride = [host: pinnedIP] }
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
    }

    static let maxJSONBytes = 32 * 1024 * 1024

    private func request(_ path: String, _ query: [(String, String)] = []) async throws -> HTTPClientResponse {
        var c = URLComponents(string: endpoint.base + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = c.url?.absoluteString else { throw ImportError("invalid_url") }
        var req = HTTPClientRequest(url: url)
        req.method = .GET
        req.headers.add(name: "Authorization", value: "Token \(token)")
        req.headers.add(name: "Accept", value: "application/json")
        req.headers.add(name: "User-Agent", value: "labhub-import")
        let response: HTTPClientResponse
        do { response = try await client.execute(req, timeout: .seconds(120)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Linux: NIOSSL; macOS: Network.framework (NWTLSError). Beides sind Fehler der TLS-Prüfung (Zertifikat, Handshake).
            let kind = String(describing: type(of: error)).lowercased(), text = String(describing: error).lowercased()
            if error is NIOSSLError || error is BoringSSLError || kind.contains("tls") || kind.contains("ssl") || text.contains("certificate") || text.contains("handshake") {
                throw ImportError("source_tls_failed")
            }
            if Task.isCancelled { throw CancellationError() }
            throw ImportError("source_unreachable")
        }
        switch response.status.code {
        case 200: return response
        case 401, 403: throw ImportError("source_auth_failed")
        case 404: throw ImportError("source_not_found")
        default: throw ImportError("source_http_error")
        }
    }

    private func json(_ path: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        let response = try await request(path, query)
        do {
            let body = try await response.body.collect(upTo: Self.maxJSONBytes)
            guard let o = StrictJSON.object(Data(buffer: body)) else { throw ImportError("source_response_invalid") }
            return o
        } catch let e as ImportError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch { throw ImportError("source_response_invalid") }
    }

    private func results(_ path: String, extra: [(String, String)] = [], size: Int, _ body: ([[String: Any]], Int?) async throws -> Void) async throws {
        var page = 1
        while true {
            try Task.checkCancellation()
            let o = try await json(path, [("page", String(page)), ("page_size", String(size))] + extra)
            let rows = (o["results"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            if rows.isEmpty { return }
            try await body(rows, PL.int(o["count"]).map(Int.init))
            if o["next"] == nil || o["next"] is NSNull { return }
            page += 1
            guard page <= 100_000 else { throw ImportError("source_response_invalid") }
        }
    }

    func references() async throws -> PLReferences {
        var refs = PLReferences()
        func entity(_ f: [String: Any]) -> PLEntity? {
            guard let id = PL.int(f["id"]), let name = PL.str(f["name"]) else { return nil }
            var x = PLEntity(id: id, name: name)
            x.match = (f["match"] as? String) ?? ""
            x.algorithm = Int(PL.int(f["matching_algorithm"]) ?? 0)
            x.insensitive = (f["is_insensitive"] as? Bool) ?? true
            x.color = PL.str(f["color"])
            x.template = PL.str(f["path"])
            x.dataType = PL.str(f["data_type"])
            if let extra = f["extra_data"] as? [String: Any], let opts = extra["select_options"] as? [Any] {
                x.options = opts.compactMap { o in
                    if let s = o as? String { return PLOption(id: nil, label: s) }
                    if let d = o as? [String: Any], let label = PL.str(d["label"]) { return PLOption(id: PL.str(d["id"]) ?? PL.int(d["id"]).map(String.init), label: label) }
                    return nil
                }
            }
            return x
        }
        for (path, keyPath) in [("/api/correspondents/", \PLReferences.correspondents), ("/api/document_types/", \.types), ("/api/tags/", \.tags),
                                ("/api/storage_paths/", \.paths), ("/api/custom_fields/", \.fields)] as [(String, WritableKeyPath<PLReferences, [PLEntity]>)] {
            try await results(path, extra: [("ordering", "id")], size: 500) { rows, _ in refs[keyPath: keyPath].append(contentsOf: rows.compactMap(entity)) }
        }
        return refs
    }

    func pages(size: Int, _ body: ([PLDoc], Int?) async throws -> Void) async throws {
        try await results("/api/documents/", extra: [("ordering", "id")], size: size) { rows, total in
            try await body(rows.compactMap(Self.document), total)
        }
    }

    static func document(_ f: [String: Any]) -> PLDoc? {
        guard let id = PL.int(f["id"]) else { return nil }
        var d = PLDoc(id: id)
        d.title = (f["title"] as? String) ?? ""
        d.content = (f["content"] as? String) ?? ""
        d.created = (f["created"] as? String) ?? (f["created_date"] as? String)
        d.added = f["added"] as? String
        d.asn = PL.int(f["archive_serial_number"])
        d.correspondent = PL.int(f["correspondent"])
        d.type = PL.int(f["document_type"])
        d.path = PL.int(f["storage_path"])
        d.tags = ((f["tags"] as? [Any]) ?? []).compactMap(PL.int)
        d.owner = PL.int(f["owner"])
        d.originalName = PL.str(f["original_file_name"])
        d.archiveAvailable = PL.str(f["archived_file_name"]) != nil
        d.notes = ((f["notes"] as? [Any]) ?? []).compactMap { n in
            guard let o = n as? [String: Any], let text = PL.str(o["note"]) else { return nil }
            return PLNote(id: PL.int(o["id"]), text: text, created: o["created"] as? String)
        }
        d.fields = ((f["custom_fields"] as? [Any]) ?? []).compactMap { c in
            guard let o = c as? [String: Any], let field = PL.int(o["field"]), !(o["value"] is NSNull), o["value"] != nil else { return nil }
            return PLFieldValue(field: field, value: PLValue(native: o["value"]))
        }
        return d
    }

    func materialize(_ doc: PLDoc, _ role: PLFileRole, maxBytes: Int64) async throws -> LocalFile? {
        if role == .archive, !doc.archiveAvailable { return nil }
        let response: HTTPClientResponse
        do { response = try await request("/api/documents/\(doc.id)/download/", role == .original ? [("original", "true")] : []) }
        catch let e as ImportError where e.code == "source_not_found" { return nil }
        if let len = response.headers.first(name: "content-length").flatMap(Int64.init), len > maxBytes { throw ImportError("file_too_large") }
        let url = tempRoot.appendingPathComponent("lh-import-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ImportError("workdir_unwritable") }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var written: Int64 = 0
            for try await chunk in response.body {
                written += Int64(chunk.readableBytes)
                if written > maxBytes { throw ImportError("file_too_large") }
                try handle.write(contentsOf: Data(buffer: chunk))
            }
            return try LocalFile.measure(url, temporary: true, maxBytes: maxBytes)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let e = error as? ImportError { throw e }
            throw ImportError("source_unreachable")
        }
    }
}
