import Foundation
import NIOCore
import NIOPosix
import NIOSSL

// WP-D4: schlanker IMAP-Client (RFC 3501, RFC 6851 MOVE) über NIO + NIOSSL (beides schon Abhängigkeiten des Backends, Apache-2.0).
// Entscheidung (Handoff WP-D4): keine neue IMAP-Bibliothek. Der Hub braucht nur LOGIN, SELECT, UID SEARCH/FETCH/STORE/COPY/MOVE, ein
// Test-APPEND und LOGOUT; ein eigener Client hat keine zusätzliche Lizenz- und Wartungsfläche und lässt TLS, Zeitlimits und Größenlimits
// an einer Stelle prüfen. Immer implizites TLS (Port 993), niemals Klartext, kein STARTTLS-Rückfall. Eine Sitzung = ein Poll-Lauf, kein Dauerprozess.
// Nicht unterstützt: IDLE, Modified-UTF-7-Postfachnamen (nur ASCII), SASL außer LOGIN, Pipelining.

struct IMAPOptions: Sendable {
    /// Zertifikatsprüfung (Standard an). Abschalten nur für Tests/Labor (Betreiber-Umgebung `DMS_MAIL_TLS_VERIFY=false`), nie je Quelle.
    var verifyCertificate = true
    /// Eigene CA-Datei (PEM) für interne Mailserver (`DMS_MAIL_CA_PATH`).
    var caFile: String?
    var connectTimeout: TimeAmount = .seconds(15)
    /// Gesamtzeit einer Sitzung; danach Abbruch (`imap_timeout`).
    var sessionTimeout: Duration = .seconds(300)
    var maxMessageBytes = 100 * 1024 * 1024
    /// WP-H10 (Befund 3): Zielprüfung vor jedem Connect (Standard: interne Ziele gesperrt; `DMS_ALLOW_INTERNAL_TARGETS=true` erlaubt sie ausdrücklich) und Portliste (Standard nur 993,
    /// weitere über `DMS_MAIL_PORT_ALLOWLIST`, kommagetrennt). Verstoß: `target_not_allowed`, immer derselbe Code (kein Port-/Host-Orakel).
    var targetPolicy = NetworkTargetPolicy()
    var allowedPorts: Set<Int> = [993]
    var resolver: NetworkTarget.Resolver = NetworkTarget.systemResolver
    /// WP-H10 (Befund 8): Grenzen je Befehlsantwort (alle Zeilen inkl. Literale). Überschreitung: `imap_response_too_large`. Die wirksame Bytegrenze ist nie kleiner als die größte
    /// erlaubte Nachricht plus 1 MB Rahmen (`maxMessageBytes`), damit ein erlaubter `FETCH` nie daran scheitert.
    var maxResponseLines = 10_000
    var maxResponseBytes = 64 * 1024 * 1024

