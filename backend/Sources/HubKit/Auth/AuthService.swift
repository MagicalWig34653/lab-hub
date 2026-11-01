import Vapor
import Fluent
import SQLKit

/// Anmeldelogik (WP-K1). Alle Zustände (Challenges, Sitzungen, Einladungen, Rate-Limit) liegen in der Datenbank; Zeiten kommen aus DB-`now()`.
/// Vorbild (nur gelesen, neu geschrieben): timetrack-backend `WebAuthnService.swift`, `SessionService.swift`, `RecoveryService.swift`.
struct AuthService: Sendable {
    let settings: AuthSettings
    let passkeys: any PasskeyService

    static let handlePattern = "^[a-z0-9][a-z0-9._-]{2,31}$"
    static let challengeTTLSeconds = 300
    static let bootstrapLock: Int64 = 0x4C41_4248_5553  // Advisory-Lock: genau ein erster Nutzer

    struct Options: Sendable { let challengeID: UUID; let options: PasskeyOptions }

    private static func validate(handle: String, displayName: String) throws {
        var errors: [FieldError] = []
        if handle.range(of: handlePattern, options: .regularExpression) == nil { errors.append(FieldError(field: "handle", code: "invalid")) }
        if !(1...80).contains(displayName.count) { errors.append(FieldError(field: "display_name", code: "invalid")) }
        if !errors.isEmpty { throw HubError(.unprocessableEntity, "validation_failed", errors: errors) }
    }

    // MARK: Challenges

    private struct StoredChallenge: Sendable { let challenge: Data; let payload: [String: String]; let userID: UUID?; let invitationID: UUID? }

    private func createChallenge(_ purpose: String, _ challenge: Data, payload: [String: String] = [:], userID: UUID? = nil,
                                 invitationID: UUID? = nil, on s: any SQLDatabase) async throws -> UUID {
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let ttl = Self.challengeTTLSeconds
        guard let row = try await s.raw("""
            INSERT INTO auth_challenges (purpose, challenge, payload, user_id, invitation_id, expires_at)
            VALUES (\(bind: purpose), \(bind: challenge), \(bind: json)::text::jsonb, \(bind: userID), \(bind: invitationID),
                    now() + (\(bind: ttl)::bigint * interval '1 second')) RETURNING id
            """).first() else { throw Abort(.internalServerError) }
        return try row.decode(column: "id", as: UUID.self)
    }

    /// Einmalig einlösbar, nur vor Ablauf (DB-Zeit); wird sofort und unabhängig vom Ausgang der Prüfung verbraucht.
    private func consumeChallenge(_ id: UUID, purpose: String, on s: any SQLDatabase) async throws -> StoredChallenge? {
        guard let row = try await s.raw("""
            UPDATE auth_challenges SET consumed_at = now()
            WHERE id = \(bind: id) AND purpose = \(bind: purpose) AND consumed_at IS NULL AND expires_at > now()
            RETURNING challenge, payload::text AS payload, user_id, invitation_id
            """).first() else { return nil }
        let payload = try JSONDecoder().decode([String: String].self, from: Data(try row.decode(column: "payload", as: String.self).utf8))
        return StoredChallenge(challenge: try row.decode(column: "challenge", as: Data.self), payload: payload,
                               userID: try row.decode(column: "user_id", as: UUID?.self),
                               invitationID: try row.decode(column: "invitation_id", as: UUID?.self))
    }

    // MARK: Sitzungen

    func authenticate(_ token: String, viaCookie: Bool, on db: any Database) async throws -> AuthContext? {
        let s = try sql(db)
        guard let row = try await s.raw("""
            SELECT s.id, s.kind, s.expires_at, u.id AS user_id, u.handle, u.display_name, u.is_admin
            FROM sessions s JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = \(bind: AuthSecrets.hash(token)) AND s.revoked_at IS NULL AND s.expires_at > now() AND u.disabled_at IS NULL
            """).first() else { return nil }
        let id = try row.decode(column: "id", as: UUID.self)
        // Nur informativ: höchstens einmal je Minute schreiben.
        try await s.raw("UPDATE sessions SET last_seen_at = now() WHERE id = \(bind: id) AND last_seen_at < now() - interval '60 seconds'").run()
        return AuthContext(
            sessionID: id,
            user: AuthUser(id: try row.decode(column: "user_id", as: UUID.self), handle: try row.decode(column: "handle", as: String.self),
                           displayName: try row.decode(column: "display_name", as: String.self), isAdmin: try row.decode(column: "is_admin", as: Bool.self)),
            kind: SessionKind(rawValue: try row.decode(column: "kind", as: String.self)) ?? .normal,
            expiresAt: try row.decode(column: "expires_at", as: Date.self), token: token, viaCookie: viaCookie)
    }

