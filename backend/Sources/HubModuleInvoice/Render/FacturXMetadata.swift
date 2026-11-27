import Foundation

// WP-R6b (ADR 0008): Typst schreibt keine Factur-X-Metadaten. Das `fx:`-Schema kommt in die vorhandene `pdfaExtension`-Liste (eine zweite wäre
// ungültig), die vier Werte in eine eigene `rdf:Description`.

enum FacturXMetadata {
    enum Level: String, Sendable, CaseIterable {
        case minimum = "MINIMUM", basicWL = "BASIC WL", basic = "BASIC", en16931 = "EN 16931", extended = "EXTENDED"
    }

    static let fileName = "factur-x.xml"
    static let namespace = "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
    private static let listStart = "<pdfaExtension:schemas><rdf:Bag>", rdfEnd = "</rdf:RDF>"

    /// `nil`, wenn die erwarteten Stellen fehlen oder das Schema schon enthalten ist.
    static func insert(into xmp: String, conformanceLevel: Level) -> String? {
        guard !xmp.contains(namespace), let list = xmp.range(of: listStart), xmp.contains(rdfEnd) else { return nil }
        let properties = [("DocumentFileName", "name of the embedded XML invoice file"), ("DocumentType", "INVOICE"),
                          ("Version", "The actual version of the Factur-X XML schema"), ("ConformanceLevel", "The conformance level of the embedded Factur-X data")]
            .map { name, description in
                "<rdf:li rdf:parseType=\"Resource\"><pdfaProperty:name>\(name)</pdfaProperty:name><pdfaProperty:valueType>Text</pdfaProperty:valueType>"
                    + "<pdfaProperty:category>external</pdfaProperty:category><pdfaProperty:description>\(description)</pdfaProperty:description></rdf:li>"
            }.joined()
        let schema = "<rdf:li rdf:parseType=\"Resource\"><pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>"
            + "<pdfaSchema:namespaceURI>\(namespace)</pdfaSchema:namespaceURI><pdfaSchema:prefix>fx</pdfaSchema:prefix>"
            + "<pdfaSchema:property><rdf:Seq>\(properties)</rdf:Seq></pdfaSchema:property></rdf:li>"
        let values = "<rdf:Description rdf:about=\"\" xmlns:fx=\"\(namespace)\"><fx:DocumentType>INVOICE</fx:DocumentType>"
            + "<fx:DocumentFileName>\(fileName)</fx:DocumentFileName><fx:Version>1.0</fx:Version>"
            + "<fx:ConformanceLevel>\(conformanceLevel.rawValue)</fx:ConformanceLevel></rdf:Description>"
        var out = xmp
        out.insert(contentsOf: schema, at: list.upperBound)
        guard let end = out.range(of: rdfEnd, options: .backwards) else { return nil }
        out.insert(contentsOf: values, at: end.lowerBound)
        return out
    }

    /// Aus der Ausgabe von `qpdf --json=2 --json-stream-data=inline` die Eingabe für `--update-from-json` bauen: nur der XMP-Strom des Katalogs.
    static func update(qpdfJSON: Data, conformanceLevel: Level) throws -> Data {
        let broken = InvoiceRenderError.failed(tool: "factur-x", exitCode: 0, diagnostics: "XMP-Metadaten nicht wie erwartet")
        guard let root = try JSONSerialization.jsonObject(with: qpdfJSON) as? [String: Any], let parts = root["qpdf"] as? [Any], parts.count == 2,
              let objects = parts[1] as? [String: Any],
              let trailer = (objects["trailer"] as? [String: Any])?["value"] as? [String: Any], let catalogRef = trailer["/Root"] as? String,
              let catalog = (objects["obj:" + catalogRef] as? [String: Any])?["value"] as? [String: Any], let metadataRef = catalog["/Metadata"] as? String,
              let stream = (objects["obj:" + metadataRef] as? [String: Any])?["stream"] as? [String: Any],
              var dictionary = stream["dict"] as? [String: Any], dictionary["/Filter"] == nil,
              let encoded = stream["data"] as? String, let raw = Data(base64Encoded: encoded), let xmp = String(data: raw, encoding: .utf8),
              let enriched = insert(into: xmp, conformanceLevel: conformanceLevel)
        else { throw broken }
        dictionary["/Length"] = nil  // setzt qpdf selbst
        let object: [String: Any] = ["stream": ["dict": dictionary, "data": Data(enriched.utf8).base64EncodedString()]]
        // qpdf liest Stromdaten direkt aus der Datei und versteht das maskierte `\/` dort nicht
        return try JSONSerialization.data(withJSONObject: ["qpdf": [parts[0], ["obj:" + metadataRef: object]]], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