    /// Erlaubte Ports aus der Betreiber-Umgebung (993 immer, dazu `DMS_MAIL_PORT_ALLOWLIST`).
    static func allowedPorts(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Set<Int> {
        var ports: Set<Int> = [993]
        for part in (env["DMS_MAIL_PORT_ALLOWLIST"] ?? "").split(separator: ",") { if let p = Int(part.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) { ports.insert(p) } }
        return ports
    }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> IMAPOptions {
        var o = IMAPOptions()
        o.targetPolicy = NetworkTargetPolicy.fromEnvironment(env)
        o.allowedPorts = allowedPorts(env)
        if let v = env["DMS_MAIL_TLS_VERIFY"]?.lowercased(), ["false", "0", "no"].contains(v) { o.verifyCertificate = false }
        if let f = env["DMS_MAIL_CA_PATH"], !f.isEmpty { o.caFile = f }
        if let s = env["DMS_MAIL_SESSION_TIMEOUT_SECONDS"].flatMap(Int.init), (10...3600).contains(s) { o.sessionTimeout = .seconds(s) }
        return o
    }
}

/// Fehler mit stabilem, nutzdatenfreiem Code (landet als `last_error` in der Quelle).
struct IMAPError: Error, Equatable, CustomStringConvertible {
    let code: String
    var description: String { code }
    static let connect = IMAPError(code: "imap_connect_failed"), tls = IMAPError(code: "imap_tls_failed"), auth = IMAPError(code: "imap_auth_failed")
    static let protocolError = IMAPError(code: "imap_protocol_error"), timeout = IMAPError(code: "imap_timeout"), closed = IMAPError(code: "imap_connection_closed")
    static let mailbox = IMAPError(code: "imap_mailbox_not_found"), tooLarge = IMAPError(code: "imap_message_too_large")
    static let responseTooLarge = IMAPError(code: "imap_response_too_large"), targetNotAllowed = IMAPError(code: "target_not_allowed")
}

/// Eine Serverzeile; Literale (`{n}` plus Bytes) stehen getrennt, im Text steht an ihrer Stelle `\u{0}`.
struct IMAPLine: Sendable {
    var text: String
    var literals: [[UInt8]]
}

struct IMAPResponse: Sendable {
    var untagged: [IMAPLine]
    var status: String        // OK, NO, BAD
    var statusText: String
}

/// Zugriff strikt sequenziell (eine Sitzung, ein Aufrufer); daher kein Actor (mutierender `next()` des Iterators).
final class IMAPSession: @unchecked Sendable {
    private var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private let writer: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private var buffer: [UInt8] = []
    private var tagCounter = 0
    private let maxLiteral: Int
    private let maxResponseBytes: Int
    private let maxResponseLines: Int
    private var responseBytes = 0
    private var responseLines = 0
    private(set) var capabilities: Set<String> = []
    private(set) var uidValidity: String?

    init(inbound: NIOAsyncChannelInboundStream<ByteBuffer>, outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>, maxLiteral: Int,
         maxResponseBytes: Int = 64 * 1024 * 1024, maxResponseLines: Int = 10_000) {
        iterator = inbound.makeAsyncIterator(); writer = outbound; self.maxLiteral = maxLiteral
        self.maxResponseBytes = max(maxResponseBytes, maxLiteral + 1024 * 1024); self.maxResponseLines = maxResponseLines
    }

    /// Beginn einer Befehlsantwort: Zähler für Bytes und Zeilen zurücksetzen (Befund 8).
    private func beginResponse() { responseBytes = 0; responseLines = 0 }

    private func account(bytes: Int) throws {
        responseBytes += bytes
        if responseBytes > maxResponseBytes { throw IMAPError.responseTooLarge }
    }

    // MARK: Lesen

    private func fill() async throws {
        guard let chunk = try await iterator.next() else { throw IMAPError.closed }
        buffer.append(contentsOf: chunk.readableBytesView)
    }