    private func issueSession(for user: AuthUser, kind: SessionKind = .normal, on s: any SQLDatabase) async throws -> AuthContext {
        let token = AuthSecrets.token()
        let ttl = kind == .recovery ? settings.recoverySessionTTL : settings.sessionTTL
        guard let row = try await s.raw("""
            INSERT INTO sessions (user_id, token_hash, kind, expires_at)
            VALUES (\(bind: user.id), \(bind: AuthSecrets.hash(token)), \(bind: kind.rawValue), now() + (\(bind: ttl)::bigint * interval '1 second'))
            RETURNING id, expires_at
            """).first() else { throw Abort(.internalServerError) }
        return AuthContext(sessionID: try row.decode(column: "id", as: UUID.self), user: user, kind: kind,
                           expiresAt: try row.decode(column: "expires_at", as: Date.self), token: token, viaCookie: false)
    }

    /// Meldet die aktuelle Sitzung ab.
    func logout(_ c: AuthContext, requestID: String, on db: any Database) async throws {
        try await inTransaction(db) { s in
            try await s.raw("UPDATE sessions SET revoked_at = now() WHERE id = \(bind: c.sessionID) AND revoked_at IS NULL").run()
            try await AuditLog.record(AuditEvent(action: "auth.logout", actor: c.user.id, subjectType: "session", subjectID: c.sessionID.uuidString, requestID: requestID), on: s)
        }
    }

    /// AK-K1-7: alle Geräte abmelden (alle Sitzungen des Nutzers, auch die aktuelle). Rückgabe: Anzahl.
    func logoutAll(_ c: AuthContext, requestID: String, on db: any Database) async throws -> Int {
        try await inTransaction(db) { s in
            let rows = try await s.raw("UPDATE sessions SET revoked_at = now() WHERE user_id = \(bind: c.user.id) AND revoked_at IS NULL RETURNING id").all()
            try await AuditLog.record(AuditEvent(action: "auth.logout_all", actor: c.user.id, subjectType: "user", subjectID: c.user.id.uuidString,
                                                 meta: ["count": .number(Int64(rows.count))], requestID: requestID), on: s)
            return rows.count
        }
    }

    struct SessionInfo: Sendable { let id: UUID; let kind: String; let createdAt: Date; let lastSeenAt: Date; let expiresAt: Date; let current: Bool }

    func sessions(_ c: AuthContext, on db: any Database) async throws -> [SessionInfo] {
        try await sql(db).raw("""
            SELECT id, kind, created_at, last_seen_at, expires_at FROM sessions
            WHERE user_id = \(bind: c.user.id) AND revoked_at IS NULL AND expires_at > now() ORDER BY created_at, id
            """).all().map { r in
            let id = try r.decode(column: "id", as: UUID.self)
            return SessionInfo(id: id, kind: try r.decode(column: "kind", as: String.self), createdAt: try r.decode(column: "created_at", as: Date.self),
                               lastSeenAt: try r.decode(column: "last_seen_at", as: Date.self), expiresAt: try r.decode(column: "expires_at", as: Date.self),
                               current: id == c.sessionID)
        }
    }

    /// Fremde Sitzungs-ID liefert 404 (kein Hinweis auf Existenz).
    func revokeSession(_ id: UUID, _ c: AuthContext, requestID: String, on db: any Database) async throws {
        try await inTransaction(db) { s in
            guard try await s.raw("UPDATE sessions SET revoked_at = now() WHERE id = \(bind: id) AND user_id = \(bind: c.user.id) AND revoked_at IS NULL RETURNING id").first() != nil
            else { throw HubError(.notFound, "not_found") }
            try await AuditLog.record(AuditEvent(action: "auth.session_revoked", actor: c.user.id, subjectType: "session", subjectID: id.uuidString, requestID: requestID), on: s)
        }
    }

    // MARK: Registrierung (Bootstrap und Einladung)

    private func users(count s: any SQLDatabase) async throws -> Int64 {
        try await s.raw("SELECT count(*)::bigint AS n FROM users").first()?.decode(column: "n", as: Int64.self) ?? 0
    }

