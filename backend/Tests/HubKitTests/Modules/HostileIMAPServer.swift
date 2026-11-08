import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import XCTest

/// WP-H10 (Befund 8): minimaler feindlicher IMAP-Server (TLS, selbstsigniertes Zertifikat per `openssl`), synthetisch. Moduswerte: `normal`, `lines` (endlose untagged-Zeilen),
/// `literals` (viele große Literale), `longline` (Zeile ohne Zeilenende).
final class HostileIMAPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _mode = "normal"
    var mode: String { get { lock.lock(); defer { lock.unlock() }; return _mode } set { lock.lock(); _mode = newValue; lock.unlock() } }
    let port: Int
    private let channel: Channel
    private let dir: URL

    private init(channel: Channel, port: Int, dir: URL) { self.channel = channel; self.port = port; self.dir = dir }

    static func make() async throws -> HostileIMAPServer? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-h10-imap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir.appendingPathComponent("k.pem").path, "-out", dir.appendingPathComponent("c.pem").path,
                       "-days", "1", "-subj", "/CN=127.0.0.1"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let config = TLSConfiguration.makeServerConfiguration(certificateChain: try NIOSSLCertificate.fromPEMFile(dir.appendingPathComponent("c.pem").path).map { .certificate($0) },
                                                              privateKey: .file(dir.appendingPathComponent("k.pem").path))
        let context = try NIOSSLContext(configuration: config)
        let box = ModeBox()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try ch.pipeline.syncOperations.addHandler(HostileHandler(mode: { box.get() }))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else { return nil }
        let server = HostileIMAPServer(channel: channel, port: port, dir: dir)
        box.server = server
        return server
    }

    func stop() async { try? await channel.close(); try? FileManager.default.removeItem(at: dir) }

    private final class ModeBox: @unchecked Sendable {
        weak var server: HostileIMAPServer?
        func get() -> String { server?.mode ?? "normal" }
    }

    private final class HostileHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let mode: () -> String
        var pending = ""
        var awaitingAuth: String?
        init(mode: @escaping () -> String) { self.mode = mode }

        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "* OK ready\r\n")), promise: nil)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            pending += String(buffer: unwrapInboundIn(data))
            while let r = pending.range(of: "\r\n") {
                let line = String(pending[..<r.lowerBound]); pending.removeSubrange(..<r.upperBound)
                handle(line, context)
            }
        }

        private func send(_ s: String, _ context: ChannelHandlerContext) { context.write(wrapOutboundOut(ByteBuffer(string: s)), promise: nil) }

        private func handle(_ line: String, _ context: ChannelHandlerContext) {
            if let tag = awaitingAuth { awaitingAuth = nil; send("\(tag) OK authenticated\r\n", context); context.flush(); return }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return }
            let tag = parts[0], command = parts[1].uppercased()
            switch command {
            case "CAPABILITY": send("* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n\(tag) OK done\r\n", context)
            case "AUTHENTICATE": awaitingAuth = tag; send("+ \r\n", context)
            case "LOGOUT": send("* BYE\r\n\(tag) OK bye\r\n", context)
            case "SELECT":
                switch mode() {
                case "lines": for _ in 0..<5_000 { send("* 1 EXISTS\r\n", context) }
                case "literals":
                    let block = String(repeating: "A", count: 900_000)
                    for _ in 0..<8 { send("* 1 FETCH (BODY[] {900000}\r\n\(block))\r\n", context) }
                case "longline": send(String(repeating: "x", count: 1_500_000), context)
                default: send("* 1 EXISTS\r\n", context)
                }
                if mode() != "longline" { send("\(tag) OK [READ-WRITE] done\r\n", context) }
            default: send("\(tag) OK\r\n", context)
            }
            context.flush()
        }
    }
}
