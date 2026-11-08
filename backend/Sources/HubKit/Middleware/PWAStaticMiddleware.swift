import Vapor
import Foundation
import Crypto

/// Auslieferung der PWA durch das Backend (WP-H9). Konfiguration nur aus der Umgebung:
/// - `PWA_ENABLED=false` schaltet die Auslieferung ab (reines API-Backend).
/// - `PWA_DIR` (Standard `/usr/share/lab-hub/pwa`, im Image gesetzt). Ist der Pfad ausdrücklich gesetzt, aber ohne `index.html`, scheitert der Start;
///   der Standardpfad ohne Verzeichnis (z. B. `swift run` in der Entwicklung) schaltet die Auslieferung still ab.
/// - `PWA_HSTS_MAX_AGE` (Sekunden, Standard aus): sendet `Strict-Transport-Security` an PWA-Antworten. Nur hinter einem TLS-Proxy setzen.
public struct PWAConfig: Sendable, Equatable {
    public static let defaultDir = "/usr/share/lab-hub/pwa"
    public var dir: String
    public var hstsMaxAge: Int?

    public init(dir: String, hstsMaxAge: Int? = nil) { self.dir = dir; self.hstsMaxAge = hstsMaxAge }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> PWAConfig? {
        if let enabled = try HubConfig.value("PWA_ENABLED", env) {
            switch enabled.lowercased() {
            case "false", "0", "no", "off": return nil
            case "true", "1", "yes", "on": break
            default: throw ConfigError(description: "PWA_ENABLED muss true oder false sein")
            }
        }
        let explicit = try HubConfig.value("PWA_DIR", env)
        let dir = explicit ?? defaultDir
        var isDir: ObjCBool = false
        let hasIndex = FileManager.default.fileExists(atPath: dir + "/index.html", isDirectory: &isDir) && !isDir.boolValue
        if !hasIndex {
            if explicit != nil { throw ConfigError(description: "PWA_DIR enthält keine index.html") }
            return nil
        }
        var hsts: Int?
        if let raw = try HubConfig.value("PWA_HSTS_MAX_AGE", env) {
            guard let n = Int(raw), n >= 0 else { throw ConfigError(description: "PWA_HSTS_MAX_AGE ungültig") }
            hsts = n == 0 ? nil : n
        }
        return PWAConfig(dir: dir, hstsMaxAge: hsts)
    }
}

/// Liefert Dateien aus `PWA_DIR` für `GET`/`HEAD` auf Pfaden, die keine Backend-Route treffen (nie `/api`, `/health`, `/ready`).
/// Unbekannte Pfade ohne Dateiendung liefern `index.html` (Deep-Link-Fallback der SPA); fehlende Dateien mit Endung und Pfade mit
/// Traversal-Versuchen bleiben 404. Die Dateien liegen unveränderlich im Image; die Instanz hält keinen Zustand außer dem beim Start
/// gelesenen `index.html` samt Hash.
///
/// Sicherheits-Header (nur an PWA-Antworten, die API setzt ihre eigenen): CSP, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`,
/// optional HSTS. CSP-Strategie: SvelteKit schreibt in `index.html` genau ein Inline-Skript (Start der App). Dessen SHA-256 wird beim Start aus
/// der ausgelieferten Datei berechnet und in `script-src` eingetragen; so braucht es weder `unsafe-inline` noch ein Nonce (ein Nonce würde je
/// Anfrage ein Umschreiben der statischen Datei verlangen). `unsafe-eval` ist nicht erlaubt.
public struct PWAStaticMiddleware: AsyncMiddleware {
    static let reservedFirstSegments: Set<String> = ["api", "health", "ready"]
    static let immutableCache = "public, max-age=31536000, immutable"
    static let revalidateCache = "no-cache"

    let realRoot: String
    let index: ByteBuffer
    let indexETag: String
    let securityHeaders: [(String, String)]