    /// AK-K1-1: Der erste Nutzer entsteht nur mit dem Setup-Token aus Env/Secret und nur, solange es noch keinen Nutzer gibt.
    func beginBootstrap(setupToken: String, handle: String, displayName: String, on db: any Database) async throws -> Options {
        guard let expected = settings.setupToken else { throw HubError(.notFound, "not_found") }
        try Self.validate(handle: handle, displayName: displayName)
        let lock = Self.bootstrapLock
        return try await inTransaction(db) { s in
            try await s.raw("SELECT pg_advisory_xact_lock(\(bind: lock))").run()
            guard try await users(count: s) == 0 else { throw HubError(.notFound, "not_found") }
            guard AuthSecrets.equal(AuthSecrets.hash(setupToken), AuthSecrets.hash(expected)) else { throw HubError(.forbidden, "setup_token_invalid") }
            let userID = UUID()
            let options = try passkeys.beginRegistration(userID: userID, userName: handle, displayName: displayName, excludeCredentialIDs: [])
            let id = try await createChallenge("bootstrap", options.challenge,
                                               payload: ["user_id": userID.uuidString, "handle": handle, "display_name": displayName], on: s)
            return Options(challengeID: id, options: options)
        }
    }

    func finishBootstrap(challengeID: UUID, credential: Data, requestID: String, on db: any Database) async throws -> AuthContext {
        guard settings.setupToken != nil else { throw HubError(.notFound, "not_found") }
        guard let ch = try await consumeChallenge(challengeID, purpose: "bootstrap", on: sql(db)) else { throw HubError(.badRequest, "passkey_invalid") }
        let lock = Self.bootstrapLock
        return try await inTransaction(db) { s in
            try await s.raw("SELECT pg_advisory_xact_lock(\(bind: lock))").run()
            guard try await users(count: s) == 0 else { throw HubError(.notFound, "not_found") }
            let user = try await createUser(from: ch, isAdmin: true, credential: credential, on: s)
            try await AuditLog.record(AuditEvent(action: "auth.bootstrap", actor: user.id, subjectType: "user", subjectID: user.id.uuidString, requestID: requestID), on: s)
            return try await issueSession(for: user, on: s)
        }
    }

    /// Prüft eine Einladung ohne sie zu verbrauchen. Unbekannt, abgelaufen und verbraucht sind nicht unterscheidbar.
    private func openInvitation(_ token: String, on s: any SQLDatabase) async throws -> UUID {
        guard let row = try await s.raw("""
            SELECT id FROM invitations WHERE token_hash = \(bind: AuthSecrets.hash(token)) AND used_at IS NULL AND expires_at > now()
            """).first() else { throw HubError(.gone, "invitation_invalid") }
        return try row.decode(column: "id", as: UUID.self)
    }

    func beginRegistration(inviteToken: String, handle: String, displayName: String, on db: any Database) async throws -> Options {
        try Self.validate(handle: handle, displayName: displayName)
        return try await inTransaction(db) { s in
            let invitationID = try await openInvitation(inviteToken, on: s)
            guard try await s.raw("SELECT 1 AS x FROM users WHERE handle = \(bind: handle)").first() == nil else { throw HubError(.conflict, "handle_taken") }
            let userID = UUID()
            let options = try passkeys.beginRegistration(userID: userID, userName: handle, displayName: displayName, excludeCredentialIDs: [])
            let id = try await createChallenge("registration", options.challenge,
                                               payload: ["user_id": userID.uuidString, "handle": handle, "display_name": displayName],
                                               invitationID: invitationID, on: s)
            return Options(challengeID: id, options: options)
        }
    }

    /// AK-K1-3: Die Einladung wird atomar eingelöst (zweite Verwendung scheitert), Ablauf nach DB-Zeit.
    func finishRegistration(challengeID: UUID, credential: Data, requestID: String, on db: any Database) async throws -> AuthContext {
        guard let ch = try await consumeChallenge(challengeID, purpose: "registration", on: sql(db)), let invitationID = ch.invitationID
        else { throw HubError(.badRequest, "passkey_invalid") }
        return try await inTransaction(db) { s in
            guard let used = try await s.raw("""
                UPDATE invitations SET used_at = now() WHERE id = \(bind: invitationID) AND used_at IS NULL AND expires_at > now() RETURNING created_by
                """).first() else { throw HubError(.gone, "invitation_invalid") }
            let user = try await createUser(from: ch, isAdmin: false, credential: credential, on: s)
            try await s.raw("UPDATE invitations SET used_by = \(bind: user.id) WHERE id = \(bind: invitationID)").run()
            try await AuditLog.record(AuditEvent(action: "auth.register", actor: user.id, subjectType: "user", subjectID: user.id.uuidString,
                                                 meta: ["invited_by": .safe(try used.decode(column: "created_by", as: UUID.self).uuidString)], requestID: requestID), on: s)
            return try await issueSession(for: user, on: s)
        }
    }

