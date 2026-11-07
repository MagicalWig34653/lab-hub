import Vapor
import Fluent
import SQLKit

/// Schlüsselraum eines Zählers: `space` (Modul/Zweck, z. B. "invoice") und `name` (z. B. Jahr). Rohschlüssel `space:name`.
public struct CounterKey: Sendable, Equatable, Hashable {
    public let space: String
    public let name: String
    public init(space: String, name: String) {
        precondition(!space.isEmpty && !space.contains(":"), "invalid counter space")
        self.space = space; self.name = name
    }
    public var rawValue: String { "\(space):\(name)" }
}

/// Ereignis einer Anhebung per `ensureAtLeast` (nur Zählerdaten, keine Nutzdaten).
public struct CounterAuditEvent: Sendable, Equatable {
    public let tenant: UUID
    public let key: String
    public let previous: Int64?
    public let new: Int64
    public let reason: String
}

/// Schnittstelle für das Audit-Log (Tabelle `audit_log` entsteht mit WP-K1). Der Hook läuft auf derselben
/// Datenbank/Transaktion wie die Anhebung, damit Zähler und Audit-Eintrag gemeinsam committen oder zurückrollen.
public protocol CounterAuditHook: Sendable {
    func counterRaised(_ event: CounterAuditEvent, on db: any SQLDatabase) async throws
}

/// Zähler: ein Statement, atomar durch die Zeilensperre des Upserts. Rückgabe ist die vergebene Nummer (ab 1).
/// Mit `on:` läuft die Vergabe in einer fremden Transaktion; Rollback setzt den Zählerstand zurück.
public struct CounterService: Sendable {
    let db: any SQLDatabase
    let auditHook: (any CounterAuditHook)?
    public init(_ db: any SQLDatabase, auditHook: (any CounterAuditHook)? = nil) { self.db = db; self.auditHook = auditHook }

    public func next(tenant: UUID, key: String) async throws -> Int64 {
        try await next(tenant: tenant, key: key, on: db)
    }

    public func next(tenant: UUID, key: CounterKey, on tx: (any SQLDatabase)? = nil) async throws -> Int64 {
        try await next(tenant: tenant, key: key.rawValue, on: tx ?? db)
    }

    /// Hebt den Zähler auf mindestens `value` an (nie ab), z. B. nach Importen. Rückgabe: Stand danach.
    /// Bei tatsächlicher Änderung wird der Audit-Hook (falls gesetzt) auf derselben Verbindung aufgerufen.
    @discardableResult
    public func ensureAtLeast(tenant: UUID, key: CounterKey, value: Int64, reason: String = "ensureAtLeast",
                              on tx: (any SQLDatabase)? = nil) async throws -> Int64 {
        let db = tx ?? self.db
        let rawKey = key.rawValue
        let inserted = try await db.raw("""
            INSERT INTO counters (tenant_id, key, value) VALUES (\(bind: tenant), \(bind: rawKey), \(bind: value))
            ON CONFLICT (tenant_id, key) DO NOTHING RETURNING value
            """).first()
        var previous: Int64? = nil
        var result = value
        if inserted == nil {
            // Row exists: lock it, return old and new value in one statement.
            guard let row = try await db.raw("""
                UPDATE counters c SET value = GREATEST(c.value, \(bind: value))
                FROM (SELECT value FROM counters WHERE tenant_id = \(bind: tenant) AND key = \(bind: rawKey) FOR UPDATE) old
                WHERE c.tenant_id = \(bind: tenant) AND c.key = \(bind: rawKey)
                RETURNING old.value AS previous, c.value AS value
                """).first() else { throw Abort(.internalServerError) }
            previous = try row.decode(column: "previous", as: Int64.self)
            result = try row.decode(column: "value", as: Int64.self)
        }
        if previous != result, let auditHook {
            try await auditHook.counterRaised(
                CounterAuditEvent(tenant: tenant, key: rawKey, previous: previous, new: result, reason: reason), on: db)
        }
        return result
    }

