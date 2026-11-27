import Foundation

// WP-R6b: bereitet die eingefrorenen Belegdaten für die Vorlage auf. Die Vorlage bekommt nur fertige Zeichenketten: gerechnet und formatiert wird
// hier mit `Decimal` (nie Gleitkomma). Summen je Beleg sind die gespeicherten Werte; nur Positionswerte und die Zwischensumme entstehen hier.
// Die interne Notiz (`note`) wird nicht gedruckt.

enum InvoiceRenderFormat {
    /// `1234567.5` → `1.234.567,50`; Nachkommastellen: mindestens `minFraction`, weitere nur wenn ungleich null.
    static func number(_ value: String, minFraction: Int = 0) -> String {
        let negative = value.hasPrefix("-")
        let parts = (negative ? String(value.dropFirst()) : value).split(separator: ".", maxSplits: 1)
        let integer = String(parts.first ?? "0")
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        while fraction.count > minFraction, fraction.hasSuffix("0") { fraction.removeLast() }
        while fraction.count < minFraction { fraction += "0" }
        var grouped = ""
        for (i, digit) in integer.enumerated() {
            if i > 0, (integer.count - i) % 3 == 0 { grouped += "." }
            grouped.append(digit)
        }
        let zero = (integer + fraction).allSatisfy { $0 == "0" }
        return (negative && !zero ? "-" : "") + grouped + (fraction.isEmpty ? "" : "," + fraction)
    }

    static func money(_ value: String, currency: String) -> String { number(value, minFraction: 2) + " " + (currency == "EUR" ? "€" : currency) }

    /// `2026-11-03` → `03.11.2026`
    static func date(_ iso: String) -> String { iso.split(separator: "-").reversed().joined(separator: ".") }
}

struct InvoiceRenderData: Encodable, Sendable {
    struct Column: Encodable, Sendable { let key: String; let label: String }
    struct Row: Encodable, Sendable { let kind: String; let cells: [String]; var detail: String?; var text: String? }
    struct Total: Encodable, Sendable { let label: String; let value: String; var strong = false }
    struct Pair: Encodable, Sendable { let label: String; let value: String }
    struct Prepared: Sendable { let data: InvoiceRenderData; let createdAt: Int }
    /// WP-R6d: Parameter des Layouts für die Vorlage (fertige Zeichenketten, Platzhalter schon ersetzt). Fehlt er, rendert das Standardlayout wie in R6b.
    struct Layout: Encodable, Sendable {
        struct Logo: Encodable, Sendable { let file: String; let width: Int; let align: String }
        let font: String, accent: String, text: String
        var logo: Logo?
        var headerText: String?, footerText: String?
    }

    var title = "", number = "", senderName = "", senderLine = ""
    var senderLines: [String] = [], recipientLines: [String] = []
    var meta: [Pair] = []
    var headerText: String?
    var columns: [Column] = []
    var rows: [Row] = []
    var totals: [Total] = []
    var notes: [String] = []
    var footerText: String?
    var footerColumns: [[String]] = []
    var attach = false
    var layout: Layout?
    /// WP-R6d: Vorschau eines Entwurfs (Hinweis auf jeder Seite, keine Nummer).
    var preview: Bool?

    /// Wortlaut fachlich zu prüfen (`docs/OFFENE-FRAGEN.md` F-38).
    static let smallBusinessNote = "Gemäß § 19 UStG wird keine Umsatzsteuer berechnet (Kleinunternehmerregelung)."

    // MARK: Eingabe (Teilmenge von `InvoiceDocuments.fullJSON`)

    private struct Document: Decodable {
        struct Line: Decodable {
            let kind, description: String
            let unit, quantity, second_quantity, unit_price, tax_rate, discount_kind, discount_value: String?
        }
        struct Charge: Decodable { let description, tax_rate, amount: String }
        struct TaxTotal: Decodable { let rate, net, tax: String }
        struct Sender: Decodable { let sender_name, street, postal_code, city, country, tax_number, vat_id, email, phone, website, bank_name, iban, bic: String? }
        struct Address: Decodable { let street, postal_code, city, country: String? }
        struct Recipient: Decodable { let display_name, first_name, last_name, company_name, vat_id: String?; let address: Address? }

        let kind, status, issue_date, currency, price_mode, net_total, gross_total, discount_total, rounding_mode: String
        let number, due_date, delivery_date, discount_percent, discount_amount, header_text, footer_text, tax_regime, finalized_at, skonto_percent: String?
        let skonto_days: Int?
        let lines: [Line]
        let charges: [Charge]
        let tax_totals: [TaxTotal]
        let sender: Sender?
        let recipient: Recipient?
    }

    private static let titles = [
        "quote": ("Angebot", "Angebotsnummer", "Datum"), "order_confirmation": ("Auftragsbestätigung", "Auftragsnummer", "Datum"),
        "delivery_note": ("Lieferschein", "Lieferscheinnummer", "Datum"), "invoice": ("Rechnung", "Rechnungsnummer", "Rechnungsdatum"),
        "credit_note": ("Gutschrift", "Gutschriftnummer", "Datum")
    ]

