import Foundation
@testable import HubKit

// WP-D8: synthetischer Entwicklungskorpus für Vertrag, Versicherung, Behörde/Steuer, Kontoauszug und Kassenbon. Alles erfunden (Firmen, Personen, Nummern,
// IBANs und Steuer-IDs aus dem Testbereich mit gültiger Prüfsumme, example.org). ENTWICKLUNGSKORPUS: die Regeln wurden an diesen Fällen geschärft, die Zahlen sind
// daher optimistisch. Den unabhängigen Holdout-Korpus (`ExtractionCorpusHoldout.swift`) schrieb der Autor erst nach dem Einfrieren der Regeln (Commit im Handoff).
// Soll-Fakten: `facts[Typ] = Wert` (bester Fakt des Typs: höchste Konfidenz, dann frühester Fundort), `absent` = Typen, die NICHT vorkommen dürfen.

struct KindCase {
    var name: String
    /// Zielgruppe der Messung (Behörde und Steuer bilden eine Gruppe).
    var group: DocumentKind
    var text: String
    var subject: String? = nil
    var sender: String? = nil
    var kind: DocumentKind
    var certain = true
    var facts: [String: String] = [:]
    var currency: String? = nil
    var absent: [String] = []
    /// Soll-Übersicht (Spalten Betrag/Fälligkeit/Referenz), nur gesetzte Werte werden geprüft.
    var summary: (amount: String?, due: String?, reference: String?) = (nil, nil, nil)
}

enum ExtractionKindCorpus {
    static let taxIDValid = "94580730215"
    static let taxIDInvalid = "94580730216"
    static let ibanDE = "DE89370400440532013000"
    static let ibanDE2 = "DE91100000000123456789"
    static let ibanDE3 = "DE62370400440532013001"

    static func group(_ k: DocumentKind) -> DocumentKind { k == .letter ? .taxNotice : k }

    static let all: [KindCase] = contracts + insurances + authorities + statements + receipts + conflicts

    // MARK: Vertrag

