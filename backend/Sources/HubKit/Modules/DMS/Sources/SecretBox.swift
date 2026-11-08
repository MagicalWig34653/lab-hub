import Foundation
import Crypto

// WP-D4: Verschlüsselung der Quellen-Zugangsdaten (Mail-Passwort) in der Datenbank. Nie Klartext in DB, Log oder Audit.
// Schlüssel: `SECRET_KEY` / `SECRET_KEY_FILE` aus der Umgebung (HubConfig.secretKey, in compose/swarm als Secret vorhanden), per HKDF-SHA256 zu einem
// 256-Bit-Schlüssel abgeleitet (Verwendungszweck im `info`). AES-256-GCM mit zufälligem 96-Bit-Nonce je Wert; die zugehörigen Daten (AAD) binden den
// Geheimtext an Mandant und Quelle (kopierte Zeilen lassen sich nicht in eine andere Quelle verschieben). Format: `v1:<base64(nonce|ciphertext|tag)>`;
// das Präfix erlaubt später einen Schlüsselwechsel (Neuverschlüsseln pro Version). Wer SECRET_KEY verliert, muss die Passwörter neu eintragen.

struct SecretBox: Sendable {
    /// WP-H10 (Befund 7): mindestens 32 Byte (z. B. liefert `openssl rand -base64 32` 44 Zeichen). Kürzere Schlüssel werden nicht verwendet.
    static let minimumKeyLength = 32
    private let key: SymmetricKey

    enum Failure: Error, Equatable { case keyMissing, invalidFormat, authenticationFailed }

    /// Meldung für Start/Anlegen, wenn ein Schlüssel gesetzt, aber zu kurz ist.
    static let tooShortMessage = "SECRET_KEY ist zu kurz: mindestens 32 Byte erforderlich (Erzeugung: openssl rand -base64 32)."

    /// Ein gesetzter, aber zu kurzer Schlüssel ist ein Konfigurationsfehler (nicht „kein Schlüssel“).
    static func isTooShort(_ secretKey: String?) -> Bool {
        guard let secretKey, !secretKey.isEmpty else { return false }
        return secretKey.utf8.count < minimumKeyLength
    }

    /// `nil`, wenn der Schlüssel fehlt oder zu kurz ist (kein stiller Rückfall auf einen schwachen Schlüssel).
    init?(secretKey: String?) {
        guard let secretKey, secretKey.utf8.count >= Self.minimumKeyLength else { return nil }
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secretKey.utf8)), salt: Data("labhub-secret-box".utf8),
                                     info: Data("dms-source-credentials v1".utf8), outputByteCount: 32)
    }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SecretBox? {
        SecretBox(secretKey: (try? HubConfig.value("SECRET_KEY", env)) ?? nil)
    }

    private static func aad(tenant: UUID, source: UUID) -> Data { Data("dms-source|\(tenant.uuidString.lowercased())|\(source.uuidString.lowercased())".utf8) }

    func seal(_ plaintext: String, tenant: UUID, source: UUID) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: Self.aad(tenant: tenant, source: source))
        guard let combined = box.combined else { throw Failure.invalidFormat }
        return "v1:" + combined.base64EncodedString()
    }

    func open(_ sealed: String, tenant: UUID, source: UUID) throws -> String {
        guard sealed.hasPrefix("v1:"), let data = Data(base64Encoded: String(sealed.dropFirst(3))) else { throw Failure.invalidFormat }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: key, authenticating: Self.aad(tenant: tenant, source: source))
            guard let s = String(data: plain, encoding: .utf8) else { throw Failure.invalidFormat }
            return s
        } catch let f as Failure { throw f } catch { throw Failure.authenticationFailed }
    }
}