    private static func decimal(_ s: String) throws -> Decimal {
        guard let d = InvoiceDecimal.parse(s) else { throw InvoiceRenderError.invalidDocument("amount") }
        return d
    }

    private static func timestamp(_ s: String) -> Int? {
        // Postgres liefert Mikrosekunden; der PDF-Zeitstempel kennt nur Sekunden
        ISO8601DateFormatter().date(from: s.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)).map { Int($0.timeIntervalSince1970) }
    }

    private static func present(_ values: String?...) -> [String] { values.compactMap { $0 }.filter { !$0.isEmpty } }
    private static func joined(_ values: [String], _ separator: String = " ") -> String? { values.isEmpty ? nil : values.joined(separator: separator) }

    static func prepare(_ documentJSON: Data, attach: Bool, layout: InvoiceRenderLayout? = nil) throws -> Prepared {
        let doc: Document
        do { doc = try JSONDecoder().decode(Document.self, from: documentJSON) } catch { throw InvoiceRenderError.invalidDocument("json") }
        guard doc.status != "draft", let number = doc.number, let finalized = doc.finalized_at, let sender = doc.sender, let recipient = doc.recipient
        else { throw InvoiceRenderError.notFinal }
        guard let (title, numberLabel, dateLabel) = titles[doc.kind] else { throw InvoiceRenderError.invalidDocument("kind") }
        guard let createdAt = timestamp(finalized) else { throw InvoiceRenderError.invalidDocument("finalized_at") }
        if attach, doc.kind != "invoice", doc.kind != "credit_note" { throw InvoiceRenderError.invalidDocument("attachment_not_allowed") }

        let priced = doc.kind != "delivery_note"
        var data = InvoiceRenderData(title: title, number: number, attach: attach)
        data.headerText = doc.header_text
        data.footerText = doc.footer_text
        if doc.status == "preview" { data.preview = true }

        // Briefkopf und Fußzeile
        data.senderName = sender.sender_name ?? ""
        let cityLine = joined(present(sender.postal_code, sender.city))
        data.senderLine = present(sender.sender_name, sender.street, cityLine).joined(separator: " · ")
        data.senderLines = present(sender.street, cityLine, sender.phone.map { "Tel. " + $0 }, sender.email, sender.website)
        data.footerColumns = [
            present(sender.sender_name, sender.street, cityLine),
            present(sender.tax_number.map { "Steuernummer: " + $0 }, sender.vat_id.map { "USt-IdNr.: " + $0 }),
            present(sender.bank_name, sender.iban.map { "IBAN: " + $0 }, sender.bic.map { "BIC: " + $0 })
        ]

        // Empfänger
        let person = joined(present(recipient.first_name, recipient.last_name))
        var lines = present(recipient.company_name, person)
        if lines.isEmpty { lines = present(recipient.display_name) }
        if let address = recipient.address {
            lines += present(address.street, joined(present(address.postal_code, address.city)))
            if let country = address.country, !country.isEmpty, country != (sender.country ?? "DE") { lines.append(country) }
        }
        data.recipientLines = lines

        // Kopfdaten
        func pair(_ label: String, _ value: String?) { if let value, !value.isEmpty { data.meta.append(.init(label: label, value: value)) } }
        pair(numberLabel, number)
        pair(dateLabel, InvoiceRenderFormat.date(doc.issue_date))
        pair(["quote", "delivery_note"].contains(doc.kind) ? "Lieferdatum" : "Liefer-/Leistungsdatum", doc.delivery_date.map(InvoiceRenderFormat.date))
        if doc.kind == "invoice" { pair("Fällig am", doc.due_date.map(InvoiceRenderFormat.date)) }
        if doc.kind == "quote" { pair("Gültig bis", doc.due_date.map(InvoiceRenderFormat.date)) }
        if priced { pair("Ihre USt-IdNr.", recipient.vat_id) }

        // Positionen
        let gross = doc.price_mode == "gross"
        func money(_ s: String) -> String { InvoiceRenderFormat.money(s, currency: doc.currency) }
        let rounding = InvoiceRounding(mode: InvoiceRounding.Mode(rawValue: doc.rounding_mode) ?? .halfAwayFromZero, scale: 2)
        func amount(_ d: Decimal) -> String { money(InvoiceDecimal.string(d, scale: 2)) }
        data.columns = [.init(key: "position", label: "Pos."), .init(key: "description", label: "Beschreibung"), .init(key: "quantity", label: "Menge")]
        if priced {
            data.columns += [.init(key: "price", label: gross ? "Einzel brutto" : "Einzelpreis"), .init(key: "tax", label: "USt"),
                             .init(key: "total", label: gross ? "Gesamt brutto" : "Gesamt")]
        }
        var position = 0, sum = Decimal(0)
        for line in doc.lines {
            if line.kind != "item" { data.rows.append(.init(kind: "text", cells: [], text: line.description)); continue }
            position += 1
            guard let quantity = line.quantity, let price = line.unit_price, let rate = line.tax_rate else { throw InvoiceRenderError.invalidDocument("line") }
            var amountText = InvoiceRenderFormat.number(try validated(quantity))
            if let second = line.second_quantity { amountText += " × " + InvoiceRenderFormat.number(try validated(second)) }
            if let unit = line.unit, !unit.isEmpty { amountText += " " + unit }
            var cells = [String(position), line.description, amountText]
            var detail: String?
            if priced {
                var discount: InvoiceCalculator.Discount?
                if let kind = line.discount_kind, let value = line.discount_value {
                    discount = kind == "percent" ? .percent(try decimal(value)) : .amount(try decimal(value))
                    detail = "Rabatt " + (kind == "percent" ? InvoiceRenderFormat.number(value) + " %" : money(value))
                }
                let value = rounding.apply(InvoiceCalculator.Line(taxRate: try decimal(rate), unitPrice: try decimal(price), quantity: try decimal(quantity),
                                                                  secondQuantity: try line.second_quantity.map(decimal), discount: discount).value)
                sum += value
                cells += [money(try validated(price)), InvoiceRenderFormat.number(try validated(rate)) + " %", amount(value)]
            }
            data.rows.append(.init(kind: "item", cells: cells, detail: detail))
        }

        if let params = layout?.params {
            let values = ["number": number, "issue_date": InvoiceRenderFormat.date(doc.issue_date), "due_date": doc.due_date.map(InvoiceRenderFormat.date) ?? "",
                          "sender": data.senderName, "recipient": data.recipientLines.first ?? ""]
            var l = Layout(font: params.font, accent: params.accent, text: params.text)
            if let logo = params.logo, let file = layout?.logoFileName { l.logo = .init(file: file, width: logo.widthMM, align: logo.align) }
            l.headerText = params.headerText.map { InvoiceLayoutParams.fill($0, values) }
            l.footerText = params.footerText.map { InvoiceLayoutParams.fill($0, values) }
            data.layout = l
        }

        guard priced else { return Prepared(data: data, createdAt: createdAt) }

        // Summenblock
        let discountTotal = try decimal(doc.discount_total)
        // Gerundet wird je Steuersatz (`InvoiceCalculator`), gedruckt werden gerundete Positionswerte: damit die Spalte aufgeht, steht eine Abweichung da.
        let difference = try decimal(gross ? doc.gross_total : doc.net_total) - (sum - discountTotal + doc.charges.reduce(Decimal(0)) { try $0 + decimal($1.amount) })
        if discountTotal != 0 || !doc.charges.isEmpty || difference != 0 {
            data.totals.append(.init(label: "Zwischensumme", value: amount(sum)))
            if discountTotal != 0 {
                let percent = doc.discount_amount == nil ? doc.discount_percent.map { " " + InvoiceRenderFormat.number($0) + " %" } : nil
                data.totals.append(.init(label: "Rabatt" + (percent ?? ""), value: amount(-discountTotal)))
            }
            for charge in doc.charges {
                data.totals.append(.init(label: "\(charge.description) (USt \(InvoiceRenderFormat.number(try validated(charge.tax_rate))) %)", value: money(try validated(charge.amount))))
            }
            if difference != 0 { data.totals.append(.init(label: "Rundungsdifferenz", value: money(InvoiceDecimal.string(difference, scale: 4)))) }
        }
        let hasTax = try doc.tax_totals.contains { try decimal($0.tax) != 0 }
        // Kleinunternehmer ohne Steuer: nur der Gesamtbetrag und der Hinweis. Steht gespeicherte Steuer da, wird sie gezeigt und der Hinweis
        // entfällt (das PDF widerspricht sich nie selbst; ob so etwas finalisiert werden darf, ist F-38).
        let smallBusiness = doc.tax_regime == "small_business" && !hasTax
        let total = Total(label: "Gesamtbetrag", value: money(try validated(doc.gross_total)), strong: true)
        let taxes = try smallBusiness ? [] : doc.tax_totals.map { t in
            Total(label: "\(gross ? "enthaltene " : "")USt \(InvoiceRenderFormat.number(try validated(t.rate))) % auf \(money(try validated(t.net)))", value: money(try validated(t.tax)))
        }
        let net = smallBusiness ? [] : [Total(label: "Nettobetrag", value: money(try validated(doc.net_total)))]
        data.totals += gross ? [total] + net + taxes : net + taxes + [total]

        if smallBusiness { data.notes.append(smallBusinessNote) }
        if doc.kind == "invoice", let percent = doc.skonto_percent, let days = doc.skonto_days {
            let when = days == 0 ? "am Rechnungsdatum" : "innerhalb von \(days) \(days == 1 ? "Tag" : "Tagen") ab Rechnungsdatum"
            data.notes.append("Bei Zahlung \(when) gewähren wir \(InvoiceRenderFormat.number(try validated(percent))) % Skonto.")
        }
        return Prepared(data: data, createdAt: createdAt)
    }

    /// Nur geprüfte Dezimal-Strings werden formatiert.
    private static func validated(_ s: String) throws -> String { _ = try decimal(s); return s }
}