    /// Legt Nutzer und ersten Passkey an (in der Transaktion des Aufrufers).
    private func createUser(from ch: StoredChallenge, isAdmin: Bool, credential: Data, on s: any SQLDatabase) async throws -> AuthUser {
        guard let idString = ch.payload["user_id"], let id = UUID(uuidString: idString), let handle = ch.payload["handle"],
              let name = ch.payload["display_name"] else { throw HubError(.badRequest, "passkey_invalid") }
        let registration = try await verifyRegistration(challenge: ch.challenge, credential: credential, on: s)
        guard try await s.raw("""
            INSERT INTO users (id, handle, display_name, is_admin) VALUES (\(bind: id), \(bind: handle), \(bind: name), \(bind: isAdmin))
            ON CONFLICT (handle) DO NOTHING RETURNING id
            """).first() != nil else { throw HubError(.conflict, "handle_taken") }
        try await insertPasskey(registration, userID: id, name: "Passkey", on: s)
        return AuthUser(id: id, handle: handle, displayName: name, isAdmin: isAdmin)
    }

    private func verifyRegistration(challenge: Data, credential: Data, on s: any SQLDatabase) async throws -> PasskeyRegistration {
        do {
            return try await passkeys.finishRegistration(challenge: challenge, credentialJSON: credential) { credentialID in
                try await s.raw("SELECT 1 AS x FROM passkey_credentials WHERE credential_id = \(bind: credentialID)").first() == nil
            }
        } catch { throw HubError(.badRequest, "passkey_invalid") }
    }

    @discardableResult
    private func insertPasskey(_ r: PasskeyRegistration, userID: UUID, name: String, on s: any SQLDatabase) async throws -> UUID {
        guard let row = try await s.raw("""
            INSERT INTO passkey_credentials (user_id, credential_id, public_key, sign_count, name, backed_up)
            VALUES (\(bind: userID), \(bind: r.credentialID), \(bind: r.publicKey), \(bind: Int64(r.signCount)), \(bind: name), \(bind: r.backedUp))
            ON CONFLICT (credential_id) DO NOTHING RETURNING id
            """).first() else { throw HubError(.badRequest, "passkey_invalid") }
        return try row.decode(column: "id", as: UUID.self)
    }

    // MARK: Anmeldung

    func beginLogin(on db: any Database) async throws -> Options {
        let options = try passkeys.beginAuthentication()
        return Options(challengeID: try await createChallenge("authentication", options.challenge, on: sql(db)), options: options)
    }

    func finishLogin(challengeID: UUID, credential: Data, requestID: String, on db: any Database) async throws -> AuthContext {
        let failed = HubError(.unauthorized, "login_failed")
        guard let ch = try await consumeChallenge(challengeID, purpose: "authentication", on: sql(db)) else { throw failed }
        return try await inTransaction(db) { s in
            guard let info = try? passkeys.assertionInfo(credentialJSON: credential),
                  let row = try await s.raw("""
                    SELECT p.id, p.public_key, p.sign_count, u.id AS user_id, u.handle, u.display_name, u.is_admin
                    FROM passkey_credentials p JOIN users u ON u.id = p.user_id
                    WHERE p.credential_id = \(bind: info.credentialID) AND p.revoked_at IS NULL AND u.disabled_at IS NULL
                    """).first() else { throw failed }
            let userID = try row.decode(column: "user_id", as: UUID.self)
            guard info.userHandle == Data(userID.uuidString.utf8) else { throw failed }
            let result: PasskeyAssertionResult
            do {
                result = try passkeys.finishAuthentication(challenge: ch.challenge, credentialJSON: credential,
                                                           publicKey: try row.decode(column: "public_key", as: Data.self),
                                                           signCount: UInt32(clamping: try row.decode(column: "sign_count", as: Int64.self)))
            } catch { throw failed }
            try await s.raw("""
                UPDATE passkey_credentials SET sign_count = \(bind: Int64(result.newSignCount)), backed_up = \(bind: result.backedUp), last_used_at = now()
                WHERE id = \(bind: try row.decode(column: "id", as: UUID.self))
                """).run()
            let user = AuthUser(id: userID, handle: try row.decode(column: "handle", as: String.self),
                                displayName: try row.decode(column: "display_name", as: String.self), isAdmin: try row.decode(column: "is_admin", as: Bool.self))
            try await AuditLog.record(AuditEvent(action: "auth.login", actor: userID, subjectType: "user", subjectID: userID.uuidString, requestID: requestID), on: s)
            return try await issueSession(for: user, on: s)
        }
    }