    public func next(tenant: UUID, key: String, on tx: any SQLDatabase) async throws -> Int64 {
        let row = try await tx.raw("""
            INSERT INTO counters (tenant_id, key, value) VALUES (\(bind: tenant), \(bind: key), 1)
            ON CONFLICT (tenant_id, key) DO UPDATE SET value = counters.value + 1 RETURNING value
            """).first()
        guard let row else { throw Abort(.internalServerError) }
        return try row.decode(column: "value", as: Int64.self)
    }
}

public struct StoredResponse: Sendable, Equatable { public let status: Int; public let body: String }

public enum IdempotencyError: Error, Equatable { case keyReusedWithDifferentRequest, inProgress }

/// Idempotency-Key: gleicher Schlüssel + gleicher Request-Hash liefert die gespeicherte Antwort, ohne `work` erneut auszuführen.
public struct IdempotencyService: Sendable {
    let db: any SQLDatabase
    public init(_ db: any SQLDatabase) { self.db = db }

    public func execute(tenant: UUID, key: String, requestHash: String,
                        work: @Sendable () async throws -> StoredResponse) async throws -> StoredResponse {
        let inserted = try await db.raw("""
            INSERT INTO idempotency_keys (tenant_id, key, request_hash) VALUES (\(bind: tenant), \(bind: key), \(bind: requestHash))
            ON CONFLICT DO NOTHING RETURNING key
            """).all()
        if inserted.isEmpty {
            guard let row = try await db.raw("""
                SELECT request_hash, state, response_status, response_body FROM idempotency_keys
                WHERE tenant_id = \(bind: tenant) AND key = \(bind: key)
                """).first() else { throw IdempotencyError.inProgress }
            if try row.decode(column: "request_hash", as: String.self) != requestHash { throw IdempotencyError.keyReusedWithDifferentRequest }
            guard try row.decode(column: "state", as: String.self) == "done" else { throw IdempotencyError.inProgress }
            return StoredResponse(status: try row.decode(column: "response_status", as: Int.self),
                                  body: try row.decode(column: "response_body", as: String.self))
        }
        do {
            let result = try await work()
            try await db.raw("""
                UPDATE idempotency_keys SET state = 'done', response_status = \(bind: result.status), response_body = \(bind: result.body)
                WHERE tenant_id = \(bind: tenant) AND key = \(bind: key)
                """).run()
            return result
        } catch {
            try? await db.raw("DELETE FROM idempotency_keys WHERE tenant_id = \(bind: tenant) AND key = \(bind: key)").run()
            throw error
        }
    }
}

public struct ClaimedJob: Sendable {
    public let id: UUID
    public let kind: String
    public let payload: String
    /// Versuche inklusive dieses Abholens (1 beim ersten Mal).
    public let attempts: Int
}

/// Ergebnis von `JobService.fail`.
public enum JobFailOutcome: Sendable, Equatable { case retry, failedPermanent, notOwner }

/// Datenbank-Jobs mit Lease: `FOR UPDATE SKIP LOCKED`, Zeiten von der Datenbank (nie die Instanzuhr).
/// Zustände: `queued`, `running`, `done`, `failed_permanent` (Quarantäne nach `maxAttempts` Versuchen, WP-O1, ADR 0006).
/// Jeder Übergang ist idempotent: nur der Besitzer wirkt, jede Wiederholung ist ohne Effekt.
public struct JobService: Sendable {
    let db: any SQLDatabase
    public let maxAttempts: Int
    public init(_ db: any SQLDatabase, maxAttempts: Int = 3) { self.db = db; self.maxAttempts = maxAttempts }

    /// `priority`: höhere Zahl zuerst (manuelle Uploads vor Massenimport), bei Gleichstand `run_at`, dann Anlage.
    @discardableResult
    public func enqueue(kind: String, payload: String = "{}", priority: Int = 0) async throws -> UUID {
        let id = UUID()
        try await db.raw("INSERT INTO jobs (id, kind, payload, priority) VALUES (\(bind: id), \(bind: kind), \(bind: payload), \(bind: priority))").run()
        return id
    }

