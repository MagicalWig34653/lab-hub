import Vapor
import Fluent
import SQLKit

/// Zähler: ein Statement, atomar durch die Zeilensperre des Upserts. Rückgabe ist die vergebene Nummer (ab 1).
public struct CounterService: Sendable {
    let db: any SQLDatabase
    public init(_ db: any SQLDatabase) { self.db = db }

    public func next(tenant: UUID, key: String) async throws -> Int64 {
        let row = try await db.raw("""
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

public struct ClaimedJob: Sendable { public let id: UUID; public let kind: String; public let payload: String }

/// Datenbank-Jobs mit Lease: `FOR UPDATE SKIP LOCKED`, Zeiten von der Datenbank.
public struct JobService: Sendable {
    let db: any SQLDatabase
    public init(_ db: any SQLDatabase) { self.db = db }

    @discardableResult
    public func enqueue(kind: String, payload: String = "{}") async throws -> UUID {
        let id = UUID()
        try await db.raw("INSERT INTO jobs (id, kind, payload) VALUES (\(bind: id), \(bind: kind), \(bind: payload))").run()
        return id
    }

    public func claim(owner: String, leaseSeconds: Int) async throws -> ClaimedJob? {
        guard let row = try await db.raw("""
            UPDATE jobs SET state = 'running', lease_owner = \(bind: owner),
              lease_until = now() + make_interval(secs => \(bind: leaseSeconds)), attempts = attempts + 1
            WHERE id = (SELECT id FROM jobs WHERE state <> 'done' AND run_at <= now()
                        AND (lease_until IS NULL OR lease_until < now())
                        ORDER BY run_at, created_at FOR UPDATE SKIP LOCKED LIMIT 1)
            RETURNING id, kind, payload
            """).first() else { return nil }
        return ClaimedJob(id: try row.decode(column: "id", as: UUID.self), kind: try row.decode(column: "kind", as: String.self),
                          payload: try row.decode(column: "payload", as: String.self))
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

    /// Gibt die Lease frei (Graceful Shutdown); der Job wird sofort wieder abholbar.
    public func release(_ id: UUID, owner: String) async throws {
        try await db.raw("UPDATE jobs SET lease_owner = NULL, lease_until = NULL, state = 'queued' WHERE id = \(bind: id) AND lease_owner = \(bind: owner)").run()
    }
}