    static let contracts: [KindCase] = [
        KindCase(name: "contract-wartung-de", group: .contract, text: """
            Wartungsvertrag
            zwischen der Muster Technik GmbH (Auftragnehmer) und der Beispiel Handel GmbH (Auftraggeber)
            Vertragsnummer: WV-2026-017
            § 1 Vertragsgegenstand
            § 2 Laufzeit
            Vertragsbeginn: 01.01.2027
            Die Mindestlaufzeit beträgt 24 Monate. Der Vertrag verlängert sich jeweils um 12 Monate, wenn er nicht gekündigt wird.
            Kündigungsfrist: 3 Monate zum Laufzeitende.
            § 3 Vergütung
            Die monatliche Vergütung beträgt 450,00 EUR netto.
            Unterschrift Auftraggeber / Unterschrift Auftragnehmer
            """, kind: .contract,
                 facts: ["contract_number": "WV-2026-017", "period_start": "2027-01-01", "term": "P24M", "notice_period": "P3M", "auto_renewal": "true",
                         "recurring_amount": "450.00", "payment_interval": "monthly", "counterparty": "Muster Technik GmbH"], currency: "EUR",
                 summary: ("450.00", nil, "WV-2026-017")),
        KindCase(name: "contract-license-en", group: .contract, text: """
            Software License Agreement
            Agreement No. SLA-8841
            between Example Cloud Ltd. ("Licensor") and Sample Retail Inc. ("Licensee")
            1. Term
            The initial term is 12 months, starting on January 1, 2027. This agreement renews automatically for successive 12 month terms unless either party gives 60 days' written notice.
            2. Fees
            The license fee is EUR 1,200.00 per year.
            Signature: ______
            """, kind: .contract,
                 facts: ["contract_number": "SLA-8841", "term": "P12M", "period_start": "2027-01-01", "notice_period": "P60D", "auto_renewal": "true",
                         "recurring_amount": "1200.00", "payment_interval": "yearly", "counterparty": "Example Cloud Ltd."], currency: "EUR"),
        KindCase(name: "contract-miete-unbefristet", group: .contract, text: """
            Mietvertrag Nr. M-4412
            Vermieter: Beispiel Immobilien GmbH
            Mieter: Erika Muster
            Mietbeginn: 01.03.2027
            Das Mietverhältnis läuft auf unbestimmte Zeit.
            Kündigungsfrist für den Mieter: drei Monate.
            Kaltmiete monatlich 780,00 €, Nebenkostenvorauszahlung 160,00 € monatlich.
            Unterschrift Vermieter   Unterschrift Mieter
            """, kind: .contract,
                 facts: ["contract_number": "M-4412", "counterparty": "Beispiel Immobilien GmbH", "period_start": "2027-03-01", "term": "indefinite", "notice_period": "P3M",
                         "recurring_amount": "780.00", "payment_interval": "monthly"], currency: "EUR"),
        KindCase(name: "contract-internet-de", group: .contract, text: """
            Beispiel Telekom GmbH
            Vertrag über Internet-Zugang
            Vertragsnummer 55-102-9981
            Vertragspartner: Muster Handels GmbH
            Vertragsbeginn: 15.12.2026
            Mindestvertragslaufzeit: 24 Monate
            Die Kündigung ist mit einer Frist von 1 Monat zum Ende der Laufzeit möglich. Ohne Kündigung verlängert sich der Vertrag automatisch um jeweils 12 Monate.
            Monatliches Entgelt: 39,90 €
            """, kind: .contract,
                 facts: ["contract_number": "55-102-9981", "counterparty": "Muster Handels GmbH", "period_start": "2026-12-15", "term": "P24M", "notice_period": "P1M",
                         "auto_renewal": "true", "recurring_amount": "39.90", "payment_interval": "monthly"], currency: "EUR"),
        KindCase(name: "contract-beratung-befristet", group: .contract, text: """
            Beratungsvertrag
            Vertragsnummer: BV-2027-3
            zwischen Lena Beispiel Beratung e.K. und der Muster Verlag GmbH
            Vertragslaufzeit: 01.02.2027 bis 31.07.2027
            § 1 Leistungen
            § 2 Honorar: 95,00 EUR pro Stunde
            Das Vertragsverhältnis endet automatisch mit Ablauf der Laufzeit, ohne dass es einer Kündigung bedarf.
            Ort, Datum / Unterschrift
            """, kind: .contract,
                 facts: ["contract_number": "BV-2027-3", "period_start": "2027-02-01", "period_end": "2027-07-31", "auto_renewal": "false", "counterparty": "Lena Beispiel Beratung e.K."],
                 absent: ["recurring_amount"], summary: (nil, "2027-07-31", "BV-2027-3")),
        KindCase(name: "contract-msa-en", group: .contract, text: """
            MASTER SERVICES AGREEMENT
            Contract No. MSA-2026-09
            This Agreement is made between Sample Logistics GmbH and Example Parts Ltd.
            Term: This agreement starts on 1 March 2027 and ends on 28 February 2029. It does not automatically renew.
            Either party may terminate with 90 days notice.
            Fees: USD 2,000.00 per month.
            Signed by: ____
            """, kind: .contract,
                 facts: ["contract_number": "MSA-2026-09", "period_start": "2027-03-01", "period_end": "2029-02-28", "auto_renewal": "false", "notice_period": "P90D",
                         "recurring_amount": "2000.00", "payment_interval": "monthly", "counterparty": "Sample Logistics GmbH"], currency: "USD"),

        // Negativ- und Grenzfälle
        KindCase(name: "contract-neg-angebots-newsletter", group: .contract, text: """
            Betreff: Ihr Vertragsangebot: Jetzt Stromvertrag wechseln und 100 € sparen
            Laufzeit 12 Monate, Kündigungsfrist 1 Monat, Preisgarantie bis 31.12.2027.
            Jetzt abschließen und Bonus sichern! Dies ist ein unverbindliches Angebot.
            Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Ihr Vertragsangebot: Jetzt Stromvertrag wechseln und 100 € sparen", kind: .other),
        KindCase(name: "contract-neg-kuendigungsbestaetigung", group: .contract, text: """
            Kündigungsbestätigung
            Hiermit bestätigen wir die Kündigung Ihres Vertrags Nr. 4455-77 zum 31.12.2026.
            Kündigungsfrist wurde eingehalten.
            Vertragsende: 31.12.2026
            """, kind: .other),
        KindCase(name: "contract-neg-angebot", group: .contract, text: """
            Beispiel Gebäudeservice GmbH
            Angebot Wartungsvertrag
            Angebotsdatum: 03.11.2026
            Laufzeit 24 Monate, Kündigungsfrist 3 Monate.
            Monatliche Vergütung 380,00 € zzgl. MwSt.
            Dieses Angebot ist unverbindlich und gilt 30 Tage.
            """, kind: .other),
        KindCase(name: "contract-neg-mahnung-mit-vertragsnummer", group: .contract, text: """
            Muster Energie GmbH
            Mahnung
            Zu Ihrer Vertragsnummer 7788-11 ist die Zahlung vom 01.10.2026 über 84,00 € noch offen.
            Mahngebühr 5,00 €
            Gesamtbetrag 89,00 €
            Bitte zahlen Sie bis 20.11.2026. Die Mindestlaufzeit Ihres Vertrags bleibt unberührt.
            """, kind: .reminder),
        KindCase(name: "contract-neg-phishing", group: .contract, text: """
            Betreff: Ihr Vertrag wurde gekündigt
            Ihr Vertrag wurde gekündigt. Klicken Sie hier und bestätigen Sie Ihre Zugangsdaten und Ihr Passwort, um die Kündigung zu stoppen.
            Kündigungsfrist: 24 Stunden.
            """, subject: "Ihr Vertrag wurde gekündigt", kind: .other),
    ]

    // MARK: Versicherung

    static let insurances: [KindCase] = [
        KindCase(name: "insurance-hausrat-de", group: .insurance, text: """
            Beispiel Versicherung AG
            Versicherungsschein Hausratversicherung
            Versicherungsschein-Nr.: HR-2026-554433
            Versicherungsnehmer: Erika Muster
            Versicherungsbeginn: 01.01.2027
            Versicherungsablauf: 01.01.2028
            Zahlweise: halbjährlich
            Beitrag: 62,40 € je Zahlung
            Fälligkeit: 01.01.2027
            Versicherungssumme 45.000,00 €
            Selbstbeteiligung 150,00 €
            """, kind: .insurance,
                 facts: ["insurer": "Beispiel Versicherung AG", "policy_number": "HR-2026-554433", "premium": "62.40", "payment_interval": "semiannual",
                         "period_start": "2027-01-01", "period_end": "2028-01-01", "due_date": "2027-01-01"], currency: "EUR",
                 summary: ("62.40", "2027-01-01", "HR-2026-554433")),
        KindCase(name: "insurance-policy-en", group: .insurance, text: """
            Example Insurance Co.
            Policy Schedule
            Policy No: PS-77881234
            Policyholder: Sample Retail Ltd
            Period of insurance: 1 January 2027 to 31 December 2027
            Annual premium: GBP 480.00
            Next payment due: 1 January 2027
            """, kind: .insurance,
                 facts: ["policy_number": "PS-77881234", "period_start": "2027-01-01", "period_end": "2027-12-31", "premium": "480.00", "payment_interval": "yearly", "due_date": "2027-01-01"],
                 currency: "GBP"),
        KindCase(name: "insurance-kfz-beitragsanpassung", group: .insurance, text: """
            Muster Direkt Versicherung AG
            Beitragsanpassung zum 01.01.2027 – Kfz-Haftpflicht
            Versicherungsnummer: KFZ-9087654
            Ihr neuer Jahresbeitrag beträgt 318,45 €.
            Der Beitrag wird zum 15.01.2027 von Ihrem Konto abgebucht.
            Versicherungsschutz: Haftpflicht, Teilkasko
            """, kind: .insurance,
                 facts: ["insurer": "Muster Direkt Versicherung AG", "policy_number": "KFZ-9087654", "premium": "318.45", "payment_interval": "yearly"], currency: "EUR"),
        KindCase(name: "insurance-leben-monatlich", group: .insurance, text: """
            Muster Leben Lebensversicherung a.G.
            Versicherungsschein zur Lebensversicherung
            Versicherungsscheinnummer: LV-120-334455
            Versicherungsnehmerin: Erika Muster
            Versicherungsbeginn: 01.04.2027
            Ablauf: 01.04.2047
            Monatsbeitrag: 89,00 € (Zahlweise monatlich)
            """, kind: .insurance,
                 facts: ["policy_number": "LV-120-334455", "period_start": "2027-04-01", "period_end": "2047-04-01", "premium": "89.00", "payment_interval": "monthly"], currency: "EUR"),
        KindCase(name: "insurance-haftpflicht-nachtrag", group: .insurance, text: """
            Beispiel Haftpflichtversicherung AG
            Nachtrag zum Versicherungsschein
            Policennummer: HP-33-2210
            Prämie vierteljährlich 28,90 €
            Gültig ab 01.02.2027
            """, kind: .insurance,
                 facts: ["insurer": "Beispiel Haftpflichtversicherung AG", "policy_number": "HP-33-2210", "premium": "28.90", "payment_interval": "quarterly", "period_start": "2027-02-01"], currency: "EUR"),
        KindCase(name: "insurance-rechtsschutz-nachweis", group: .insurance, text: """
            Versicherungsnachweis Rechtsschutz
            Beispiel Rechtsschutz Versicherung SE
            Vers.-Nr.: RS-2027-9911
            Versicherungsnehmer: Muster Handels GmbH
            Versicherungszeitraum: 01.01.2027 - 31.12.2027
            Jahresbeitrag 412,00 EUR, fällig am 10.01.2027
            """, kind: .insurance,
                 facts: ["policy_number": "RS-2027-9911", "period_start": "2027-01-01", "period_end": "2027-12-31", "premium": "412.00", "payment_interval": "yearly", "due_date": "2027-01-10"], currency: "EUR"),

        KindCase(name: "insurance-neg-werbe-newsletter", group: .insurance, text: """
            Betreff: Jetzt Kfz-Versicherung wechseln und bis zu 300 € sparen
            Beitrag berechnen mit unserem Tarifrechner: unverbindliches Angebot in 2 Minuten.
            Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Jetzt Kfz-Versicherung wechseln und bis zu 300 € sparen", kind: .other),
        KindCase(name: "insurance-neg-werbebrief", group: .insurance, text: """
            Beispiel Versicherung AG
            Sichern Sie sich jetzt unsere Sonderaktion für die Hausratversicherung.
            Beitrag ab 9,90 € monatlich, Versicherungsschutz für Ihr Zuhause. Jetzt abschließen!
            """, kind: .other),
        KindCase(name: "insurance-neg-reisebuchung", group: .insurance, text: """
            Buchungsbestätigung
            Ihre Reise nach Musterstadt vom 20.12.2026 bis 27.12.2026. Buchungsnummer: B-5566.
            Optional hinzubuchbar: Reiseversicherung für 29,00 €.
            Gesamtpreis 420,00 €
            """, kind: .other),
        KindCase(name: "insurance-neg-rechnung-makler", group: .insurance, text: """
            Muster Versicherungsmakler GmbH
            Rechnung
            Rechnungsnummer: VM-2026-118
            Rechnungsdatum: 05.11.2026
            Beratung zur Betriebshaftpflicht 150,00 €
            MwSt 19 % 28,50 €
            Gesamtbetrag 178,50 €
            Zahlbar innerhalb von 14 Tagen.
            """, kind: .invoice),
        KindCase(name: "insurance-neg-mahnung-beitrag", group: .insurance, text: """
            Beispiel Versicherung AG
            Mahnung
            Der Beitrag zur Versicherungsnummer VN-4471-02 über 62,40 € ist überfällig.
            Mahngebühr 3,00 €
            Gesamtbetrag 65,40 €
            Bitte zahlen Sie bis 25.11.2026, sonst droht der Verlust des Versicherungsschutzes.
            """, kind: .reminder),
    ]

    // MARK: Behörde und Steuer

    static let authorities: [KindCase] = [
        KindCase(name: "tax-est-erstattung", group: .taxNotice, text: """
            Finanzamt Musterstadt
            Einkommensteuerbescheid 2025
            Bescheid vom 05.11.2026
            Steuernummer: 123/456/78901
            Steuer-ID: \(taxIDValid)
            Festgesetzte Einkommensteuer: 12.480,00 €
            Vorauszahlungen: 13.000,00 €
            Erstattung: 520,00 €
            Der Erstattungsbetrag wird in den nächsten Tagen überwiesen.
            Rechtsbehelfsbelehrung: Gegen diesen Bescheid ist der Einspruch zulässig. Einspruch bis 08.12.2026
            """, kind: .taxNotice,
                 facts: ["authority": "Finanzamt Musterstadt", "date": "2026-11-05", "tax_number": "123/456/78901", "tax_id": taxIDValid, "settlement_amount": "-520.00",
                         "objection_deadline": "2026-12-08", "notice_type": "tax_assessment"], currency: "EUR", summary: ("-520.00", "2026-12-08", nil)),
        KindCase(name: "tax-gewerbesteuer-nachzahlung", group: .taxNotice, text: """
            Stadt Musterstadt – Stadtkasse
            Gewerbesteuerbescheid 2026
            Datum: 03.11.2026
            Kassenzeichen: 2026-GS-00815
            Nachzahlung: 1.140,00 €
            Zahlen Sie den Betrag bitte bis zum 03.12.2026.
            Rechtsbehelfsbelehrung: Gegen diesen Bescheid kann innerhalb eines Monats nach Bekanntgabe Widerspruch erhoben werden.
            """, kind: .taxNotice,
                 facts: ["authority": "Stadt Musterstadt – Stadtkasse", "date": "2026-11-03", "reference": "2026-GS-00815", "settlement_amount": "1140.00", "due_date": "2026-12-03",
                         "notice_type": "tax_assessment"], currency: "EUR", summary: ("1140.00", "2026-12-03", "2026-GS-00815")),
        KindCase(name: "letter-verwarnung", group: .taxNotice, text: """
            Stadt Musterstadt
            Ordnungsamt – Bußgeldstelle
            Verwarnung mit Verwarnungsgeld
            Aktenzeichen: 32-2026-4711
            Datum: 06.11.2026
            Verwarnungsgeld: 55,00 €
            Zahlungsfrist: 20.11.2026
            Rechtsbehelfsbelehrung: Gegen diese Verwarnung können Sie Einspruch einlegen.
            """, kind: .letter,
                 facts: ["authority": "Ordnungsamt – Bußgeldstelle", "reference": "32-2026-4711", "date": "2026-11-06", "settlement_amount": "55.00", "due_date": "2026-11-20", "notice_type": "fine"],
                 currency: "EUR", summary: ("55.00", "2026-11-20", "32-2026-4711")),
        KindCase(name: "letter-anhoerung", group: .taxNotice, text: """
            Landratsamt Musterkreis
            Anhörung gemäß § 28 VwVfG
            Geschäftszeichen: 50.2-1234/2026
            Schreiben vom 04.11.2026
            Wir beabsichtigen, Ihnen die Gaststättenerlaubnis zu entziehen. Sie haben Gelegenheit, sich zu äußern.
            Stellungnahme bis 20.11.2026
            """, kind: .letter,
                 facts: ["authority": "Landratsamt Musterkreis", "reference": "50.2-1234/2026", "date": "2026-11-04", "deadline": "2026-11-20", "notice_type": "hearing"],
                 absent: ["settlement_amount"], summary: (nil, "2026-11-20", "50.2-1234/2026")),
        KindCase(name: "tax-assessment-en", group: .taxNotice, text: """
            Example Tax Office
            Tax Assessment Notice 2025/26
            Date: 5 November 2026
            Tax reference: 123 4567 890
            Balance due: GBP 1,250.00
            Payment due: 31 January 2027
            You can appeal within 30 days of the date of this notice.
            """, kind: .taxNotice,
                 facts: ["authority": "Example Tax Office", "date": "2026-11-05", "tax_number": "1234567890", "settlement_amount": "1250.00", "due_date": "2027-01-31", "notice_type": "tax_assessment"],
                 currency: "GBP"),
        KindCase(name: "tax-mahnung-finanzamt", group: .taxNotice, text: """
            Finanzamt Musterstadt
            Mahnung
            Steuernummer: 123/456/78901
            Für die Umsatzsteuer-Vorauszahlung 09/2026 ist keine Zahlung eingegangen.
            Säumniszuschlag: 24,00 €
            Zu zahlender Betrag: 1.224,00 €
            Zahlen Sie bis spätestens 25.11.2026.
            Andernfalls droht die Vollstreckung.
            """, kind: .taxNotice,
                 facts: ["tax_number": "123/456/78901", "settlement_amount": "1224.00", "due_date": "2026-11-25", "notice_type": "reminder"], currency: "EUR"),

        KindCase(name: "letter-neg-info-muellabfuhr", group: .taxNotice, text: """
            Stadtverwaltung Musterstadt
            Information zur neuen Müllabfuhr ab Januar
            Bitte beachten Sie die geänderten Abholtage in Ihrem Stadtteil.
            Weitere Hinweise finden Sie auf der Internetseite der Stadt.
            """, kind: .other, absent: ["deadline", "due_date", "objection_deadline"]),
        KindCase(name: "tax-neg-steuerberater", group: .taxNotice, text: """
            Muster Steuerberatung GmbH
            Ihre Einkommensteuererklärung 2025
            Wir haben Ihre Unterlagen erhalten. Steuernummer: 123/456/78901.
            Bitte senden Sie uns die fehlenden Belege bis zum 15.12.2026.
            """, kind: .other),
        KindCase(name: "tax-neg-phishing", group: .taxNotice, text: """
            Betreff: Finanzamt: Ihre Steuererstattung wartet
            Klicken Sie hier und bestätigen Sie Ihre Zugangsdaten, damit wir Ihre Erstattung auszahlen können.
            """, subject: "Finanzamt: Ihre Steuererstattung wartet", kind: .other),
        KindCase(name: "tax-neg-rechnung-mit-finanzamt-fusszeile", group: .taxNotice, text: """
            Muster Werkstatt GmbH
            Rechnung
            Rechnungsnummer: RE-2026-0077
            Rechnungsdatum: 08.11.2026
            Nettobetrag 200,00 €
            MwSt 19 % 38,00 €
            Gesamtbetrag 238,00 €
            Zahlbar bis 22.11.2026
            Steuernummer: 123/456/78901, zuständiges Finanzamt Musterstadt
            """, kind: .invoice),
        KindCase(name: "tax-neg-newsletter-bundesamt", group: .taxNotice, text: """
            Betreff: Newsletter des Bundesamts für Beispielforschung
            Aktuelle Meldungen aus dem Bundesamt. Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Newsletter des Bundesamts für Beispielforschung", kind: .other),
    ]

    // MARK: Kontoauszug

    static let statements: [KindCase] = [
        KindCase(name: "statement-standard-de", group: .bankStatement, text: """
            Beispiel Bank AG
            Kontoauszug Nr. 11/2026
            IBAN DE89 3704 0044 0532 0130 00
            Zeitraum: 01.11.2026 bis 30.11.2026
            Buchungstag Valuta Buchungstext Umsatz
            03.11.2026 03.11.2026 Miete November -780,00
            10.11.2026 10.11.2026 Gehalt Muster GmbH 2.500,00
            15.11.2026 15.11.2026 Strom Stadtwerke -99,50
            Alter Kontostand 1.200,50 €
            Neuer Kontostand 2.821,00 €
            """, kind: .bankStatement,
                 facts: ["iban": ibanDE, "period_start": "2026-11-01", "period_end": "2026-11-30", "balance_opening": "1200.50", "balance_closing": "2821.00", "date": "2026-11-30"], currency: "EUR",
                 absent: ["amount"], summary: ("2821.00", nil, ibanDE)),
        KindCase(name: "statement-soll-saldo", group: .bankStatement, text: """
            Muster Sparkasse
            Kontoauszug
            Auszugsdatum: 30.11.2026
            IBAN: DE91 1000 0000 0123 4567 89
            Anfangssaldo: 350,00 EUR H
            03.11.2026 Lastschrift Telefon 45,00 S
            12.11.2026 Kartenzahlung Tankstelle 425,00 S
            Endsaldo 120,00 EUR S
            """, kind: .bankStatement,
                 facts: ["iban": ibanDE2, "date": "2026-11-30", "balance_opening": "350.00", "balance_closing": "-120.00"], currency: "EUR"),
        KindCase(name: "statement-account-en", group: .bankStatement, text: """
            Example Bank plc
            Account Statement
            IBAN: DE62 3704 0044 0532 0130 01
            Statement period: 2026-10-01 to 2026-10-31
            Opening balance: EUR 1,000.00
            2026-10-03 Coffee Shop -4.80
            2026-10-09 Salary Sample Ltd 1,550.00
            2026-10-20 Rent October -1,000.00
            Closing balance: EUR 1,545.20
            """, kind: .bankStatement,
                 facts: ["iban": ibanDE3, "period_start": "2026-10-01", "period_end": "2026-10-31", "balance_opening": "1000.00", "balance_closing": "1545.20"], currency: "EUR"),
        KindCase(name: "statement-kreditkarte", group: .bankStatement, text: """
            Beispiel Kreditkarten AG
            Kreditkartenabrechnung 10/2026
            Abrechnungszeitraum: 01.10.2026 - 31.10.2026
            Saldovortrag 120,00 €
            04.10.2026 Online-Shop Beispiel 59,90
            17.10.2026 Tankstelle 48,00
            Neuer Saldo 227,90 €
            """, kind: .bankStatement,
                 facts: ["period_start": "2026-10-01", "period_end": "2026-10-31", "balance_opening": "120.00", "balance_closing": "227.90"], currency: "EUR"),
        KindCase(name: "statement-tagesauszug", group: .bankStatement, text: """
            Tagesauszug 05.11.2026
            IBAN \(ibanDE)
            Kontostand am 05.11.2026: 845,20 €
            05.11.2026 Lastschrift Stadtwerke Beispiel -62,00
            05.11.2026 Gutschrift Kunde A 150,00
            """, kind: .bankStatement, facts: ["iban": ibanDE, "balance_closing": "845.20"], currency: "EUR"),
        KindCase(name: "statement-anfangsbestand", group: .bankStatement, text: """
            Muster Volksbank eG
            Kontoauszug Dezember
            Konto: \(ibanDE2)
            Anfangsbestand 80,00 EUR
            02.12.2026 Überweisung Beispiel Handel GmbH 400,00
            19.12.2026 Dauerauftrag Miete -300,00
            Endbestand 180,00 EUR
            """, kind: .bankStatement, facts: ["iban": ibanDE2, "balance_opening": "80.00", "balance_closing": "180.00"], currency: "EUR"),

        KindCase(name: "statement-neg-benachrichtigung", group: .bankStatement, text: """
            Betreff: Ihr Kontoauszug liegt bereit
            Ihr neuer Kontoauszug steht im Online-Banking zum Abruf bereit. Jetzt einsehen.
            """, subject: "Ihr Kontoauszug liegt bereit", kind: .other),
        KindCase(name: "statement-neg-phishing", group: .bankStatement, text: """
            Kontoauszug gesperrt
            Klicken Sie hier und geben Sie Ihr Passwort ein, um Ihren Kontoauszug zu entsperren.
            """, kind: .other),
        KindCase(name: "statement-neg-rechnung-mit-iban", group: .bankStatement, text: """
            Muster Werkstatt GmbH
            Rechnung
            Rechnungsnummer: RE-2026-0042
            Rechnungsdatum: 08.11.2026
            Gesamtbetrag 178,50 €
            Bitte überweisen Sie an IBAN \(ibanDE)
            """, kind: .invoice),
        KindCase(name: "statement-neg-newsletter", group: .bankStatement, text: """
            Betreff: Newsletter: So lesen Sie Ihren Kontoauszug richtig
            Tipps rund um Kontoauszug und Saldo. Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Newsletter: So lesen Sie Ihren Kontoauszug richtig", kind: .other),
        KindCase(name: "statement-neg-ueberweisungsbeleg", group: .bankStatement, text: """
            Überweisungsbestätigung
            Empfänger-IBAN: \(ibanDE)
            Betrag: 120,00 €
            Verwendungszweck: Rechnung 4711
            Ausgeführt am 05.11.2026
            """, kind: .other),
    ]

    // MARK: Kassenbon

    static let receipts: [KindCase] = [
        KindCase(name: "receipt-markt-bar", group: .receipt, text: """
            Beispiel Markt GmbH
            Musterstraße 1, 12345 Musterstadt
            Kassenbon
            08.11.2026 14:32 Kasse 3
            Brot 3,20 B
            Milch 1,10 B
            Shampoo 2,49 A
            Summe EUR 6,79
            Bar 10,00
            Rückgeld 3,21
            MwSt 7 % 0,28
            MwSt 19 % 0,40
            """, kind: .receipt,
                 facts: ["seller": "Beispiel Markt GmbH", "date": "2026-11-08", "amount": "6.79", "amount_tax_7": "0.28", "amount_tax_19": "0.40", "payment_method": "cash"], currency: "EUR",
                 summary: ("6.79", nil, nil)),
        KindCase(name: "receipt-tankstelle-girocard", group: .receipt, text: """
            Muster Tankstelle
            Kassenbon
            Datum: 07.11.2026 Uhrzeit 08:15
            Super E10   48,00 EUR
            Gesamtbetrag 48,00 EUR
            MwSt 19 %: 7,66 EUR
            Zahlart: girocard
            """, kind: .receipt, facts: ["date": "2026-11-07", "amount": "48.00", "amount_tax_19": "7.66", "payment_method": "debit_card"], currency: "EUR"),
        KindCase(name: "receipt-cafe-quittung", group: .receipt, text: """
            Café Beispiel
            Quittung Nr. 4471
            Datum 06.11.2026
            2x Cappuccino 7,80
            1x Kuchen 4,20
            Summe 12,00 EUR
            Davon MwSt 7 %: 0,79 EUR
            Bezahlt mit Visa
            """, kind: .receipt, facts: ["date": "2026-11-06", "amount": "12.00", "amount_tax_7": "0.79", "payment_method": "credit_card"], currency: "EUR"),
        KindCase(name: "receipt-store-en", group: .receipt, text: """
            Example Store Ltd
            Receipt No. 000884
            Date: 2026-11-05 17:20
            Notebook  2.50
            Pen  1.20
            Total  EUR 3.70
            VAT 19%  0.59
            Paid by card (contactless)
            Thank you for shopping
            """, kind: .receipt, facts: ["seller": "Example Store Ltd", "date": "2026-11-05", "amount": "3.70", "amount_tax_19": "0.59", "payment_method": "card"], currency: "EUR"),
        KindCase(name: "receipt-supermarkt-zwei-saetze", group: .receipt, text: """
            Muster Supermarkt
            Kassenbeleg
            Bon-Nr. 5532
            03.11.2026 10:05
            Apfelsaft 1,99 B
            Wasser 0,79 B
            Batterien 4,99 A
            ZU ZAHLEN 7,77 EUR
            Gegeben bar 10,00
            Rückgeld 2,23
            A 19,00% 0,80   B 7,00% 0,18
            """, kind: .receipt, facts: ["date": "2026-11-03", "amount": "7.77", "amount_tax_19": "0.80", "amount_tax_7": "0.18", "payment_method": "cash"], currency: "EUR"),
        KindCase(name: "receipt-apotheke-kundenbeleg", group: .receipt, text: """
            Beispiel Apotheke
            Kundenbeleg
            06.11.2026
            Hustensaft 8,95
            Summe EUR 8,95
            Kartenzahlung girocard
            MwSt 19 % 1,43
            """, kind: .receipt, facts: ["date": "2026-11-06", "amount": "8.95", "amount_tax_19": "1.43", "payment_method": "debit_card"], currency: "EUR"),

        KindCase(name: "receipt-neg-kleinbetragsrechnung", group: .receipt, text: """
            Beispiel Markt GmbH
            Rechnung
            Rechnungsnummer: KB-2026-881
            Rechnungsdatum: 08.11.2026
            Schreibwaren 11,90
            Nettobetrag 10,00 €
            MwSt 19 % 1,90 €
            Gesamtbetrag 11,90 €
            Zahlbar innerhalb von 14 Tagen.
            """, kind: .invoice),
        KindCase(name: "receipt-neg-bestellbestaetigung", group: .receipt, text: """
            Beispiel Shop GmbH
            Bestellbestätigung
            Bestellnummer: 4711-9
            Summe: 59,90 €
            Enthaltene MwSt 19 %: 9,56 €
            Zahlart: PayPal
            Lieferung in 3 bis 5 Tagen.
            """, kind: .other),
        KindCase(name: "receipt-neg-gewinnspiel", group: .receipt, text: """
            Betreff: Kassenbon hochladen und gewinnen
            Laden Sie Ihren Kassenbon hoch und gewinnen Sie einen Einkaufsgutschein.
            Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Kassenbon hochladen und gewinnen", kind: .other),
        KindCase(name: "receipt-neg-lieferschein", group: .receipt, text: """
            Beispiel Großhandel GmbH
            Lieferschein 2026-33
            Lieferdatum: 04.11.2026
            10 Stück Artikel A
            Bitte bewahren Sie die Quittung gut auf. Bar bezahlt wurde nicht.
            """, kind: .other),
        KindCase(name: "receipt-neg-spesenliste", group: .receipt, text: """
            Reisekosten November
            Taxi 18,50
            Mittagessen 12,40
            Parkgebühr 6,00
            Summe 36,90
            """, kind: .other),
    ]

    // MARK: Konflikte zwischen Rechnung, Mahnung und Vertrag

    static let conflicts: [KindCase] = [
        KindCase(name: "conflict-rechnung-mit-vertragsdaten", group: .contract, text: """
            Beispiel Telekom GmbH
            Rechnung
            Rechnungsnummer: 2026-11-0099
            Rechnungsdatum: 02.11.2026
            Vertragsnummer: 55-102-9981
            Vertragspartner: Muster Handels GmbH
            Laufzeit 24 Monate, Kündigungsfrist 1 Monat
            Internet-Zugang November 33,53 €
            MwSt 19 % 6,37 €
            Gesamtbetrag 39,90 €
            Zahlbar bis 16.11.2026
            """, kind: .invoice),
        KindCase(name: "conflict-vertrag-mit-rechnungsklausel", group: .contract, text: """
            Dienstleistungsvertrag
            zwischen der Beispiel Software GmbH und der Muster Handel GmbH
            § 1 Vertragsgegenstand
            § 2 Vergütung: Die Rechnung wird monatlich gestellt. Rechnungsnummer und Rechnungsdatum werden jeweils mitgeteilt.
            Zahlungsziel 14 Tage. Vertragsnummer: DV-2026-5
            Unterschrift
            """, kind: .contract, facts: ["contract_number": "DV-2026-5"]),
        KindCase(name: "conflict-mahnung-zu-vertrag", group: .contract, text: """
            Mahnung
            Zum Vertrag Nr. 8812-4 (Laufzeit bis 31.12.2027) ist die Rechnung RE-2026-0301 vom 01.10.2026 über 120,00 € unbezahlt.
            Mahngebühr 5,00 €
            Gesamtbetrag 125,00 €
            Zahlen Sie bis 30.11.2026.
            """, kind: .reminder),
    ]
}
