import Vapor
import SQLKit

// WP-D3: lesender Dienst für das Kontakt-Matching (DMS-Korrespondent). Neue Datei, die bestehenden Kontakt-Dateien bleiben unverändert.
// Liefert pro aktivem Kontakt (weder gelöscht noch zusammengeführt) die Schlüssel USt-ID, IBAN, Name und Aliase des Mandanten in fester Reihenfolge.

struct ContactMatchKey: Sendable, Equatable {
    enum Signal: String, Sendable { case vat, iban, name, alias }
    let contactID: UUID
    let signal: Signal
    let key: String
}

extension ContactService {
    /// Obergrenze der Schlüssel je Mandant (Schutz des Speichers; darüber wird abgeschnitten).
    static let matchKeyLimit = 50_000

    /// Alle Abgleichschlüssel des Mandanten, sortiert nach (Kontakt, Signal, Schlüssel): gleiche Daten, gleiche Reihenfolge.
    static func matchKeys(tenant: UUID, on s: any SQLDatabase) async throws -> [ContactMatchKey] {
        let rows = try await s.raw("""
            SELECT id, signal, key FROM (
              SELECT c.id, 'vat' AS signal, c.vat_id AS key FROM contacts c
                WHERE c.tenant_id = \(bind: tenant) AND c.deleted_at IS NULL AND c.merged_into IS NULL AND c.vat_id IS NOT NULL
              UNION ALL
              SELECT c.id, 'iban', b.iban FROM contact_bank_accounts b JOIN contacts c ON c.id = b.contact_id
                WHERE c.tenant_id = \(bind: tenant) AND b.tenant_id = \(bind: tenant) AND c.deleted_at IS NULL AND c.merged_into IS NULL
              UNION ALL
              SELECT c.id, 'name', c.display_name FROM contacts c
                WHERE c.tenant_id = \(bind: tenant) AND c.deleted_at IS NULL AND c.merged_into IS NULL
              UNION ALL
              SELECT c.id, 'name', c.company_name FROM contacts c
                WHERE c.tenant_id = \(bind: tenant) AND c.deleted_at IS NULL AND c.merged_into IS NULL AND c.company_name IS NOT NULL
              UNION ALL
              SELECT c.id, 'alias', a.alias FROM contact_aliases a JOIN contacts c ON c.id = a.contact_id
                WHERE c.tenant_id = \(bind: tenant) AND a.tenant_id = \(bind: tenant) AND c.deleted_at IS NULL AND c.merged_into IS NULL
            ) k ORDER BY id, signal, key LIMIT \(bind: matchKeyLimit)
            """).all()
        return try rows.compactMap { r in
            guard let signal = ContactMatchKey.Signal(rawValue: try r.decode(column: "signal", as: String.self)) else { return nil }
            return ContactMatchKey(contactID: try r.decode(column: "id", as: UUID.self), signal: signal, key: try r.decode(column: "key", as: String.self))
        }
    }
}
