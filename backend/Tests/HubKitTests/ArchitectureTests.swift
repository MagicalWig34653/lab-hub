import XCTest

/// WP-ST2: Der Kern kennt seine Module nicht. Bezeichner mit `DMS` oder `Invoice` stehen nur unter `Sources/HubKit/Modules/<Name>/`
/// und in der Modulliste (`Sources/HubKit/Modules/InstalledModules.swift`). Kommentare und Zeichenkettentexte zählen nicht (z. B. Umgebungsvariablen
/// wie `DMS_ALLOW_INTERNAL_TARGETS`), Interpolationen in Zeichenketten schon. Keine Datenbank nötig.
final class ArchitectureTests: XCTestCase {
    static let forbidden = ["DMS", "Invoice"]
    static let moduleList = "HubKit/Modules/InstalledModules.swift"

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    }

    /// Pfad relativ zu `Sources/` ist erlaubt, wenn er in einem Modulordner `HubKit/Modules/<Name>/` liegt oder die Modulliste ist.
    static func isAllowed(_ relative: String) -> Bool {
        if relative == moduleList { return true }
        let parts = relative.split(separator: "/")
        return parts.count >= 4 && parts[0] == "HubKit" && parts[1] == "Modules"
    }

    /// AK-ST2-4: kein `DMS*`/`Invoice*`-Bezeichner außerhalb der Modulordner und der Modulliste.
    func testAKST2_4_coreNamesNoModuleIdentifiers() throws {
        let root = Self.sourcesRoot
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return XCTFail("Sources fehlt: \(root.path)") }
        var scanned = 0, findings: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            scanned += 1
            if Self.isAllowed(relative) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = SwiftIdentifierScanner.scan(text)
            // Endet der Lexer nicht im Code, hat er sich verlesen und könnte Bezeichner übersehen
            XCTAssertTrue(result.clean, "Scanner endet nicht im Code: \(relative)")
            for (line, name) in result.identifiers where Self.forbidden.contains(where: name.contains) {
                findings.append("\(relative):\(line) \(name)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "zu wenige Quelldateien gefunden: \(root.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.moduleList).path), "Modulliste fehlt")
        XCTAssertEqual(findings, [], "Modulbezeichner im Kern:\n" + findings.joined(separator: "\n"))
    }

    /// AK-ST2-4: Der Scanner selbst (sonst wäre ein grüner Test wertlos): Code und Interpolationen zählen, Kommentare und Texte nicht.
    func testAKST2_4_scannerFindsCodeButNotCommentsOrText() {
        let sample = """
            // DMSComment
            /* DMSBlock /* nested DMSNested */ still */
            let a = DMSError.trashed
            let b = "DMS_ALLOW \\(InvoiceModule().key) tail"
            let c = \"\"\"
                DMSMulti \\(x.DMSInside)
                \"\"\"
            let d = #"DMSRaw \\(notInterpolated)"#
            let e = "esc \\" DMSEscaped"
            """
        let names = SwiftIdentifierScanner.identifiers(in: sample).map(\.1)
        XCTAssertTrue(names.contains("DMSError"))
        XCTAssertTrue(names.contains("InvoiceModule"))
        XCTAssertTrue(names.contains("DMSInside"))
        for hidden in ["DMSComment", "DMSBlock", "DMSNested", "DMS_ALLOW", "DMSMulti", "DMSRaw", "DMSEscaped", "notInterpolated"] {
            XCTAssertFalse(names.contains(hidden), hidden)
        }
        XCTAssertEqual(SwiftIdentifierScanner.identifiers(in: sample).first { $0.1 == "DMSError" }?.0, 3)
        XCTAssertTrue(SwiftIdentifierScanner.scan(sample).clean)
        XCTAssertFalse(SwiftIdentifierScanner.scan("let x = \"offen").clean)
        XCTAssertTrue(ArchitectureTests.isAllowed("HubKit/Modules/DMS/DMSModule.swift"))
        XCTAssertTrue(ArchitectureTests.isAllowed("HubKit/Modules/InstalledModules.swift"))
        XCTAssertFalse(ArchitectureTests.isAllowed("HubKit/Modules/HubModule.swift"))
        XCTAssertFalse(ArchitectureTests.isAllowed("HubKit/Worker/WorkerCommand.swift"))
    }
}