    // MARK: Einladungen

    struct CreatedInvitation: Sendable { let id: UUID; let token: String; let expiresAt: Date }

    func createInvitation(by c: AuthContext, ttlSeconds: Int?, requestID: String, on db: any Database) async throws -> CreatedInvitation {
        let token = AuthSecrets.token()
        let ttl = ttlSeconds ?? settings.invitationTTL
        return try await inTransaction(db) { s in
            guard let row = try await s.raw("""
                INSERT INTO invitations (token_hash, created_by, expires_at)
                VALUES (\(bind: AuthSecrets.hash(token)), \(bind: c.user.id), now() + (\(bind: ttl)::bigint * interval '1 second')) RETURNING id, expires_at
                """).first() else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            try await AuditLog.record(AuditEvent(action: "auth.invitation_created", actor: c.user.id, subjectType: "invitation", subjectID: id.uuidString,
                                                 meta: ["ttl_seconds": .number(Int64(ttl))], requestID: requestID), on: s)
            return CreatedInvitation(id: id, token: token, expiresAt: try row.decode(column: "expires_at", as: Date.self))
        }
    }

    // MARK: Recovery-Codes

    static let recoveryCodeCount = 10

    /// AK-K1-4: Neue Codes ersetzen alle alten; Klartext wird nur hier zurückgegeben, in der DB steht nur der Hash.
    func generateRecoveryCodes(_ c: AuthContext, requestID: String, on db: any Database) async throws -> [String] {
        let codes = (0..<Self.recoveryCodeCount).map { _ in AuthSecrets.recoveryCode() }
        try await inTransaction(db) { s in
            try await s.raw("DELETE FROM recovery_codes WHERE user_id = \(bind: c.user.id)").run()
            for code in codes {
                try await s.raw("INSERT INTO recovery_codes (user_id, code_hash) VALUES (\(bind: c.user.id), \(bind: AuthSecrets.recoveryHash(user: c.user.id, code: code)))").run()
            }
            try await AuditLog.record(AuditEvent(action: "auth.recovery_codes_generated", actor: c.user.id, subjectType: "user", subjectID: c.user.id.uuidString,
                                                 meta: ["count": .number(Int64(codes.count))], requestID: requestID), on: s)
        }
        return codes
    }

    func recoveryCodesRemaining(_ c: AuthContext, on db: any Database) async throws -> Int {
        Int(try await sql(db).raw("SELECT count(*)::bigint AS n FROM recovery_codes WHERE user_id = \(bind: c.user.id) AND used_at IS NULL")
            .first()?.decode(column: "n", as: Int64.self) ?? 0)
    }

    /// Meldet mit einem Recovery-Code an (einmalig verwendbar). Ergebnis ist eine eingeschränkte Notfall-Sitzung
    /// (nur neuen Passkey anlegen, Sitzung beenden). Fehler sind einheitlich `login_failed`.
    func recoveryLogin(handle: String, code: String, requestID: String, on db: any Database) async throws -> AuthContext {
        let failed = HubError(.unauthorized, "login_failed")
        return try await inTransaction(db) { s in
            guard let row = try await s.raw("SELECT id, handle, display_name, is_admin FROM users WHERE handle = \(bind: handle) AND disabled_at IS NULL").first() else { throw failed }
            let userID = try row.decode(column: "id", as: UUID.self)
            guard try await s.raw("""
                UPDATE recovery_codes SET used_at = now()
                WHERE user_id = \(bind: userID) AND code_hash = \(bind: AuthSecrets.recoveryHash(user: userID, code: code)) AND used_at IS NULL RETURNING id
                """).first() != nil else { throw failed }
            let user = AuthUser(id: userID, handle: handle, displayName: try row.decode(column: "display_name", as: String.self),
                                isAdmin: try row.decode(column: "is_admin", as: Bool.self))
            try await AuditLog.record(AuditEvent(action: "auth.recovery_login", actor: userID, subjectType: "user", subjectID: userID.uuidString, requestID: requestID), on: s)
            return try await issueSession(for: user, kind: .recovery, on: s)
        }
    }

