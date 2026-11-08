import Foundation
@testable import HubKit

// WP-D7: synthetischer Testkorpus (alles erfunden: Firmen, Personen, Nummern; IBANs aus dem Standard-Testbereich mit gültiger Prüfsumme, example.org).
// Reproduzierbar, weil der Korpus im Code steht (keine Binärdateien); `ExtractionCorpusTests` rendert dieselben Texte zusätzlich als PDF-Textschicht (MailBodyPDF),
// als HTML-Mail (Tabellen) und als „OCR“-Ergebnis der Test-Engine. Soll-Werte stehen je Fall.

struct CorpusCase {
    var name: String
    var text: String
    var subject: String? = nil
    var sender: String? = nil
    var kind: DocumentKind
    var certain = true
    var number: String? = nil
    var gross: String? = nil
    var net: String? = nil
    var tax: String? = nil
    var currency: String? = nil
    var date: String? = nil
    var due: String? = nil
    var iban: String? = nil
    var vat: String? = nil
    var seller: String? = nil
    /// Positiv = „ist Rechnung“ (sicher erkannt) wird erwartet.
    var isInvoice: Bool { kind == .invoice }
}

enum ExtractionCorpus {
    static let ibanDE = "DE89370400440532013000"
    static let ibanAT = "AT611904300234573201"
    static let ibanNL = "NL91ABNA0417164300"
    static let ibanGB = "GB82WEST12345698765432"
    static let ibanFR = "FR1420041010050500013M02606"
    static let ibanCH = "CH9300762011623852957"

    static let all: [CorpusCase] = invoices + others