/// Kleiner Lexer für Swift-Quelltext: liefert Bezeichner (mit Zeile) außerhalb von Kommentaren und Zeichenkettentexten.
/// Unterstützt Zeilen- und (verschachtelte) Blockkommentare, ein- und mehrzeilige Zeichenketten, Raw-Strings (`#"…"#`) und Interpolationen `\( … )`.
enum SwiftIdentifierScanner {
    private enum Frame { case code(parens: Int), string(multiline: Bool, hashes: Int) }

    static func identifiers(in source: String) -> [(Int, String)] { scan(source).identifiers }

    /// `clean`: Am Ende steht der Lexer wieder im Code der obersten Ebene (keine offene Zeichenkette oder Interpolation).
    static func scan(_ source: String) -> (identifiers: [(Int, String)], clean: Bool) {
        let c = Array(source.unicodeScalars)
        var i = 0, line = 1, out: [(Int, String)] = []
        var stack: [Frame] = [.code(parens: 0)]
        func at(_ k: Int) -> Character? { k < c.count ? Character(c[k]) : nil }
        func starts(_ s: String, _ k: Int) -> Bool {
            var j = k
            for ch in s.unicodeScalars { guard j < c.count, c[j] == ch else { return false }; j += 1 }
            return true
        }
        func isIdentStart(_ ch: Character) -> Bool { ch == "_" || ch.isLetter }
        func isIdent(_ ch: Character) -> Bool { ch == "_" || ch.isLetter || ch.isNumber }
        while i < c.count {
            let ch = Character(c[i])
            if ch == "\n" { line += 1 }
            switch stack[stack.count - 1] {
            case .string(let multiline, let hashes):
                let close = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
                if ch == "\\" && starts(String(repeating: "#", count: hashes) + "(", i + 1) {
                    i += 2 + hashes; stack.append(.code(parens: 0)); continue
                }
                if ch == "\\" && hashes == 0 { if at(i + 1) == "\n" { line += 1 }; i += 2; continue }
                if starts(close, i) { stack.removeLast(); i += close.unicodeScalars.count; continue }
                i += 1
            case .code(let parens):
                if starts("//", i) {
                    while i < c.count, c[i] != "\n" { i += 1 }
                    continue
                }
                if starts("/*", i) {
                    var depth = 0
                    repeat {
                        if starts("/*", i) { depth += 1; i += 2 } else if starts("*/", i) { depth -= 1; i += 2 }
                        else { if c[i] == "\n" { line += 1 }; i += 1 }
                    } while depth > 0 && i < c.count
                    continue
                }
                var hashes = 0
                while at(i + hashes) == "#" { hashes += 1 }
                if at(i + hashes) == "\"" {
                    let multiline = starts("\"\"\"", i + hashes)
                    i += hashes + (multiline ? 3 : 1)
                    stack.append(.string(multiline: multiline, hashes: hashes)); continue
                }
                if ch == "(" { stack[stack.count - 1] = .code(parens: parens + 1); i += 1; continue }
                if ch == ")" {
                    if parens == 0 && stack.count > 1 { stack.removeLast() } else { stack[stack.count - 1] = .code(parens: max(0, parens - 1)) }
                    i += 1; continue
                }
                if isIdentStart(ch) {
                    var j = i, name = ""
                    while let x = at(j), isIdent(x) { name.append(x); j += 1 }
                    out.append((line, name)); i = j; continue
                }
                i += 1
            }
        }
        if case .code = stack[stack.count - 1], stack.count == 1 { return (out, true) }
        return (out, false)
    }
}