    // MARK: Passkeys des Nutzers

    struct PasskeyInfo: Sendable { let id: UUID; let name: String; let createdAt: Date; let lastUsedAt: Date?; let backedUp: Bool }

    func passkeyList(_ c: AuthContext, on db: any Database) async throws -> [PasskeyInfo] {
        try await sql(db).raw("""
            SELECT id, name, created_at, last_used_at, backed_up FROM passkey_credentials
            WHERE user_id = \(bind: c.user.id) AND revoked_at IS NULL ORDER BY created_at, id
            """).all().map { r in
            PasskeyInfo(id: try r.decode(column: "id", as: UUID.self), name: try r.decode(column: "name", as: String.self),
                        createdAt: try r.decode(column: "created_at", as: Date.self), lastUsedAt: try r.decode(column: "last_used_at", as: Date?.self),
                        backedUp: try r.decode(column: "backed_up", as: Bool.self))
        }
    }

    func beginAddPasskey(_ c: AuthContext, on db: any Database) async throws -> Options {
        try await inTransaction(db) { s in
            let existing = try await s.raw("SELECT credential_id FROM passkey_credentials WHERE user_id = \(bind: c.user.id) AND revoked_at IS NULL").all()
                .map { try $0.decode(column: "credential_id", as: Data.self) }
            let options = try passkeys.beginRegistration(userID: c.user.id, userName: c.user.handle, displayName: c.user.displayName, excludeCredentialIDs: existing)
            let id = try await createChallenge("add_passkey", options.challenge, payload: ["session_id": c.sessionID.uuidString], userID: c.user.id, on: s)
            return Options(challengeID: id, options: options)
        }
    }

    /// Eine Notfall-Sitzung wird durch den neuen Passkey zur normalen Sitzung hochgestuft.
    func finishAddPasskey(_ c: AuthContext, challengeID: UUID, credential: Data, name: String?, requestID: String, on db: any Database) async throws -> PasskeyInfo {
        let label = name ?? "Passkey"
        guard (1...80).contains(label.count) else {
            throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "name", code: "invalid")])
        }
        guard let ch = try await consumeChallenge(challengeID, purpose: "add_passkey", on: sql(db)), ch.userID == c.user.id,
              ch.payload["session_id"] == c.sessionID.uuidString else { throw HubError(.badRequest, "passkey_invalid") }
        let ttl = settings.sessionTTL
        let id = try await inTransaction(db) { s in
            let registration = try await verifyRegistration(challenge: ch.challenge, credential: credential, on: s)
            let id = try await insertPasskey(registration, userID: c.user.id, name: label, on: s)
            if c.kind == .recovery {
                try await s.raw("""
                    UPDATE sessions SET kind = 'normal', expires_at = now() + (\(bind: ttl)::bigint * interval '1 second') WHERE id = \(bind: c.sessionID)
                    """).run()
            }
            try await AuditLog.record(AuditEvent(action: "auth.passkey_added", actor: c.user.id, subjectType: "passkey", subjectID: id.uuidString, requestID: requestID), on: s)
            return id
        }
        guard let info = try await passkeyList(c, on: db).first(where: { $0.id == id }) else { throw Abort(.internalServerError) }
        return info
    }

    /// Fremde ID: 404. Der letzte aktive Passkey bleibt erhalten (sonst Aussperrung).
    func revokePasskey(_ id: UUID, _ c: AuthContext, requestID: String, on db: any Database) async throws {
        try await inTransaction(db) { s in
            // Zeilensperre auf alle aktiven Passkeys des Nutzers: parallele Widerrufe können nicht beide den "zweiten" entfernen.
            let active = try await s.raw("SELECT id FROM passkey_credentials WHERE user_id = \(bind: c.user.id) AND revoked_at IS NULL FOR UPDATE").all()
                .map { try $0.decode(column: "id", as: UUID.self) }
            guard active.contains(id) else { throw HubError(.notFound, "not_found") }
            guard active.count > 1 else { throw HubError(.conflict, "last_passkey") }
            try await s.raw("UPDATE passkey_credentials SET revoked_at = now() WHERE id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "auth.passkey_revoked", actor: c.user.id, subjectType: "passkey", subjectID: id.uuidString, requestID: requestID), on: s)
        }
    }
}