    /// Holt den nächsten fälligen Job (optional nur bestimmter Arten). Ein Job, dessen Lease `maxAttempts`-mal ablief (Absturzschleife),
    /// wird nicht erneut vergeben, sondern `failed_permanent`.
    public func claim(owner: String, leaseSeconds: Int, kinds: [String]? = nil) async throws -> ClaimedJob? {
        try await db.raw("""
            UPDATE jobs SET state = 'failed_permanent', lease_owner = NULL, lease_until = NULL, finished_at = now(), last_error = 'lease_expired'
            WHERE state = 'running' AND lease_until < now() AND attempts >= \(bind: maxAttempts)
            """).run()
        let kindFilter: SQLQueryString = (kinds?.isEmpty ?? true) ? "TRUE" : "kind IN (\(binds: kinds ?? []))"
        guard let row = try await db.raw("""
            UPDATE jobs SET state = 'running', lease_owner = \(bind: owner),
              lease_until = now() + make_interval(secs => \(bind: leaseSeconds)), attempts = attempts + 1
            WHERE id = (SELECT id FROM jobs WHERE state IN ('queued', 'running') AND run_at <= now()
                        AND (lease_until IS NULL OR lease_until < now()) AND attempts < \(bind: maxAttempts) AND \(kindFilter)
                        ORDER BY priority DESC, run_at, created_at FOR UPDATE SKIP LOCKED LIMIT 1)
            RETURNING id, kind, payload, attempts
            """).first() else { return nil }
        return ClaimedJob(id: try row.decode(column: "id", as: UUID.self), kind: try row.decode(column: "kind", as: String.self),
                          payload: try row.decode(column: "payload", as: String.self), attempts: try row.decode(column: "attempts", as: Int.self))
    }

    /// Nur der aktuelle Besitzer kann abschließen oder verlängern.
    public func complete(_ id: UUID, owner: String) async throws -> Bool {
        try await db.raw("""
            UPDATE jobs SET state = 'done', finished_at = now(), lease_owner = NULL, lease_until = NULL
            WHERE id = \(bind: id) AND lease_owner = \(bind: owner) AND lease_until >= now() RETURNING id
            """).all().count == 1
    }

    public func renew(_ id: UUID, owner: String, leaseSeconds: Int) async throws -> Bool {
        try await db.raw("""
            UPDATE jobs SET lease_until = now() + make_interval(secs => \(bind: leaseSeconds))
            WHERE id = \(bind: id) AND lease_owner = \(bind: owner) AND lease_until >= now() RETURNING id
            """).all().count == 1
    }

    /// Gibt die Lease frei (Graceful Shutdown); der Job wird sofort wieder abholbar und der Versuch zählt nicht.
    public func release(_ id: UUID, owner: String) async throws {
        try await db.raw("""
            UPDATE jobs SET lease_owner = NULL, lease_until = NULL, state = 'queued', attempts = GREATEST(attempts - 1, 0)
            WHERE id = \(bind: id) AND lease_owner = \(bind: owner) AND state = 'running'
            """).run()
    }

    /// Meldet Misserfolg (nur Besitzer, auch bei abgelaufener Lease, solange niemand übernahm). Wiederholung nach `retryAfterSeconds`;
    /// nach `maxAttempts` Versuchen oder mit `permanent` Quarantäne (`failed_permanent`). `code` ist ein kurzer Fehlercode, keine Nutzdaten.
    public func fail(_ id: UUID, owner: String, code: String, retryAfterSeconds: Int, permanent: Bool = false) async throws -> JobFailOutcome {
        let safe = String(code.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "_.-".unicodeScalars.contains($0)) }.prefix(64))
        guard let row = try await db.raw("""
            UPDATE jobs SET lease_owner = NULL, lease_until = NULL, last_error = \(bind: safe.isEmpty ? "error" : safe),
              state = CASE WHEN \(bind: permanent) OR attempts >= \(bind: maxAttempts) THEN 'failed_permanent' ELSE 'queued' END,
              finished_at = CASE WHEN \(bind: permanent) OR attempts >= \(bind: maxAttempts) THEN now() ELSE NULL END,
              run_at = now() + make_interval(secs => \(bind: retryAfterSeconds))
            WHERE id = \(bind: id) AND lease_owner = \(bind: owner) AND state = 'running' RETURNING state
            """).first() else { return .notOwner }
        return try row.decode(column: "state", as: String.self) == "failed_permanent" ? .failedPermanent : .retry
    }
}
