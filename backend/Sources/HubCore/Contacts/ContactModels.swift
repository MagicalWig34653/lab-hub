import Vapor
import Foundation

// WP-K5: Ein- und Ausgabeformate der Kontakte. Felder in snake_case wie im Vertrag (contracts/openapi.yaml).

package struct AddressDTO: Content, Sendable, Equatable {
    var label: String?
    var street: String?
    var postal_code: String?
    var city: String?
    var country: String?
}

package struct EmailDTO: Content, Sendable, Equatable {
    var email: String
    var label: String?
}

package struct BankAccountDTO: Content, Sendable, Equatable {
    var iban: String
    var bic: String?
    var holder: String?
}

/// Eingabe für Anlegen (`display_name`, `kind` Pflicht) und Ändern (nur gesetzte Felder; Listen ersetzen die bisherige Liste vollständig).
package struct ContactBody: Content, Sendable {
    package var kind: String?
    package var display_name: String?
    var first_name: String?
    var last_name: String?
    var company_name: String?
    var vat_id: String?
    var is_customer: Bool?
    var is_supplier: Bool?
    package var is_correspondent: Bool?
    package var note: String?
    package var addresses: [AddressDTO]?
    var emails: [EmailDTO]?
    var bank_accounts: [BankAccountDTO]?
    var aliases: [String]?
    package init(kind: String? = nil, display_name: String? = nil, first_name: String? = nil, last_name: String? = nil, company_name: String? = nil, vat_id: String? = nil, is_customer: Bool? = nil, is_supplier: Bool? = nil, is_correspondent: Bool? = nil, note: String? = nil, addresses: [AddressDTO]? = nil, emails: [EmailDTO]? = nil, bank_accounts: [BankAccountDTO]? = nil, aliases: [String]? = nil) {
        self.kind = kind; self.display_name = display_name; self.first_name = first_name; self.last_name = last_name; self.company_name = company_name; self.vat_id = vat_id; self.is_customer = is_customer; self.is_supplier = is_supplier; self.is_correspondent = is_correspondent; self.note = note; self.addresses = addresses; self.emails = emails; self.bank_accounts = bank_accounts; self.aliases = aliases
    }
}

package struct DuplicateHint: Content, Sendable, Equatable {
    package let id: UUID
    let display_name: String
    /// `vat_id` und/oder `iban`
    let reasons: [String]
}

package struct ContactOut: Content, Sendable {
    package let id: UUID
    package let kind: String
    let display_name: String
    let first_name: String?
    let last_name: String?
    let company_name: String?
    let vat_id: String?
    let is_customer: Bool
    let is_supplier: Bool
    let is_correspondent: Bool
    let note: String?
    let merged_into: UUID?
    let created_at: String
    let updated_at: String
    var addresses: [AddressDTO]?
    var emails: [EmailDTO]?
    var bank_accounts: [BankAccountDTO]?
    var aliases: [String]?
    /// Nur bei Anlegen/Ändern: Hinweis auf mögliche Dubletten (nie ein Fehler, nie stilles Zusammenführen).
    var duplicates: [DuplicateHint]?
}

package struct LinkOut: Content, Sendable {
    package let id: UUID
    package let from_type: String
    let from_id: UUID
    package let to_type: String
    package let to_id: UUID
    package let kind: String
    let source: String
    let created_by: UUID?
    let created_at: String
    let removed_at: String?
    let removed_by: UUID?
}

package struct LinkBody: Content, Sendable {
    package var from_type: String?
    package var from_id: UUID?
    package var to_type: String?
    package var to_id: UUID?
    package var kind: String?
    package var source: String?
    package init(from_type: String? = nil, from_id: UUID? = nil, to_type: String? = nil, to_id: UUID? = nil, kind: String? = nil, source: String? = nil) {
        self.from_type = from_type; self.from_id = from_id; self.to_type = to_type; self.to_id = to_id; self.kind = kind; self.source = source
    }
}

struct MergeBody: Content, Sendable { var source_id: UUID? }

struct MergeResult: Content, Sendable {
    let contact: ContactOut
    let merged_id: UUID
    let links_rewritten: Int
    let links_removed: Int
}

