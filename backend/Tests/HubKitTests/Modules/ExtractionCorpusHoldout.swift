import Foundation
@testable import HubKit

// WP-D8 HOLDOUT-KORPUS: nach dem Einfrieren der Regeln (Commit fdf60e6) geschrieben und nur zur Messung benutzt; Regeln wurden daran NICHT geschärft.
// Alles erfunden (Firmen, Personen, Nummern, Test-IBANs). Gemessen wird gemeinsam mit dem Entwicklungskorpus in `ExtractionKindsTests`, aber getrennt ausgewiesen.

extension ExtractionKindCorpus {
    static let holdout: [KindCase] = holdoutContracts + holdoutInsurances + holdoutAuthorities + holdoutStatements + holdoutReceipts

    static let holdoutContracts: [KindCase] = [
        KindCase(name: "h-contract-fitness", group: .contract, text: """
            Mitgliedsvertrag Fitnessstudio
            Vertragsnummer: FS-20261108-5
            Vertragspartner: Max Beispiel
            Vertragsbeginn: 01.12.2026
            Die Erstlaufzeit beträgt 12 Monate. Danach verlängert sich der Vertrag automatisch um weitere 6 Monate, sofern nicht mit einer Frist von 4 Wochen gekündigt wird.
            Monatsbeitrag: 29,90 €
            Unterschrift Mitglied
            """, kind: .contract,
                 facts: ["contract_number": "FS-20261108-5", "period_start": "2026-12-01", "term": "P12M", "notice_period": "P4W", "auto_renewal": "true", "recurring_amount": "29.90", "payment_interval": "monthly"],
                 currency: "EUR"),
        KindCase(name: "h-contract-hosting-en", group: .contract, text: """
            Hosting Agreement
            Contract number: HA-5521-7
            between Sample Hosting Ltd. and Muster Webdesign GmbH
            This agreement starts on 1 January 2027 and runs for 24 months. It renews automatically for 12 months unless terminated with 30 days notice.
            Fees: EUR 49.00 per month.
            Signature
            """, kind: .contract,
                 facts: ["contract_number": "HA-5521-7", "period_start": "2027-01-01", "term": "P24M", "auto_renewal": "true", "notice_period": "P30D", "recurring_amount": "49.00", "payment_interval": "monthly"], currency: "EUR"),
        KindCase(name: "h-contract-arbeitsvertrag", group: .contract, text: """
            Arbeitsvertrag
            zwischen der Beispiel Maschinenbau GmbH (Arbeitgeber) und Herrn Paul Muster (Arbeitnehmer)
            § 1 Beginn des Arbeitsverhältnisses: 01.02.2027
            § 2 Das Arbeitsverhältnis ist unbefristet. Die Kündigungsfrist beträgt 3 Monate zum Monatsende.
            § 3 Vergütung: 3.800,00 € monatlich
            Ort, Datum / Unterschrift
            """, kind: .contract, facts: ["term": "indefinite", "notice_period": "P3M"]),
        KindCase(name: "h-contract-wartung-jaehrlich", group: .contract, text: """
            Rahmenvertrag Gerätewartung
            Vertragsnummer 2027/WRT/019
            Vertragsbeginn: 01.04.2027
            Vertragsende: 31.03.2028
            Der Vertrag endet ohne Kündigung. Jährliche Pauschale: 1.800,00 EUR
            Auftraggeber: Muster Praxis GbR
            Auftragnehmer: Beispiel Medizintechnik GmbH
            Unterschriften
            """, kind: .contract, facts: ["contract_number": "2027/WRT/019", "period_start": "2027-04-01", "period_end": "2028-03-31", "auto_renewal": "false", "recurring_amount": "1800.00", "payment_interval": "yearly"],
                 currency: "EUR"),
        KindCase(name: "h-contract-neg-stellenanzeige", group: .contract, text: """
            Betreff: Ihr neuer Job: Vertragsbeginn sofort möglich
            Wir bieten einen unbefristeten Vertrag, Kündigungsfrist 4 Wochen. Jetzt bewerben und Willkommensbonus sichern!
            Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Ihr neuer Job: Vertragsbeginn sofort möglich", kind: .other),
        KindCase(name: "h-contract-neg-agb", group: .contract, text: """
            Allgemeine Informationen zu unseren Leistungen
            Unsere Leistungen werden individuell vereinbart. Weitere Details besprechen wir gern persönlich.
            Kontaktieren Sie uns unter kontakt@example.org.
            """, kind: .other),
        KindCase(name: "h-contract-neg-rechnung-abo", group: .contract, text: """
            Beispiel Streaming GmbH
            Rechnung
            Rechnungsnummer: S-2026-77881
            Rechnungsdatum: 01.11.2026
            Abo Premium, Laufzeit monatlich kündbar, Kündigungsfrist 1 Monat
            Nettobetrag 8,40 €
            MwSt 19 % 1,60 €
            Gesamtbetrag 10,00 €
            Abbuchung per Lastschrift, Zahlbar bis 08.11.2026
            """, kind: .invoice),
    ]

    static let holdoutInsurances: [KindCase] = [
        KindCase(name: "h-insurance-rechtsschutz", group: .insurance, text: """
            Beispiel Rechtsschutz AG
            Versicherungsschein
            Vertragsnummer/Versicherungsnummer: RS-33-44556
            Versicherungsnehmer: Paul Muster
            Versicherungsbeginn: 01.01.2027
            Beitrag: 18,50 € monatlich
            """, kind: .insurance, facts: ["policy_number": "RS-33-44556", "premium": "18.50", "payment_interval": "monthly", "period_start": "2027-01-01"], currency: "EUR"),
        KindCase(name: "h-insurance-travel-en", group: .insurance, text: """
            Sample Travel Insurance Ltd
            Certificate of Insurance
            Policy number: TR-2026-0099
            Policyholder: Erika Muster
            Coverage period: 2026-12-20 to 2027-01-03
            Premium: EUR 39.00
            """, kind: .insurance, facts: ["policy_number": "TR-2026-0099", "period_start": "2026-12-20", "period_end": "2027-01-03", "premium": "39.00"], currency: "EUR"),
        KindCase(name: "h-insurance-beitragsrechnung", group: .insurance, text: """
            Muster Gebäudeversicherung AG
            Beitragsrechnung 2027
            Versicherungsnummer: GB-778899-1
            Versicherungsnehmer: Beispiel Immobilien GmbH
            Jahresbeitrag: 612,00 €
            Fällig am 15.01.2027
            Zahlweise: jährlich
            """, kind: .insurance, facts: ["policy_number": "GB-778899-1", "premium": "612.00", "due_date": "2027-01-15", "payment_interval": "yearly"], currency: "EUR"),
        KindCase(name: "h-insurance-police-quartal", group: .insurance, text: """
            Beispiel Unfallversicherung VVaG
            Versicherungspolice
            Policennummer: UV-1020-3040
            Zahlweise: vierteljährlich
            Beitrag: 45,25 € je Zahlung
            Ablauf der Versicherung: 31.12.2031
            """, kind: .insurance, facts: ["policy_number": "UV-1020-3040", "premium": "45.25", "payment_interval": "quarterly", "period_end": "2031-12-31"], currency: "EUR"),
        KindCase(name: "h-insurance-neg-vergleichsportal", group: .insurance, text: """
            Betreff: Ihr Versicherungsvergleich
            Vergleichen Sie jetzt über 200 Tarife und sparen Sie bis zu 40 % beim Beitrag. Kostenloser Vergleich in 3 Minuten!
            Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Ihr Versicherungsvergleich", kind: .other),
        KindCase(name: "h-insurance-neg-schadenfrage", group: .insurance, text: """
            Hallo Erika,
            ich glaube, ich habe meine Versicherung wegen des Wasserschadens noch nicht informiert. Hast du die Nummer vom Makler?
            Danke und viele Grüße
            """, kind: .other),
        KindCase(name: "h-insurance-neg-kontoauszug-versicherungsbeitrag", group: .insurance, text: """
            Beispiel Bank AG
            Kontoauszug 12/2026
            IBAN DE89 3704 0044 0532 0130 00
            Alter Kontostand 500,00 €
            02.12.2026 Beitrag Beispiel Versicherung AG -62,40
            15.12.2026 Gehalt 2.000,00
            Neuer Kontostand 2.437,60 €
            """, kind: .bankStatement),
    ]

    static let holdoutAuthorities: [KindCase] = [
        KindCase(name: "h-tax-umsatzsteuer-bescheid", group: .taxNotice, text: """
            Finanzamt Beispielstadt
            Umsatzsteuerbescheid 2025
            Bescheid vom 09.11.2026
            Steuernummer: 12/345/67890
            Nachzahlung: 2.310,50 €
            Zahlungsfrist: 14.12.2026
            Rechtsbehelfsbelehrung: Gegen diesen Bescheid ist der Einspruch zulässig.
            """, kind: .taxNotice, facts: ["tax_number": "12/345/67890", "date": "2026-11-09", "settlement_amount": "2310.50", "due_date": "2026-12-14", "notice_type": "tax_assessment"], currency: "EUR"),
        KindCase(name: "h-letter-beitragsservice", group: .taxNotice, text: """
            Beitragsservice Beispielland
            Beitragsbescheid
            Beitragsnummer: 123 456 789
            Bescheid vom 03.11.2026
            Zu zahlender Betrag: 55,08 €
            Fällig am 15.12.2026
            Widerspruch ist innerhalb eines Monats nach Bekanntgabe möglich.
            """, kind: .letter, facts: ["date": "2026-11-03", "settlement_amount": "55.08", "due_date": "2026-12-15", "notice_type": "fee_notice"], currency: "EUR"),
        KindCase(name: "h-letter-gericht-ladung", group: .taxNotice, text: """
            Amtsgericht Musterstadt
            Ladung zum Termin
            Aktenzeichen: 12 C 345/26
            Schreiben vom 06.11.2026
            Sie werden zum Termin am 18.01.2027 geladen.
            Rechtsbehelfsbelehrung: Gegen diesen Beschluss ist ... Widerspruch möglich.
            """, kind: .letter, facts: ["reference": "12 C 345/26", "date": "2026-11-06"], absent: ["settlement_amount"]),
        KindCase(name: "h-tax-grundsteuer", group: .taxNotice, text: """
            Stadt Beispielstadt – Stadtkasse
            Grundsteuerbescheid 2027
            Kassenzeichen: GS-2027-00311
            Datum: 07.11.2026
            Zahlbetrag: 312,40 €
            Zahlbar bis 15.02.2027
            """, kind: .taxNotice, facts: ["reference": "GS-2027-00311", "date": "2026-11-07", "settlement_amount": "312.40", "due_date": "2027-02-15"], currency: "EUR"),
        KindCase(name: "h-letter-neg-buergerinfo", group: .taxNotice, text: """
            Gemeindeverwaltung Beispieldorf
            Bürgerinformation zur Straßensperrung
            Die Hauptstraße ist von 10.11.2026 bis 20.11.2026 gesperrt. Bitte nutzen Sie die Umleitung.
            """, kind: .other, absent: ["settlement_amount", "objection_deadline"]),
        KindCase(name: "h-tax-neg-steuerberater-rechnung", group: .taxNotice, text: """
            Beispiel Steuerberatung GmbH
            Rechnung
            Rechnungsnummer: StB-2026-77
            Rechnungsdatum: 08.11.2026
            Erstellung Einkommensteuererklärung 2025
            Nettobetrag 300,00 €
            MwSt 19 % 57,00 €
            Gesamtbetrag 357,00 €
            Zahlbar bis 22.11.2026
            """, kind: .invoice),
        KindCase(name: "h-tax-neg-fake-finanzamt-mail", group: .taxNotice, text: """
            Betreff: Finanzamt – dringende Rückerstattung
            Bitte klicken Sie hier, um Ihre Kreditkarte und Zugangsdaten für die Rückerstattung zu bestätigen.
            """, subject: "Finanzamt – dringende Rückerstattung", kind: .other),
    ]

    static let holdoutStatements: [KindCase] = [
        KindCase(name: "h-statement-giro", group: .bankStatement, text: """
            Muster Sparkasse
            Kontoauszug 09/2026
            IBAN DE62 3704 0044 0532 0130 01
            Alter Kontostand 3.210,00 €
            02.09.2026 Gehalt Beispiel GmbH 2.800,00
            05.09.2026 Miete -1.100,00
            Neuer Kontostand 4.910,00 €
            """, kind: .bankStatement, facts: ["iban": ibanDE3, "balance_opening": "3210.00", "balance_closing": "4910.00"], currency: "EUR"),
        KindCase(name: "h-statement-uebersicht-en", group: .bankStatement, text: """
            Example Bank
            Statement of account
            IBAN: DE91 1000 0000 0123 4567 89
            Period: 2026-09-01 to 2026-09-30
            Opening balance EUR 200.00
            2026-09-05 Supermarket -35.20
            2026-09-12 Refund 20.00
            Closing balance EUR 184.80
            """, kind: .bankStatement, facts: ["iban": ibanDE2, "period_start": "2026-09-01", "period_end": "2026-09-30", "balance_opening": "200.00", "balance_closing": "184.80"], currency: "EUR"),
        KindCase(name: "h-statement-dispo", group: .bankStatement, text: """
            Beispiel Bank AG
            Kontoauszug
            Konto \(ibanDE)
            Anfangssaldo 100,00 EUR H
            04.10.2026 Lastschrift Versicherung 250,00 S
            Endsaldo 150,00 EUR S
            """, kind: .bankStatement, facts: ["iban": ibanDE, "balance_opening": "100.00", "balance_closing": "-150.00"], currency: "EUR"),
        KindCase(name: "h-statement-depot-umsatz", group: .bankStatement, text: """
            Muster Online Bank
            Umsatzübersicht Oktober
            IBAN \(ibanDE2)
            Saldo alt 1.000,00 €
            01.10.2026 Überweisung Beispiel Handel 500,00
            09.10.2026 Kartenzahlung -80,00
            Saldo neu 1.420,00 €
            """, kind: .bankStatement, facts: ["iban": ibanDE2, "balance_opening": "1000.00", "balance_closing": "1420.00"], currency: "EUR"),
        KindCase(name: "h-statement-neg-werbung-girokonto", group: .bankStatement, text: """
            Betreff: Ihr neues Girokonto: Jetzt Konto eröffnen
            Eröffnen Sie jetzt ein kostenloses Girokonto, Saldo egal. Aktion nur heute!
            Newsletter abbestellen unter https://example.org/abmelden
            """, subject: "Ihr neues Girokonto: Jetzt Konto eröffnen", kind: .other),
        KindCase(name: "h-statement-neg-zahlungserinnerung-bank", group: .bankStatement, text: """
            Beispiel Bank AG
            Zahlungserinnerung
            Ihr Konto \(ibanDE) weist einen offenen Betrag von 45,00 € auf. Bitte zahlen Sie bis 20.11.2026.
            Mahngebühr 5,00 €
            Gesamtbetrag 50,00 €
            """, kind: .reminder),
        KindCase(name: "h-statement-neg-online-banking-hinweis", group: .bankStatement, text: """
            Betreff: Neue Nachricht in Ihrem Postfach
            Ihre Bank hat Ihnen ein neues Dokument bereitgestellt. Melden Sie sich im Online-Banking an, um es einzusehen.
            """, subject: "Neue Nachricht in Ihrem Postfach", kind: .other),
    ]

    static let holdoutReceipts: [KindCase] = [
        KindCase(name: "h-receipt-baeckerei", group: .receipt, text: """
            Bäckerei Beispiel
            Kassenzettel
            09.11.2026 07:45
            Brötchen 4x 1,60
            Kaffee 2,20
            Summe 3,80 EUR
            Bar gegeben 5,00
            Rückgeld 1,20
            Enthaltene MwSt 7 %: 0,25
            """, kind: .receipt, facts: ["date": "2026-11-09", "amount": "3.80", "amount_tax_7": "0.25", "payment_method": "cash"], currency: "EUR"),
        KindCase(name: "h-receipt-baumarkt-ec", group: .receipt, text: """
            Beispiel Baumarkt
            Kassenbon
            Bon-Nr. 88112
            05.11.2026 16:10
            Schrauben 4,99 A
            Dübel 3,49 A
            Gesamt EUR 8,48
            EC-Karte
            MwSt 19 % 1,35
            """, kind: .receipt, facts: ["date": "2026-11-05", "amount": "8.48", "amount_tax_19": "1.35", "payment_method": "debit_card"], currency: "EUR"),
        KindCase(name: "h-receipt-restaurant-visa", group: .receipt, text: """
            Restaurant Beispiel
            Quittung
            Datum: 04.11.2026
            2 Hauptgerichte 31,00
            2 Getränke 8,40
            Summe EUR 39,40
            MwSt 19 % 6,29
            Bezahlt mit Mastercard
            """, kind: .receipt, facts: ["date": "2026-11-04", "amount": "39.40", "amount_tax_19": "6.29", "payment_method": "credit_card"], currency: "EUR"),
        KindCase(name: "h-receipt-kiosk-en", group: .receipt, text: """
            Example Kiosk
            Receipt
            Receipt No. 4421
            2026-11-02 12:15
            Magazine 5.50
            Total EUR 5.50
            VAT 7%  0.36
            Cash
            Change 4.50
            """, kind: .receipt, facts: ["date": "2026-11-02", "amount": "5.50", "amount_tax_7": "0.36"], currency: "EUR"),
        KindCase(name: "h-receipt-neg-rechnung-handwerker", group: .receipt, text: """
            Muster Elektrik GmbH
            Rechnung
            Rechnungsnummer: E-2026-4410
            Rechnungsdatum: 03.11.2026
            Material 24,50 €
            Nettobetrag 24,50 €
            MwSt 19 % 4,66 €
            Gesamtbetrag 29,16 €
            Bitte überweisen Sie bis 17.11.2026.
            """, kind: .invoice),
        KindCase(name: "h-receipt-neg-paketbenachrichtigung", group: .receipt, text: """
            Betreff: Ihr Paket ist unterwegs
            Sendungsnummer: 00340434161094099999
            Ihr Paket wurde versendet und kommt am Freitag. Bestellnummer: 7766-2.
            Summe 24,90 €
            """, subject: "Ihr Paket ist unterwegs", kind: .other),
        KindCase(name: "h-receipt-neg-speisekarte", group: .receipt, text: """
            Restaurant Beispiel – Tageskarte
            Suppe 5,50
            Hauptgericht 14,90
            Dessert 6,00
            Alle Preise inkl. MwSt 19 %.
            """, kind: .other),
    ]
}
