// WP-R6b: Standardlayout 1 für alle fünf Belegarten (Typst). Alle Werte kommen als Zeichenketten aus `data.json` (`InvoiceRenderData`); Zeichenketten
// werden in Typst nie als Quelltext ausgewertet. Keine Paketimporte. Ligaturen und kontextabhängige Ersetzungen sind aus, damit Nutzertext Zeichen
// für Zeichen erscheint. Jede sichtbare Änderung an dieser Vorlage ändert die PDF-Bytes: dann `version` erhöhen und die Referenzen neu erzeugen.

enum InvoiceStandardLayout {
    static let key = "standard"
    static let version = 1

    static let template = #"""
    #let d = json("data.json")
    #set document(title: d.title + " " + d.number, author: d.senderName, date: auto)
    #set text(font: "Inter", size: 9pt, lang: "de", hyphenate: false, ligatures: false, features: (calt: 0))
    #set par(leading: 0.55em)

    #let footer = context {
      set text(size: 7pt, fill: luma(80))
      line(length: 100%, stroke: 0.4pt + luma(160))
      grid(columns: (1fr, 1fr, 1.2fr), column-gutter: 6mm, ..d.footerColumns.map(column => column.map(entry => [#entry]).join(linebreak())))
      align(right)[Seite #counter(page).display() von #counter(page).final().first()]
    }
    #set page(
      paper: "a4",
      margin: (left: 22mm, right: 18mm, top: 22mm, bottom: 36mm),
      footer: footer,
      header: context if counter(page).get().first() > 1 { align(right, text(size: 8pt, fill: luma(80))[#d.title #d.number]) },
    )

    #if d.attach {
      pdf.attach("factur-x.xml", relationship: "alternative", mime-type: "text/xml", description: "Factur-X E-Rechnung")
    }

    // Briefkopf
    #align(right)[
      #text(size: 14pt, weight: "bold")[#d.senderName] \
      #text(size: 8pt, fill: luma(80), d.senderLines.map(entry => [#entry]).join(linebreak()))
    ]
    #v(6mm)

    // Anschrift und Kopfdaten
    #grid(
      columns: (85mm, 1fr),
      column-gutter: 8mm,
      [
        #text(size: 6.5pt, fill: luma(100))[#underline(d.senderLine)] \
        #v(1mm)
        #d.recipientLines.map(entry => [#entry]).join(linebreak())
      ],
      align(right, table(
        columns: 2, stroke: none, inset: (x: 3pt, y: 2pt), align: (left, right),
        ..d.meta.map(m => ([#m.label], [#m.value])).flatten(),
      )),
    )
    #v(10mm)

    #text(size: 13pt, weight: "bold")[#d.title #d.number]
    #v(3mm)
    #if d.at("headerText", default: none) != none [
      #d.headerText
      #v(3mm)
    ]

    // Positionstabelle
    #let widths = (position: 8mm, description: 1fr, quantity: auto, price: auto, tax: auto, total: auto)
    #let left-aligned = ("position", "description")
    #table(
      columns: d.columns.map(c => widths.at(c.key)),
      align: (x, y) => if d.columns.at(x).key in left-aligned { left + top } else { right + top },
      inset: (x: 3pt, y: 4pt),
      stroke: (x, y) => (bottom: if y == 0 { 0.8pt } else { 0.3pt + luma(200) }),
      table.header(..d.columns.map(c => text(weight: "bold")[#c.label])),
      ..d.rows.map(row => {
        if row.kind == "text" {
          (table.cell(colspan: d.columns.len(), align: left)[#row.text],)
        } else {
          row.cells.enumerate().map(((i, value)) => {
            if d.columns.at(i).key == "description" and row.at("detail", default: none) != none {
              [#value \ #text(size: 7.5pt, fill: luma(90))[#row.detail]]
            } else {
              [#value]
            }
          })
        }
      }).flatten(),
    )

    // Summenblock
    #if d.totals.len() > 0 {
      v(2mm)
      block(breakable: false, width: 100%, align(right, table(
        columns: 2, stroke: none, inset: (x: 3pt, y: 2.5pt), align: (left, right),
        ..d.totals.map(t => {
          if t.strong {
            (table.hline(stroke: 0.8pt), text(weight: "bold")[#t.label], text(weight: "bold")[#t.value])
          } else {
            ([#t.label], [#t.value])
          }
        }).flatten(),
      )))
    }

    #for note in d.notes {
      v(3mm)
      par[#note]
    }
    #if d.at("footerText", default: none) != none [
      #v(4mm)
      #d.footerText
    ]
    """#
}