package enum ContactValidation {
    package static func fail(_ field: String, _ code: String = "invalid") -> HubError {
        HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: field, code: code)])
    }

    /// Leerer Text zählt als nicht gesetzt.
    package static func text(_ v: String?, _ field: String, max: Int = 200) throws -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        guard t.count <= max else { throw fail(field, "too_long") }
        return t
    }

    package static func vatID(_ v: String?) throws -> String? {
        guard let raw = v, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let n = raw.uppercased().filter { !$0.isWhitespace && $0 != "." && $0 != "-" }
        guard n.range(of: "^[A-Z]{2}[A-Z0-9]{2,12}$", options: .regularExpression) != nil else { throw fail("vat_id") }
        return n
    }

    /// Normalisiert (Großbuchstaben, ohne Leerzeichen) und prüft Länge und Prüfziffer (ISO 7064 mod 97-10).
    package static func iban(_ v: String, _ field: String) throws -> String {
        let n = v.uppercased().filter { !$0.isWhitespace }
        guard n.range(of: "^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$", options: .regularExpression) != nil, mod97(n) == 1 else { throw fail(field) }
        return n
    }

    static func mod97(_ iban: String) -> Int {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var rem = 0
        for ch in rearranged {
            let digits: String
            if let d = ch.wholeNumberValue, ch.isASCII { digits = String(d) }
            else if let a = ch.asciiValue, (65...90).contains(a) { digits = String(Int(a) - 55) }
            else { return -1 }
            for d in digits { rem = (rem * 10 + Int(String(d))!) % 97 }
        }
        return rem
    }

    package static func email(_ v: String, _ field: String) throws -> String {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 254, t.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil else { throw fail(field) }
        return t
    }

    package static func country(_ v: String?, _ field: String) throws -> String? {
        guard let t = try text(v, field, max: 2) else { return nil }
        let c = t.uppercased()
        guard c.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { throw fail(field) }
        return c
    }
}

/// Auf nachgeprüfte Werte normalisierte Eingabe.
package struct ContactFields: Sendable {
    package var kind: String?
    var displayName: String?
    var firstName: String??, lastName: String??, companyName: String??, vatID: String??, note: String??
    var isCustomer: Bool?, isSupplier: Bool?, isCorrespondent: Bool?
    package var addresses: [AddressDTO]?
    var emails: [EmailDTO]?
    var banks: [BankAccountDTO]?
    var aliases: [String]?

    static let maxChildren = 50

    package init(_ b: ContactBody, creating: Bool) throws {
        if let k = b.kind {
            guard ["person", "organization"].contains(k) else { throw ContactValidation.fail("kind") }
            kind = k
        } else if creating { throw ContactValidation.fail("kind", "required") }
        if b.display_name != nil || creating {
            guard let n = try ContactValidation.text(b.display_name, "display_name") else { throw ContactValidation.fail("display_name", "required") }
            displayName = n
        }
        if b.first_name != nil { firstName = .some(try ContactValidation.text(b.first_name, "first_name")) }
        if b.last_name != nil { lastName = .some(try ContactValidation.text(b.last_name, "last_name")) }
        if b.company_name != nil { companyName = .some(try ContactValidation.text(b.company_name, "company_name")) }
        if b.vat_id != nil { vatID = .some(try ContactValidation.vatID(b.vat_id)) }
        if b.note != nil { note = .some(try ContactValidation.text(b.note, "note", max: 4000)) }
        isCustomer = b.is_customer; isSupplier = b.is_supplier; isCorrespondent = b.is_correspondent
        if let a = b.addresses {
            guard a.count <= Self.maxChildren else { throw ContactValidation.fail("addresses", "too_many") }
            addresses = try a.enumerated().map { i, x in
                AddressDTO(label: try ContactValidation.text(x.label, "addresses[\(i)].label", max: 80),
                           street: try ContactValidation.text(x.street, "addresses[\(i)].street"),
                           postal_code: try ContactValidation.text(x.postal_code, "addresses[\(i)].postal_code", max: 20),
                           city: try ContactValidation.text(x.city, "addresses[\(i)].city"),
                           country: try ContactValidation.country(x.country, "addresses[\(i)].country"))
            }
        }
        if let e = b.emails {
            guard e.count <= Self.maxChildren else { throw ContactValidation.fail("emails", "too_many") }
            var seen = Set<String>()
            emails = try e.enumerated().compactMap { i, x in
                let v = try ContactValidation.email(x.email, "emails[\(i)].email")
                guard seen.insert(v.lowercased()).inserted else { return nil }
                return EmailDTO(email: v, label: try ContactValidation.text(x.label, "emails[\(i)].label", max: 80))
            }
        }
        if let k = b.bank_accounts {
            guard k.count <= Self.maxChildren else { throw ContactValidation.fail("bank_accounts", "too_many") }
            var seen = Set<String>()
            banks = try k.enumerated().compactMap { i, x in
                let v = try ContactValidation.iban(x.iban, "bank_accounts[\(i)].iban")
                guard seen.insert(v).inserted else { return nil }
                return BankAccountDTO(iban: v, bic: try ContactValidation.text(x.bic, "bank_accounts[\(i)].bic", max: 11)?.uppercased(),
                                      holder: try ContactValidation.text(x.holder, "bank_accounts[\(i)].holder"))
            }
        }
        if let al = b.aliases {
            guard al.count <= Self.maxChildren else { throw ContactValidation.fail("aliases", "too_many") }
            var seen = Set<String>()
            aliases = try al.enumerated().compactMap { i, x in
                guard let v = try ContactValidation.text(x, "aliases[\(i)]") else { return nil }
                return seen.insert(v.lowercased()).inserted ? v : nil
            }
        }
    }
}