    public init(config: PWAConfig) throws {
        guard let real = Self.realPath(config.dir) else { throw ConfigError(description: "PWA_DIR nicht lesbar") }
        realRoot = real
        guard let data = FileManager.default.contents(atPath: realRoot + "/index.html") else { throw ConfigError(description: "index.html nicht lesbar") }
        index = ByteBuffer(data: data)
        indexETag = "\"" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32) + "\""
        var headers: [(String, String)] = [
            ("Content-Security-Policy", Self.contentSecurityPolicy(indexHTML: String(decoding: data, as: UTF8.self))),
            ("X-Content-Type-Options", "nosniff"),
            ("Referrer-Policy", "same-origin"),
            ("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()"),
        ]
        if let age = config.hstsMaxAge { headers.append(("Strict-Transport-Security", "max-age=\(age)")) }
        securityHeaders = headers
    }

    /// `default-src 'self'`; Vorschau von Bildern/PDF/Mail über `blob:` (img-src, frame-src) und die Datei-Routen derselben Herkunft (frame-src 'self').
    /// `style-src 'unsafe-inline'`: SvelteKit/Tailwind setzen `style`-Attribute (`display: contents`); Skripte bleiben streng (Hash, kein eval).
    static func contentSecurityPolicy(indexHTML: String) -> String {
        let hashes = inlineScriptHashes(indexHTML).map { "'sha256-\($0)'" }
        let script = (["'self'"] + hashes).joined(separator: " ")
        return [
            "default-src 'self'",
            "script-src \(script)",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' blob: data:",
            "font-src 'self'",
            "connect-src 'self'",
            "frame-src 'self' blob:",
            "worker-src 'self'",
            "manifest-src 'self'",
            "object-src 'none'",
            "base-uri 'self'",
            "form-action 'self'",
            "frame-ancestors 'none'",
        ].joined(separator: "; ")
    }

    /// Base64-SHA-256 aller Inline-Skripte (`<script>` ohne `src`).
    static func inlineScriptHashes(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<script(\\s[^>]*)?>(.*?)</script>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = html as NSString
        var out: [String] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound, ns.substring(with: m.range(at: 1)).range(of: "src=", options: .caseInsensitive) != nil { continue }
            let body = ns.substring(with: m.range(at: 2))
            out.append(Data(SHA256.hash(data: Data(body.utf8))).base64EncodedString())
        }
        return out
    }

    enum Resolution: Equatable {
        case file(String)
        case fallback
        case notFound
    }

    /// Ordnet einen (noch prozentkodierten) URL-Pfad einer Datei unterhalb der Wurzel zu. Abgelehnt werden `.`/`..`-Segmente (auch kodiert, doppelt kodiert),
    /// Rückwärtsschrägstriche, Steuerzeichen, versteckte Dateien und alles, was nach Auflösung von Symlinks außerhalb der Wurzel liegt.
    func resolve(_ rawPath: String) -> Resolution {
        guard let decoded = rawPath.removingPercentEncoding, !decoded.contains("%"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return .notFound }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { return .notFound }
        guard let last = parts.last else { return .fallback }
        let candidate = realRoot + "/" + parts.joined(separator: "/")
        if let real = Self.realPath(candidate) {
            guard real.hasPrefix(realRoot + "/") else { return .notFound }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue { return .file(real) }
        }
        return last.contains(".") ? .notFound : .fallback
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func cacheControl(for relative: String) -> String {
        relative.hasPrefix("_app/immutable/") ? immutableCache : revalidateCache
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let first = request.url.path.split(separator: "/", omittingEmptySubsequences: true).first.map { String($0).lowercased() }
        if let first, Self.reservedFirstSegments.contains(first) { return try await next.respond(to: request) }
        guard request.method == .GET || request.method == .HEAD else { return try await next.respond(to: request) }
        do {
            return try await next.respond(to: request)
        } catch let abort as AbortError where abort.status == .notFound {
            switch resolve(request.url.path) {
            case .notFound: throw abort
            case .fallback: return fallbackResponse(request)
            case .file(let real):
                if real == realRoot + "/index.html" { return fallbackResponse(request) }
                return fileResponse(request, real: real)
            }
        }
    }

    private func apply(_ headers: inout HTTPHeaders, cache: String) {
        for (k, v) in securityHeaders { headers.replaceOrAdd(name: k, value: v) }
        headers.replaceOrAdd(name: .cacheControl, value: cache)
    }

    private func fallbackResponse(_ request: Request) -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .html
        headers.replaceOrAdd(name: .eTag, value: indexETag)
        apply(&headers, cache: Self.revalidateCache)
        if request.headers.first(name: .ifNoneMatch) == indexETag {
            headers.remove(name: .contentType)
            return Response(status: .notModified, headers: headers)
        }
        if request.method == .HEAD {
            headers.replaceOrAdd(name: .contentLength, value: String(index.readableBytes))
            return Response(status: .ok, headers: headers)
        }
        return Response(status: .ok, headers: headers, body: .init(buffer: index))
    }

    private func fileResponse(_ request: Request, real: String) -> Response {
        let relative = String(real.dropFirst(realRoot.count + 1))
        let response: Response
        if request.method == .HEAD {
            let size = (try? FileManager.default.attributesOfItem(atPath: real)[.size] as? Int) ?? 0
            response = Response(status: .ok)
            if let ext = real.split(separator: ".").last.map(String.init), let type = HTTPMediaType.fileExtension(ext) { response.headers.contentType = type }
            response.headers.replaceOrAdd(name: .contentLength, value: String(size))
        } else {
            response = request.fileio.streamFile(at: real)
        }
        apply(&response.headers, cache: Self.cacheControl(for: relative))
        return response
    }
}
