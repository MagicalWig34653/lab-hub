import Foundation

// WP-D3 Kontakt-Matching (MODUL-DMS 5.4): Korrespondent aus dem Text. Signale in absteigender Verlässlichkeit: IBAN (exakt), USt-ID (exakt, Ziffernfolge endet),
// Alias (ganze Wörter), Name (ganze Wörter). Deterministisch: feste Konfidenzen, feste Sortierung (Konfidenz absteigend, dann Kontakt-ID), höchstens drei Vorschläge.
// Kein Fuzzy-Matching im Fließtext (zu viele Fehltreffer bei OCR-Rauschen); Tippfehler-Abgleich wäre ein eigener Schritt (offen im Handoff).

enum DMSContactMatch {
    static let minNameLength = 4
    static let maxSuggestions = 5

    static func baseConfidence(_ s: ContactMatchKey.Signal) -> Double {
        switch s { case .iban: 0.99; case .vat: 0.97; case .alias: 0.85; case .name: 0.80 }
    }

    /// Kleinschreibung, ohne Akzente, alles außer Buchstaben/Ziffern wird zu einem Leerzeichen, Leerräume zusammengefasst.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = ""
        var lastSpace = true
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { out.unicodeScalars.append(ch); lastSpace = false }
            else if !lastSpace { out.append(" "); lastSpace = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Nur A–Z und 0–9 in Großschreibung (IBAN und USt-ID stehen im Text mit Leerzeichen).
    static func compact(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for ch in s.uppercased().unicodeScalars where (ch.value >= 48 && ch.value <= 57) || (ch.value >= 65 && ch.value <= 90) { out.append(ch) }
        return String(out)
    }

    private static func containsWithEndBoundary(_ haystack: String, _ key: String) -> Bool {
        var from = haystack.startIndex
        while let r = haystack.range(of: key, range: from..<haystack.endIndex) {
            if r.upperBound == haystack.endIndex || !(haystack[r.upperBound].isNumber) { return true }
            from = r.upperBound
        }
        return false
    }

    private struct Found { var signals: [ContactMatchKey.Signal: String] = [:] }

    static func suggestions(keys: [ContactMatchKey], text: String, currentCorrespondent: UUID?) -> [SuggestionCandidate] {
        guard !keys.isEmpty, !text.isEmpty else { return [] }
        let compactText = compact(text)
        let norm = " " + normalize(text) + " "
        let tokens = Set(norm.split(separator: " ").map(String.init))
        var found: [UUID: Found] = [:]
        for k in keys where k.contactID != currentCorrespondent {
            switch k.signal {
            case .iban:
                let key = compact(k.key)
                if key.count >= 15, compactText.contains(key) { found[k.contactID, default: Found()].signals[.iban] = "IBAN …" + key.suffix(4) }
            case .vat:
                let key = compact(k.key)
                if key.count >= 6, containsWithEndBoundary(compactText, key) { found[k.contactID, default: Found()].signals[.vat] = "USt-ID " + key }
            case .name, .alias:
                let n = normalize(k.key)
                guard n.count >= minNameLength else { continue }
                let parts = n.split(separator: " ").map(String.init)
                guard parts.allSatisfy(tokens.contains), norm.contains(" " + n + " ") else { continue }
                let label = (k.signal == .alias ? "Alias „" : "Name „") + DMSRuleEngine.excerpt(k.key, max: 60) + "“"
                // je Signal der längste Treffer (deterministisch bei mehreren Namen)
                if let existing = found[k.contactID]?.signals[k.signal], existing.count >= label.count { continue }
                found[k.contactID, default: Found()].signals[k.signal] = label
            }
        }
        let order: [ContactMatchKey.Signal] = [.iban, .vat, .alias, .name]
        var out: [SuggestionCandidate] = []
        for (contact, f) in found {
            guard let strongest = order.first(where: { f.signals[$0] != nil }) else { continue }
            let others = f.signals.count - 1
            let confidence = min(0.999, ((baseConfidence(strongest) + 0.005 * Double(others)) * 1000).rounded() / 1000)
            let reason = "Kontakt-Abgleich, Treffer " + f.signals[strongest]! + (others > 0 ? " (+\(others) weitere Übereinstimmung\(others > 1 ? "en" : ""))" : "")
            let id = contact.uuidString.lowercased()
            out.append(SuggestionCandidate(kind: "correspondent", value: ["contact_id": id], valueKey: id, source: "contact_match", ruleID: nil, ruleVersion: nil,
                                           confidence: confidence, reason: reason,
                                           evidence: ["signals": order.filter { f.signals[$0] != nil }.map(\.rawValue).joined(separator: ",")], automatic: false))
        }
        out.sort { ($0.confidence, $1.valueKey) > ($1.confidence, $0.valueKey) }
        return Array(out.prefix(maxSuggestions))
    }
}