    static let invoices: [CorpusCase] = [
        CorpusCase(name: "de-klassisch", text: """
            Muster Werkstatt GmbH · Beispielweg 1 · 12345 Musterstadt

            Rechnung
            Rechnungsnummer: RE-2026-0042
            Rechnungsdatum: 08.11.2026
            Fällig am: 22.11.2026

            Pos. 1 Reparatur Gerät 100,00 €
            Pos. 2 Ersatzteile 50,00 €
            Nettobetrag 150,00 €
            MwSt 19 % 28,50 €
            Gesamtbetrag 178,50 €

            Bitte überweisen Sie an IBAN DE89 3704 0044 0532 0130 00
            USt-IdNr.: DE123456789
            """, kind: .invoice, number: "RE-2026-0042", gross: "178.50", net: "150.00", tax: "28.50", currency: "EUR", date: "2026-11-08", due: "2026-11-22", iban: ibanDE, vat: "DE123456789", seller: "Muster Werkstatt GmbH"),
        CorpusCase(name: "en-klassisch", text: """
            Example Tools Ltd.
            Invoice
            Invoice No. INV-20260815
            Invoice date: 2026-11-03
            Due date: 2026-12-03
            Subtotal EUR 1,000.00
            VAT 20% EUR 200.00
            Total EUR 1,200.00
            IBAN: GB82 WEST 1234 5698 7654 32
            VAT ID: GB123456789
            """, kind: .invoice, number: "INV-20260815", gross: "1200.00", net: "1000.00", tax: "200.00", currency: "EUR", date: "2026-11-03", due: "2026-12-03", iban: ibanGB, vat: "GB123456789", seller: "Example Tools Ltd."),
        CorpusCase(name: "de-kurz", text: "Rechnung Nr. 2026-0042 vom 02.11.2026\nGesamtbetrag 119,00 EUR\nZahlbar bis 16.11.2026", kind: .invoice, number: "2026-0042", gross: "119.00", currency: "EUR", date: "2026-11-02", due: "2026-11-16"),
        CorpusCase(name: "en-usd", text: "Beispiel Cloud Inc.\nInvoice #INV-1001\nIssue date: November 8, 2026\nPayment due: December 8, 2026\nAmount due $ 2,500.00\nVAT ID: DE987654321", kind: .invoice, number: "INV-1001", gross: "2500.00", currency: "USD", date: "2026-11-08", due: "2026-12-08", vat: "DE987654321", seller: "Beispiel Cloud Inc."),
        CorpusCase(name: "de-spaltenlayout", text: "Rechnung\nRechnungsnummer\nR-77/2026\nRechnungsdatum\n05.11.2026\nGesamtbetrag\n1.234,56 €", kind: .invoice, number: "R-77/2026", gross: "1234.56", currency: "EUR", date: "2026-11-05"),
        CorpusCase(name: "de-relatives-ziel", text: "Rechnung Nr. 5100\nRechnungsdatum: 01.11.2026\nRechnungsbetrag: 480,00 EUR\nZahlbar innerhalb von 14 Tagen netto.", kind: .invoice, number: "5100", gross: "480.00", currency: "EUR", date: "2026-11-01", due: "2026-11-15"),
        CorpusCase(name: "ch-apostroph", text: "Beispiel Treuhand AG\nRechnung\nRechnungsnr. 2026-A-12\nRechnungsdatum 3. November 2026\nTotal CHF 1'234.50\nIBAN \(ibanCH)", kind: .invoice, number: "2026-A-12", gross: "1234.50", currency: "CHF", date: "2026-11-03", iban: ibanCH, seller: "Beispiel Treuhand AG"),
        CorpusCase(name: "de-ohne-symbol", text: "Rechnung Nr. K-9001\nDatum: 04.11.2026\nGesamtbetrag: 99,90\nUSt-ID: DE111222333", kind: .invoice, number: "K-9001", gross: "99.90", date: "2026-11-04", vat: "DE111222333"),
        CorpusCase(name: "de-shop-html-mail", text: """
            Betreff: Ihre Rechnung Nr. 4711 zur Bestellung
            Vielen Dank für Ihre Bestellung bei Beispiel Shop GmbH.
            Rechnungsnummer | 4711
            Rechnungsdatum | 07.11.2026
            Zwischensumme | 84,03 €
            MwSt 19 % | 15,97 €
            Gesamtsumme | 100,00 €
            Zahlung per Überweisung an \(ibanDE)
            """, subject: "Ihre Rechnung Nr. 4711 zur Bestellung", kind: .invoice, number: "4711", gross: "100.00", net: "84.03", tax: "15.97", currency: "EUR", date: "2026-11-07", iban: ibanDE, seller: "Beispiel Shop GmbH"),
        CorpusCase(name: "en-saas-mail", text: "Subject: Your invoice from ExampleCloud\nExampleCloud Inc.\nInvoice number: EC-2026-11-0007\nInvoice date: 1 November 2026\nTotal due: $49.00\nVAT 0.00 USD", subject: "Your invoice from ExampleCloud", kind: .invoice, number: "EC-2026-11-0007", gross: "49.00", currency: "USD", date: "2026-11-01", seller: "ExampleCloud Inc."),
        CorpusCase(name: "de-abo-brutto-netto", text: "Beispiel Medien GmbH\nRechnung\nRechnungsnummer 20261108-3\nRechnungsdatum 08.11.2026\nNetto 8,40 €\nUSt 19 % 1,60 €\nBrutto 10,00 €\nDie Summe wird per Lastschrift eingezogen.", kind: .invoice, number: "20261108-3", gross: "10.00", net: "8.40", tax: "1.60", currency: "EUR", date: "2026-11-08", seller: "Beispiel Medien GmbH"),
        CorpusCase(name: "de-kleinunternehmer", text: "Rechnung\nRechnungs-Nr.: 2026/15\nRechnungsdatum: 10.10.2026\nGemäß § 19 UStG wird keine Umsatzsteuer berechnet.\nRechnungsbetrag: 450,00 €\nZahlungsziel: 24.10.2026", kind: .invoice, number: "2026/15", gross: "450.00", currency: "EUR", date: "2026-10-10", due: "2026-10-24"),
        CorpusCase(name: "de-mehrere-steuersaetze", text: "Rechnung Nr. M-300\nRechnungsdatum: 12.10.2026\nSumme netto 200,00 €\nUSt 7 % 7,00 €\nUSt 19 % 22,00 €\nGesamtbetrag 229,00 €", kind: .invoice, number: "M-300", gross: "229.00", net: "200.00", currency: "EUR", date: "2026-10-12"),
        CorpusCase(name: "de-monatsname", text: "Rechnung\nRechnungsnummer: 88-2026\nRechnungsdatum: 8. November 2026\nFälligkeitsdatum: 8. Dezember 2026\nGesamtbetrag 59,00 EUR", kind: .invoice, number: "88-2026", gross: "59.00", currency: "EUR", date: "2026-11-08", due: "2026-12-08"),
        CorpusCase(name: "en-uk-datum", text: "Invoice\nInvoice Number: 2026-77\nInvoice date: 8 November 2026\nPayment terms: due on 7 December 2026\nGrand total: EUR 3,200.00", kind: .invoice, number: "2026-77", gross: "3200.00", currency: "EUR", date: "2026-11-08", due: "2026-12-07"),
        CorpusCase(name: "de-ocr-rauschen", text: "Rechnungs-Nr.: R2026/0815\nRechnungsdatum:   09.11.2026\nUSt-IdNr. DE 123 456 789\nGesamtbetrag EUR 2.345,67\nIBAN  AT61 1904 3002 3457 3201", kind: .invoice, number: "R2026/0815", gross: "2345.67", currency: "EUR", date: "2026-11-09", iban: ibanAT, vat: "DE123456789"),
        CorpusCase(name: "de-handwerker", text: "Elektro Beispiel e.K. · Hauptstraße 5 · 12345 Musterstadt\nRechnung\nRechnungsnummer: 2026-0031\nRechnungsdatum: 15.10.2026\nArbeitszeit 3 Std. 195,00 €\nMaterial 40,00 €\nNettobetrag 235,00 €\nMehrwertsteuer 19 % 44,65 €\nRechnungsbetrag 279,65 €\nZahlbar bis 29.10.2026\nIBAN \(ibanNL)", kind: .invoice, number: "2026-0031", gross: "279.65", net: "235.00", tax: "44.65", currency: "EUR", date: "2026-10-15", due: "2026-10-29", iban: ibanNL, seller: "Elektro Beispiel e.K."),
        CorpusCase(name: "de-mailtext-ohne-anhang", text: "Betreff: Rechnung 2026-1108 online verfügbar\nHallo,\nIhre Rechnung Nr. 2026-1108 über 36,90 € vom 08.11.2026 ist fällig am 22.11.2026.\nGesamtbetrag: 36,90 €\nMwSt (19 %): 5,89 €", subject: "Rechnung 2026-1108 online verfügbar", kind: .invoice, number: "2026-1108", gross: "36.90", tax: "5.89", currency: "EUR", date: "2026-11-08", due: "2026-11-22"),
        CorpusCase(name: "en-consulting-us-format", text: "Beispiel Consulting LLC\nTAX INVOICE\nInvoice no: C-2026-19\nDate: 11/20/2026\nTotal amount due: USD 12,000.00\nPlease pay by 12/20/2026", kind: .invoice, number: "C-2026-19", gross: "12000.00", currency: "USD", date: "2026-11-20", due: "2026-12-20", seller: "Beispiel Consulting LLC"),
        CorpusCase(name: "de-tabelle-mit-pipe", text: "Rechnung | 2026-501\nRechnungsnummer | 2026-501\nRechnungsdatum | 06.11.2026\nFällig bis | 20.11.2026\nNetto | 1.000,00 EUR\nUSt 19 % | 190,00 EUR\nGesamtbetrag | 1.190,00 EUR\nUSt-IdNr. | DE135792468", kind: .invoice, number: "2026-501", gross: "1190.00", net: "1000.00", tax: "190.00", currency: "EUR", date: "2026-11-06", due: "2026-11-20", vat: "DE135792468"),
        CorpusCase(name: "fr-rechnung-eur", text: "Beispiel SARL\nInvoice\nInvoice number: FR-2026-0099\nInvoice date: 2026-11-02\nTotal EUR 480.00\nIBAN \(ibanFR)", kind: .invoice, number: "FR-2026-0099", gross: "480.00", currency: "EUR", date: "2026-11-02", iban: ibanFR),
    ]

