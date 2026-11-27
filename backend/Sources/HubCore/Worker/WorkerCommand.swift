import Vapor
import Foundation
import SQLKit

/// Handler-Registry des Worker-Befehls. Fachliche Handler liefern die Module (`HubModule.jobHandlers`, WP-ST2); der Kern selbst kennt nur `worker.selftest`.
public enum WorkerHandlers {
    /// `worker.selftest`: Diagnose-Art für Prozesstests, nur mit `WORKER_ENABLE_SELFTEST=1`. Payload (JSON): `sleep_first_ms` (nur beim ersten Versuch), `fail` (immer werfen).
    static let selftestKind = "worker.selftest"

    /// Fremde (nicht `<key>.`) oder doppelte Job-Arten eines Moduls sind ein Programmierfehler (`ConfigError`).
    public static func registry(environment: [String: String] = ProcessInfo.processInfo.environment, modules: [any HubModule]) throws -> [String: JobHandler] {
        var map: [String: JobHandler] = [:]
        if environment["WORKER_ENABLE_SELFTEST"] == "1" { map[selftestKind] = selftest }
        for module in modules {
            for (kind, handler) in module.jobHandlers(environment: environment) {
                guard kind.hasPrefix(module.key + "."), map[kind] == nil else { throw ConfigError(description: "Job-Art \(kind) von Modul \(module.key) ungültig oder doppelt") }
                map[kind] = handler
            }
        }
        return map
    }

    /// Vorabprüfung der Module für die gewählten Arten; die erste Meldung bricht den Start ab.
    public static func preflight(kinds: Set<String>, environment: [String: String] = ProcessInfo.processInfo.environment, modules: [any HubModule]) async -> String? {
        for module in modules {
            let own = kinds.filter { $0.hasPrefix(module.key + ".") }
            if !own.isEmpty, let problem = await module.workerPreflight(kinds: own, environment: environment) { return problem }
        }
        return nil
    }

    private struct SelftestPayload: Decodable { var sleep_first_ms: Int?; var fail: Bool? }

    private static let selftest: JobHandler = { job, _ in
        let p = (try? JSONDecoder().decode(SelftestPayload.self, from: Data(job.payload.utf8))) ?? SelftestPayload()
        if let ms = p.sleep_first_ms, job.attempts == 1 { try await Task.sleep(for: .milliseconds(ms)) }
        if p.fail == true { throw NSError(domain: "worker.selftest", code: 1) }
    }
}

/// `worker --kinds a,b [--lease-seconds 60] [--poll-ms 1000] [--retry-backoff-seconds 5]`: eigener Prozess ohne HTTP-Server (ADR 0006 Nr. 2).
/// SIGTERM/SIGINT: laufender Job wird abgebrochen, seine Lease freigegeben, Exit-Code 0. Bei SIGKILL übernimmt ein anderer Worker nach Lease-Ablauf.
public struct WorkerCommand: AsyncCommand {
    public struct Signature: CommandSignature {
        @Option(name: "kinds", help: "Kommagetrennte Job-Arten, z. B. worker.selftest")
        package var kinds: String?
        @Option(name: "lease-seconds", help: "Lease-Länge in Sekunden (Standard 60); Erneuerung alle Lease/3")
        var leaseSeconds: Int?
        @Option(name: "poll-ms", help: "Wartezeit ohne Arbeit in Millisekunden (Standard 1000)")
        var pollMs: Int?
        @Option(name: "retry-backoff-seconds", help: "Basis des exponentiellen Wiederholungsabstands (Standard 5)")
        var retryBackoffSeconds: Int?
        public init() {}
    }
    public var help: String { "Startet einen Job-Worker für die angegebenen Arten." }
    public init() {}

    public func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        func fail(_ message: String) -> Never { context.console.error(message); exit(1) }
        guard app.hubConfig != nil else { fail("Datenbank nicht konfiguriert (DB_HOST)") }
        let kinds = (signature.kinds ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !kinds.isEmpty else { fail("--kinds fehlt") }
        let lease = signature.leaseSeconds ?? 60, poll = signature.pollMs ?? 1000, backoff = signature.retryBackoffSeconds ?? 5
        guard (1...3600).contains(lease), (10...60_000).contains(poll), (0...3600).contains(backoff) else { fail("Ungültiger Zahlenwert") }
        let modules = app.hubModules.modules
        let registry: [String: JobHandler]
        do { registry = try WorkerHandlers.registry(modules: modules) } catch { fail("\(error)") }
        let unknown = kinds.filter { registry[$0] == nil }
        guard unknown.isEmpty else { fail("Kein Handler für: \(unknown.joined(separator: ","))") }
        if let problem = await WorkerHandlers.preflight(kinds: Set(kinds), modules: modules) { fail(problem) }
        guard await schemaIsCurrent(app) else { fail("Schema nicht aktuell (zuerst `migrate`)") }

        let environment = ProcessInfo.processInfo.environment
        let sweeps = modules.flatMap { $0.jobSweeps(environment: environment).filter { kinds.contains($0.key) }.values }
        let worker = JobWorker(db: try sql(app.db(.psql)), kinds: kinds, handlers: registry.filter { kinds.contains($0.key) }, leaseSeconds: lease,
                               pollInterval: .milliseconds(poll), retryBackoffSeconds: backoff, logger: app.logger, sweeps: sweeps)
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { sig -> any DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { worker.requestShutdown() }
            s.resume()
            return s
        }
        await worker.run()
        for s in sources { s.cancel() }
    }
}
