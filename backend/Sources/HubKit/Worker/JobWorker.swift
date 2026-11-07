import Vapor
import Foundation
import SQLKit

// WP-O1 (ADR 0006, ADR 0003): Worker-Schleife über `JobService`. Zustandslos: alles Korrekte steht in der Datenbank (Lease, Versuche, Quarantäne);
// die Instanzuhr dient nur zum Schlafen, nie zur Entscheidung über Lease-Gültigkeit (das macht `now()` in der Datenbank).

public typealias JobHandler = @Sendable (ClaimedJob, any SQLDatabase) async throws -> Void

/// Ein Handler wirft das, wenn Wiederholen sinnlos ist (z. B. nicht unterstützte Eingabe): der Job geht ohne weitere Versuche in Quarantäne.
public struct PermanentJobError: Error, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
}

public final class JobWorker: @unchecked Sendable {
    let jobs: JobService
    let db: any SQLDatabase
    let kinds: [String]
    let handlers: [String: JobHandler]
    let leaseSeconds: Int
    let pollInterval: Duration
    let retryBackoffSeconds: Int
    let logger: Logger
    public let owner: String
    private let lock = NSLock()
    private var shuttingDown = false

    public init(db: any SQLDatabase, kinds: [String], handlers: [String: JobHandler], leaseSeconds: Int = 60, pollInterval: Duration = .seconds(1),
                retryBackoffSeconds: Int = 5, logger: Logger, owner: String = JobWorker.makeOwner(), maxAttempts: Int = 3) {
        precondition(leaseSeconds >= 1)
        self.db = db; self.jobs = JobService(db, maxAttempts: maxAttempts); self.kinds = kinds; self.handlers = handlers
        self.leaseSeconds = leaseSeconds; self.pollInterval = pollInterval; self.retryBackoffSeconds = retryBackoffSeconds
        self.logger = logger; self.owner = owner
    }

    /// Eindeutig je Prozess und Lauf (Prozess-ID plus Zufall), enthält keinen Hostnamen.
    public static func makeOwner() -> String { "w-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8).lowercased())" }

    public var isShuttingDown: Bool { lock.lock(); defer { lock.unlock() }; return shuttingDown }

    /// Fordert ein geordnetes Ende an (SIGTERM): der laufende Job wird abgebrochen und seine Lease freigegeben, dann endet `run()`.
    public func requestShutdown() { lock.lock(); shuttingDown = true; lock.unlock() }

    /// Läuft bis `requestShutdown()`.
    public func run() async {
        logger.info("Worker gestartet", metadata: ["owner": "\(owner)", "kinds": "\(kinds.joined(separator: ","))"])
        while !isShuttingDown {
            do {
                if let job = try await jobs.claim(owner: owner, leaseSeconds: leaseSeconds, kinds: kinds) {
                    await process(job)
                    continue
                }
            } catch {
                logger.error("Abholen fehlgeschlagen, neuer Versuch", metadata: ["error": "\(type(of: error))"])
            }
            await sleepInterruptibly(pollInterval)
        }
        logger.info("Worker beendet", metadata: ["owner": "\(owner)"])
    }

    private func sleepInterruptibly(_ d: Duration) async {
        let slice = Duration.milliseconds(50)
        var left = d
        while left > .zero, !isShuttingDown {
            let step = min(left, slice)
            try? await Task.sleep(for: step)
            left -= step
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    private func process(_ job: ClaimedJob) async {
        guard let handler = handlers[job.kind] else {
            // Nicht erreichbar (Art-Filter), aber sicher: nie einen unbekannten Job anfassen.
            try? await jobs.release(job.id, owner: owner)
            return
        }
        if isShuttingDown { try? await jobs.release(job.id, owner: owner); return }
        let db = self.db
        let work = Task<Void, Error> { try await handler(job, db) }
        let lost = Flag()
        let jobs = self.jobs, owner = self.owner, lease = leaseSeconds, logger = self.logger
        let renewer = Task {
            let interval = Duration.milliseconds(max(lease * 1000 / 3, 100))
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                do {
                    if try await !jobs.renew(job.id, owner: owner, leaseSeconds: lease) {
                        lost.set(); work.cancel()
                        logger.warning("Lease verloren, Auftrag wird abgebrochen", metadata: ["job": "\(job.id)"])
                        return
                    }
                } catch {
                    logger.warning("Lease-Erneuerung fehlgeschlagen", metadata: ["job": "\(job.id)"])
                }
            }
        }
        let watcher = Task { [self] in
            while !Task.isCancelled {
                if isShuttingDown { work.cancel(); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let result = await work.result
        renewer.cancel(); watcher.cancel()
        await renewer.value; await watcher.value

        if lost.value { return }  // ein anderer Worker besitzt den Job; nichts mehr schreiben
        do {
            switch result {
            case .success:
                if try await !jobs.complete(job.id, owner: owner) {
                    logger.warning("Abschluss abgelehnt (Lease nicht mehr gültig)", metadata: ["job": "\(job.id)"])
                }
            case .failure(let error):
                if isShuttingDown {
                    try await jobs.release(job.id, owner: owner)
                } else if let permanent = error as? PermanentJobError {
                    _ = try await jobs.fail(job.id, owner: owner, code: permanent.code, retryAfterSeconds: 0, permanent: true)
                } else {
                    let delay = retryBackoffSeconds * (1 << min(max(job.attempts - 1, 0), 10))
                    let outcome = try await jobs.fail(job.id, owner: owner, code: "handler_error", retryAfterSeconds: delay)
                    logger.warning("Auftrag fehlgeschlagen", metadata: ["job": "\(job.id)", "kind": "\(job.kind)", "outcome": "\(outcome)"])
                }
            }
        } catch {
            // Datenbank weg: die Lease läuft ab, ein anderer Worker übernimmt (at-least-once, Handler sind idempotent).
            logger.error("Übergang konnte nicht gespeichert werden", metadata: ["job": "\(job.id)"])
        }
    }
}