    static let others: [CorpusCase] = [
        CorpusCase(name: "neg-newsletter-rechnung-im-betreff", text: "Betreff: Ihre Rechnung: 20 % Rabatt auf alles\nNur heute: Gutschein BEISPIEL20 sichern.\nNewsletter im Browser ansehen. Abmelden unter https://example.org/abmelden", subject: "Ihre Rechnung: 20 % Rabatt auf alles", kind: .other),
        CorpusCase(name: "neg-newsletter-en", text: "Subject: Your invoice template pack is here\nGrab 30% off our new invoice templates. View in browser. Unsubscribe here.", subject: "Your invoice template pack is here", kind: .other),
        CorpusCase(name: "neg-versandbestaetigung", text: "Betreff: Versandbestätigung zu Ihrer Bestellung\nIhre Bestellung wurde versendet.\nSendungsnummer: 00340434161094032956\nBestellnummer: 4711-2\nSumme: 59,90 €\nEnthaltene MwSt 19 %: 9,56 €", subject: "Versandbestätigung zu Ihrer Bestellung", kind: .other),
        CorpusCase(name: "neg-bestellbestaetigung", text: "Beispiel Shop GmbH\nBestellbestätigung\nVielen Dank für Ihre Bestellung.\nBestelldatum: 07.11.2026\nGesamtbetrag 59,90 €\nMwSt 19 %: 9,56 €\nLieferung in 3 bis 5 Tagen.", kind: .other),
        CorpusCase(name: "neg-mahnung-de", text: "Beispiel Werkstatt GmbH\nMahnung\nZu unserer Rechnung Nr. RE-2026-0042 vom 08.11.2026 ist keine Zahlung eingegangen.\nMahngebühr 5,00 €\nGesamtbetrag 183,50 €\nBitte zahlen Sie bis 30.11.2026.", subject: "Mahnung zu Rechnung RE-2026-0042", kind: .reminder, number: nil, gross: "183.50", currency: "EUR"),
        CorpusCase(name: "neg-zahlungserinnerung-en", text: "Payment reminder\nInvoice No. 123456 is overdue.\nAmount due: EUR 250.00\nPlease pay immediately to avoid a late fee.", kind: .reminder, gross: "250.00", currency: "EUR"),
        CorpusCase(name: "neg-letzte-mahnung", text: "Betreff: Letzte Mahnung vor Inkasso\nDie Rechnung vom 01.10.2026 über 90,00 € ist überfällig. Letzte Mahnung, danach Übergabe an ein Inkassobüro.", subject: "Letzte Mahnung vor Inkasso", kind: .reminder),
        CorpusCase(name: "neg-spam-zip", text: "Betreff: Rechnung\nSehr geehrte Damen und Herren, öffnen Sie den Anhang Rechnung.zip um die Rechnung zu sehen.", subject: "Rechnung", kind: .other),
        CorpusCase(name: "neg-phishing-en", text: "Subject: Your invoice is ready\nClick here to verify your password and view invoice. Your account has been suspended.", subject: "Your invoice is ready", kind: .other),
        CorpusCase(name: "neg-freund-fragt", text: "Betreff: Rechnung vom Klempner\nHallo, kannst du mir die Rechnung vom Klempner weiterleiten? Danke und bis Samstag!", subject: "Rechnung vom Klempner", kind: .other),
        CorpusCase(name: "neg-angebot", text: "Beispiel Bau GmbH\nAngebot Nr. 2026-12\nAngebotsdatum: 05.11.2026\nGesamtbetrag 500,00 €\nMwSt 19 %: 79,83 €\nDieses Angebot gilt 30 Tage.", kind: .other),
        CorpusCase(name: "neg-lieferschein", text: "Lieferschein 2026-33\nLieferdatum: 04.11.2026\n10 Stück Artikel A\nBitte Empfang quittieren.", kind: .other),
        CorpusCase(name: "neg-termin", text: "Hallo,\nwir treffen uns am 12.11.2026 um 10:00 Uhr im Büro. Bringt bitte die Unterlagen mit.\nViele Grüße", kind: .other),
        CorpusCase(name: "vertrag", text: "Dienstleistungsvertrag\nzwischen der Beispiel Software GmbH und der Muster Handel GmbH\n§ 1 Vertragsgegenstand\n§ 2 Vertragsbeginn und Laufzeit: 01.01.2027, Kündigungsfrist 3 Monate\nVertragsnummer: V-2026-88\nUnterschrift", kind: .contract, certain: true),
        CorpusCase(name: "behoerde-bussgeld", text: "Stadtverwaltung Musterstadt – Ordnungsamt\nBußgeldbescheid\nAktenzeichen: 32-2026-4711\nRechtsbehelfsbelehrung: Gegen diesen Bescheid können Sie Widerspruch einlegen.\nZu zahlender Betrag: 35,00 €\nFrist: 30.11.2026", kind: .letter, certain: true, gross: "35.00", currency: "EUR"),
        CorpusCase(name: "steuerbescheid", text: "Finanzamt Musterstadt\nEinkommensteuerbescheid 2025\nSteuernummer: 123/456/78901\nNachzahlung: 120,00 €\nEinspruch binnen eines Monats möglich.", kind: .taxNotice, certain: true),
        CorpusCase(name: "versicherung", text: "Beispiel Versicherung AG\nVersicherungsschein\nVersicherungsnummer: VS-998877\nVersicherungsnehmer: Erika Muster\nBeitrag jährlich 240,00 €\nSelbstbeteiligung 150,00 €", kind: .insurance, certain: true),
        CorpusCase(name: "kontoauszug", text: "Beispiel Bank AG\nKontoauszug 10/2026\nIBAN \(ibanDE)\nAlter Kontostand 1.000,00 €\n03.11.2026 Rechnung 4711 -119,00 €\nNeuer Kontostand 881,00 €\nBuchungstag Valuta Umsatz", kind: .bankStatement, certain: true, iban: ibanDE),
        CorpusCase(name: "kassenbon", text: "Beispiel Markt\nKassenbon\nBon-Nr. 00231\nBrot 3,20\nMilch 1,10\nSumme EUR 4,30\nBar 5,00\nRückgeld 0,70\nMwSt 7 %", kind: .receipt, certain: true),
        CorpusCase(name: "neg-newsletter-statement", text: "Subject: Your monthly update\nHere is your account summary of what is new. Unsubscribe anytime.", subject: "Your monthly update", kind: .other),
        CorpusCase(name: "neg-reisebestaetigung", text: "Buchungsbestätigung\nIhre Reise nach Musterstadt am 20.12.2026.\nBuchungsnummer: B-5566\nGesamtpreis 420,00 €", kind: .other),
    ]
}