    private func readRawLine() async throws -> [UInt8] {
        var searchFrom = 0
        while true {
            if let i = buffer[searchFrom...].firstIndex(of: 0x0A) {
                var line = Array(buffer[0..<i])
                buffer.removeFirst(i + 1)
                if line.last == 0x0D { line.removeLast() }
                return line
            }
            searchFrom = buffer.count
            if buffer.count > 1_000_000 { throw IMAPError.protocolError }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> [UInt8] {
        while buffer.count < n { try await fill() }
        let out = Array(buffer[0..<n])
        buffer.removeFirst(n)
        return out
    }

    /// Liest eine logische Zeile inklusive Literale.
    private func readLine() async throws -> IMAPLine {
        var text = "", literals: [[UInt8]] = []
        while true {
            let raw = try await readRawLine()
            try account(bytes: raw.count + 2)
            let s = String(decoding: raw, as: UTF8.self)
            if s.hasSuffix("}"), let open = s.lastIndex(of: "{"), let n = Int(s[s.index(after: open)..<s.index(before: s.endIndex)].replacingOccurrences(of: "+", with: "")), n >= 0 {
                guard n <= maxLiteral else { throw IMAPError.tooLarge }
                try account(bytes: n)
                text += s[..<open]
                text += "\u{0}"
                literals.append(try await readBytes(n))
                continue
            }
            text += s
            responseLines += 1
            if responseLines > maxResponseLines { throw IMAPError.responseTooLarge }
            return IMAPLine(text: text, literals: literals)
        }
    }

    // MARK: Befehle

    private func write(_ s: String) async throws { try await writer.write(ByteBuffer(string: s)) }
    private func write(bytes: [UInt8]) async throws { try await writer.write(ByteBuffer(bytes: bytes)) }

    /// Sendet `command` (ohne Tag). Mit `literal` endet der Befehl auf `{n}`; der Server muss mit `+` fortsetzen (nicht synchronisierend wird nicht genutzt).
    func command(_ command: String, literal: [UInt8]? = nil) async throws -> IMAPResponse {
        tagCounter += 1
        beginResponse()
        let tag = "A\(String(format: "%03d", tagCounter))"
        guard !command.contains("\r"), !command.contains("\n"), !command.contains("\u{0}") else { throw IMAPError.protocolError }
        if let literal {
            try await write("\(tag) \(command) {\(literal.count)}\r\n")
            while true {
                let line = try await readLine()
                if line.text.hasPrefix("+") { break }
                if line.text.hasPrefix(tag + " ") { throw IMAPError.protocolError }
            }
            try await write(bytes: literal + [0x0D, 0x0A])
        } else {
            try await write("\(tag) \(command)\r\n")
        }
        var untagged: [IMAPLine] = []
        while true {
            let line = try await readLine()
            if line.text.hasPrefix(tag + " ") {
                let rest = line.text.dropFirst(tag.count + 1)
                let status = rest.split(separator: " ", maxSplits: 1).first.map { String($0).uppercased() } ?? ""
                guard ["OK", "NO", "BAD"].contains(status) else { throw IMAPError.protocolError }
                return IMAPResponse(untagged: untagged, status: status, statusText: String(rest.dropFirst(status.count)).trimmingCharacters(in: .whitespaces))
            }
            if line.text.hasPrefix("*") { untagged.append(line) }
        }
    }

    func readGreeting() async throws {
        beginResponse()
        let line = try await readLine()
        guard line.text.uppercased().hasPrefix("* OK") else { throw IMAPError.protocolError }
    }

    /// Befehl mit Fortsetzungszeile (SASL): sendet `command`, wartet auf `+`, sendet `continuation`, liest bis zur getaggten Antwort.
    func commandWithContinuation(_ command: String, continuation: String) async throws -> IMAPResponse {
        tagCounter += 1
        beginResponse()
        let tag = "A\(String(format: "%03d", tagCounter))"
        try await write("\(tag) \(command)\r\n")
        while true {
            let line = try await readLine()
            if line.text.hasPrefix("+") { break }
            if line.text.hasPrefix(tag + " ") { return IMAPResponse(untagged: [], status: "NO", statusText: "") }
        }
        try await write("\(continuation)\r\n")
        return try await finish(tag: tag)
    }

    private func finish(tag: String) async throws -> IMAPResponse {
        var untagged: [IMAPLine] = []
        while true {
            let line = try await readLine()
            if line.text.hasPrefix(tag + " ") {
                let rest = line.text.dropFirst(tag.count + 1)
                let status = rest.split(separator: " ", maxSplits: 1).first.map { String($0).uppercased() } ?? ""
                guard ["OK", "NO", "BAD"].contains(status) else { throw IMAPError.protocolError }
                return IMAPResponse(untagged: untagged, status: status, statusText: String(rest.dropFirst(status.count)).trimmingCharacters(in: .whitespaces))
            }
            if line.text.hasPrefix("*") { untagged.append(line) }
        }
    }

    // MARK: Hilfen

    /// Quoted string für ASCII-Werte (Backslash und Anführungszeichen maskiert); Steuerzeichen und Nicht-ASCII werden abgelehnt.
    static func quote(_ s: String) throws -> String {
        guard !s.isEmpty, s.utf8.count <= 256, s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { throw IMAPError.protocolError }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Operationen

    /// Anmeldung: `AUTHENTICATE PLAIN` (RFC 4616, UTF-8-sicher), wenn der Server `AUTH=PLAIN` anbietet, sonst `LOGIN` (RFC 3501, ASCII, als quoted string maskiert).
    /// Immer nur über TLS. Das Passwort steht nur in der übertragenen Zeile, nie in einem Fehler.
    func login(user: String, password: String) async throws {
        guard !user.contains("\u{0}"), !password.contains("\u{0}") else { throw IMAPError.auth }
        if capabilities.contains("AUTH=PLAIN") {
            let initial = Data(("\u{0}" + user + "\u{0}" + password).utf8).base64EncodedString()
            let r = try await commandWithContinuation("AUTHENTICATE PLAIN", continuation: initial)
            guard r.status == "OK" else { throw IMAPError.auth }
        } else if !capabilities.contains("LOGINDISABLED") {
            func credential(_ s: String) throws -> String {
                guard !s.isEmpty, s.utf8.count <= 1024, s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { throw IMAPError.auth }
                return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            let r = try await command("LOGIN \(try credential(user)) \(try credential(password))")
            guard r.status == "OK" else { throw IMAPError.auth }
        } else { throw IMAPError.auth }
    }

    func loadCapabilities() async throws {
        let r = try await command("CAPABILITY")
        guard r.status == "OK" else { throw IMAPError.protocolError }
        capabilities = Set(r.untagged.filter { $0.text.uppercased().hasPrefix("* CAPABILITY") }.flatMap { $0.text.uppercased().split(separator: " ").dropFirst(2).map(String.init) })
    }

    func select(_ mailbox: String) async throws {
        let r = try await command("SELECT \(try Self.quote(mailbox))")
        guard r.status == "OK" else { throw IMAPError.mailbox }
        for line in r.untagged {
            if let range = line.text.uppercased().range(of: "[UIDVALIDITY ") {
                let rest = line.text[range.upperBound...]
                uidValidity = rest.prefix { $0.isNumber }.isEmpty ? nil : String(rest.prefix { $0.isNumber })
            }
        }
    }

    /// `UID SEARCH UNSEEN` mit optionalen serverseitigen Filtern (Teilzeichenkette, ohne Groß-/Kleinschreibung). Ergebnis aufsteigend.
    func searchUnseen(from: String? = nil, subject: String? = nil) async throws -> [UInt32] {
        var criteria = "UNSEEN"
        if let from { criteria += " FROM \(try Self.quote(from))" }
        if let subject { criteria += " SUBJECT \(try Self.quote(subject))" }
        let r = try await command("UID SEARCH \(criteria)")
        guard r.status == "OK" else { throw IMAPError.protocolError }
        let ids = r.untagged.filter { $0.text.uppercased().hasPrefix("* SEARCH") }.flatMap { $0.text.split(separator: " ").dropFirst(2).compactMap { UInt32($0) } }
        return Array(Set(ids)).sorted()
    }

    func size(of uid: UInt32) async throws -> Int? {
        let r = try await command("UID FETCH \(uid) (RFC822.SIZE)")
        guard r.status == "OK" else { throw IMAPError.protocolError }
        for line in r.untagged {
            if let range = line.text.uppercased().range(of: "RFC822.SIZE ") { return Int(line.text[range.upperBound...].prefix { $0.isNumber }) }
        }
        return nil
    }

    /// Lädt die ganze Nachricht ohne sie als gelesen zu markieren (`BODY.PEEK`).
    func fetch(_ uid: UInt32) async throws -> Data {
        let r = try await command("UID FETCH \(uid) (BODY.PEEK[])")
        guard r.status == "OK" else { throw IMAPError.protocolError }
        for line in r.untagged where line.text.uppercased().contains("BODY[]") {
            if let literal = line.literals.first { return Data(literal) }
        }
        throw IMAPError.protocolError
    }

    func markSeen(_ uid: UInt32) async throws {
        let r = try await command("UID STORE \(uid) +FLAGS.SILENT (\\Seen)")
        guard r.status == "OK" else { throw IMAPError.protocolError }
    }

    /// Verschiebt in ein anderes Postfach, nie löschen: `UID MOVE` (RFC 6851) oder, ohne die Erweiterung, `UID COPY` (Original bleibt, ist als gelesen markiert).
    func moveOrCopy(_ uid: UInt32, to mailbox: String) async throws {
        let box = try Self.quote(mailbox)
        let r = try await command(capabilities.contains("MOVE") ? "UID MOVE \(uid) \(box)" : "UID COPY \(uid) \(box)")
        guard r.status == "OK" else { throw IMAPError.mailbox }
    }

    /// Nur für Tests (synthetische Mails einspielen).
    func append(_ message: Data, to mailbox: String) async throws {
        let r = try await command("APPEND \(try Self.quote(mailbox))", literal: [UInt8](message))
        guard r.status == "OK" else { throw IMAPError.protocolError }
    }

    func logout() async { _ = try? await command("LOGOUT") }
}

/// Eine Sitzung: Verbindung über implizites TLS, Zeitlimit für alles, Verbindung wird immer geschlossen.
enum IMAPClient {
    static func isIPLiteral(_ host: String) -> Bool {
        (try? SocketAddress(ipAddress: host, port: 0)) != nil
    }

    static func withSession<T: Sendable>(host: String, port: Int, user: String, password: String, options: IMAPOptions,
                                         _ body: @escaping @Sendable (IMAPSession) async throws -> T) async throws -> T {
        // WP-H10: Port- und Zielprüfung VOR dem Connect; verbunden wird mit einer geprüften IP, der TLS-Servername bleibt der DNS-Name (Rebinding-Schutz).
        guard options.allowedPorts.contains(port) else { throw IMAPError.targetNotAllowed }
        let addresses: [NetworkTarget.IP]
        do { addresses = try await NetworkTarget.resolve(host: host, policy: options.targetPolicy, resolver: options.resolver) }
        catch let e as NetworkTargetError { throw e == .notAllowed ? IMAPError.targetNotAllowed : IMAPError.connect }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = options.verifyCertificate ? .fullVerification : .none
        if let ca = options.caFile { tls.trustRoots = .file(ca) }
        let context: NIOSSLContext
        do { context = try NIOSSLContext(configuration: tls) } catch { throw IMAPError.tls }
        let sniHost: String? = isIPLiteral(host) ? nil : host
        let maxLiteral = options.maxMessageBytes
        let maxResponseBytes = options.maxResponseBytes, maxResponseLines = options.maxResponseLines
        var connected: NIOAsyncChannel<ByteBuffer, ByteBuffer>?
        for ip in addresses {
            do {
                connected = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(options.connectTimeout)
                    .connect(to: try ip.socketAddress(port: port)) { ch in
                        ch.eventLoop.makeCompletedFuture {
                            try ch.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: context, serverHostname: sniHost))
                            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch)
                        }
                    }
                break
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        guard let channel = connected else { throw IMAPError.connect }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await channel.executeThenClose { inbound, outbound in
                    let session = IMAPSession(inbound: inbound, outbound: outbound, maxLiteral: maxLiteral, maxResponseBytes: maxResponseBytes, maxResponseLines: maxResponseLines)
                    do {
                        try await session.readGreeting()
                        try await session.loadCapabilities()
                        try await session.login(user: user, password: password)
                        let result = try await body(session)
                        await session.logout()
                        return result
                    } catch let e as IMAPError { throw e }
                    catch is CancellationError { throw CancellationError() }
                    catch let e as NIOSSLError { _ = e; throw IMAPError.tls }
                    catch let e as ChannelError where e == .ioOnClosedChannel || e == .alreadyClosed || e == .eof { _ = e; throw IMAPError.closed }
                    catch { throw IMAPError.protocolError }
                }
            }
            group.addTask {
                try await Task.sleep(for: options.sessionTimeout)
                throw IMAPError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw IMAPError.protocolError }
            return first
        }
    }
}
