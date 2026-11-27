/// WP-H10 (Befund 7): Mindestlänge von `SECRET_KEY` (z. B. liefert `openssl rand -base64 32` 44 Zeichen). Der Start prüft sie hier im Kern,
/// Verschlüsselung mit dem Schlüssel gehört dem Modul, das Geheimnisse speichert. Kürzere Schlüssel werden nicht verwendet.
package enum SecretKeyRule {
    package static let minimumLength = 32

    /// Meldung für Start/Anlegen, wenn ein Schlüssel gesetzt, aber zu kurz ist.
    package static let tooShortMessage = "SECRET_KEY ist zu kurz: mindestens 32 Byte erforderlich (Erzeugung: openssl rand -base64 32)."

    /// Ein gesetzter, aber zu kurzer Schlüssel ist ein Konfigurationsfehler (nicht „kein Schlüssel“).
    package static func isTooShort(_ secretKey: String?) -> Bool {
        guard let secretKey, !secretKey.isEmpty else { return false }
        return secretKey.utf8.count < minimumLength
    }
}
