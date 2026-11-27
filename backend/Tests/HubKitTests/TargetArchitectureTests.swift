import XCTest

/// WP-ST3 (F-14): Kern und Module sind eigene SwiftPM-Targets. `HubCore` kennt weder Module noch den Zusammenbau, jedes `HubModule<Name>` kennt nur
/// `HubCore`, `HubKit` setzt zusammen. Geprüft werden das Package-Manifest und die `import`-Zeilen der Quellen (SwiftPM selbst lässt einen nicht
/// deklarierten Import durch, wenn das Modul zufällig schon gebaut ist). Keine Datenbank nötig.
final class TargetArchitectureTests: XCTestCase {
    static let core = "HubCore"
    static let assembly = "HubKit"
    static let modules = ["HubModuleDMS", "HubModuleInvoice"]
    static var internalTargets: Set<String> { Set([core, assembly, "App"] + modules) }

    static var backendRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Paketinterne Abhängigkeiten je Target aus dem Manifesttext (nur Zeichenketten, die ein eigenes Target nennen).
    static func manifestDependencies(_ manifest: String) throws -> [String: Set<String>] {
        // Zeilenkommentare weg (URLs mit `//` stehen in Zeichenketten hinter `:` und bleiben)
        let text = manifest.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }.joined(separator: "\n")
        let head = try NSRegularExpression(pattern: #"\.(?:target|executableTarget|testTarget)(\()\s*name:\s*"([A-Za-z0-9_]+)""#)
        let ns = text as NSString
        var out: [String: Set<String>] = [:]
        var consumed = 0  // `.target(name:)` innerhalb einer Deklaration ist eine Abhängigkeit, kein weiteres Target
        for hit in head.matches(in: text, range: NSRange(location: 0, length: ns.length)) where hit.range.location >= consumed {
            var depth = 0, end = hit.range(at: 1).location
            repeat {
                let ch = ns.substring(with: NSRange(location: end, length: 1))
                if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
                end += 1
            } while depth > 0 && end < ns.length
            consumed = end
            let body = ns.substring(with: NSRange(location: hit.range.upperBound, length: max(0, end - hit.range.upperBound)))
            let strings = body.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            out[ns.substring(with: hit.range(at: 2))] = Set(strings).intersection(internalTargets)
        }
        return out
    }

    /// Importierte Modulnamen einer Quelldatei, auch mit Attributen, Zugriffsstufe oder Einzelimport (`import struct HubKit.X`).
    static func imports(in source: String) throws -> Set<String> {
        let line = try NSRegularExpression(
            pattern: #"^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*(?:(?:public|package|internal|fileprivate|private)[ \t]+)?import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|let|var)[ \t]+)?([A-Za-z0-9_]+)"#,
            options: .anchorsMatchLines)
        let ns = source as NSString
        return Set(line.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    private func dependencies() throws -> [String: Set<String>] {
        try Self.manifestDependencies(String(contentsOf: Self.backendRoot.appendingPathComponent("Package.swift"), encoding: .utf8))
    }

    /// AK-ST3-1: die Targets gibt es, `HubKit` setzt Kern und alle Module zusammen, `App` nutzt den Zusammenbau.
    func testAKST3_1_manifestDeclaresCoreModulesAndAssembly() throws {
        let deps = try dependencies()
        for target in [Self.core, Self.assembly, "App"] + Self.modules { XCTAssertNotNil(deps[target], "Target fehlt: \(target)") }
        XCTAssertEqual(deps[Self.assembly], Set([Self.core] + Self.modules))
        XCTAssertEqual(deps["App"], [Self.assembly])
    }

    /// AK-ST3-2: der Kern hängt von keinem eigenen Target ab, jedes Modul nur vom Kern.
    func testAKST3_2_manifestSeparatesCoreAndModules() throws {
        let deps = try dependencies()
        XCTAssertEqual(deps[Self.core], [])
        for module in Self.modules { XCTAssertEqual(deps[module], [Self.core], module) }
    }

    /// AK-ST3-2: jedes Modul-Target im Manifest steht in der Liste oben (ein neues Modul kommt nicht ungeprüft dazu).
    func testAKST3_2_everySourceTargetIsKnown() throws {
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.backendRoot.appendingPathComponent("Sources").path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(folders), Self.internalTargets)
        XCTAssertEqual(Set(try dependencies().keys), Self.internalTargets.union(["HubKitTests"]))
    }

    /// AK-ST3-2: keine Quelle importiert ein eigenes Target, das ihr Target nicht deklariert (Modul → Modul, Kern → Modul, … → `HubKit`).
    func testAKST3_2_sourcesImportOnlyDeclaredTargets() throws {
        let deps = try dependencies()
        var findings: [String] = [], scanned: [String: Int] = [:]
        for target in [Self.core, Self.assembly, "App"] + Self.modules {
            let root = Self.backendRoot.appendingPathComponent("Sources/\(target)")
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                scanned[target, default: 0] += 1
                let imported = try Self.imports(in: String(contentsOf: url, encoding: .utf8)).intersection(Self.internalTargets)
                for name in imported.subtracting(deps[target] ?? []).sorted() { findings.append("\(target)/\(url.lastPathComponent): import \(name)") }
            }
            XCTAssertGreaterThan(scanned[target] ?? 0, 0, "keine Quellen: \(target)")
        }
        XCTAssertGreaterThan(scanned[Self.core] ?? 0, 20)
        XCTAssertEqual(findings, [], findings.joined(separator: "\n"))
    }

    /// Rest aus WP-ST2: Der Kern nennt kein Modul, auch nicht in Zeichenketten (Umgebungsvariablen, Hilfetexte) oder Kommentaren. Einzige Ausnahme ist die
    /// Datei mit dem gespeicherten Migrationsnamen `dms_026_api_token_tenant`, der sich nicht ändern darf.
    func testAKST3_2_coreTextNamesNoModule() throws {
        let root = Self.backendRoot.appendingPathComponent("Sources/\(Self.core)")
        var scanned = 0, findings: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            if url.lastPathComponent == "ApiTokenTenantMigration.swift" { continue }
            for (index, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where ["dms", "invoice", "paperless"].contains(where: line.lowercased().contains) {
                findings.append("\(url.lastPathComponent):\(index + 1) \(line.trimmingCharacters(in: .whitespaces).prefix(100))")
            }
        }
        XCTAssertGreaterThan(scanned, 20, "keine Kernquellen: \(root.path)")
        XCTAssertEqual(findings, [], "Modulnamen im Kern:\n" + findings.joined(separator: "\n"))
    }

    /// AK-ST3-2: die Builds in Skripten und Images brechen bei nicht deklarierten Importen ab.
    func testAKST3_2_buildsRejectUndeclaredImports() throws {
        let repo = Self.backendRoot.deletingLastPathComponent()  // `scripts/ci-backend.sh` kopiert diese Dateien mit in den Test-Container
        for file in ["scripts/ci.sh", "scripts/ci-backend.sh", "Dockerfile", "Dockerfile.worker"] {
            let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
            let builds = text.split(separator: "\n").filter { !$0.hasPrefix("#") && ($0.contains("swift build") || $0.contains("swift test")) }
            XCTAssertFalse(builds.isEmpty, file)
            for line in builds where !line.hasPrefix("echo") {
                XCTAssertTrue(line.contains("--explicit-target-dependency-import-check=error"), "\(file): \(line)")
            }
        }
    }

    /// Die Hilfen selbst (sonst wäre ein grüner Test wertlos).
    func testAKST3_2_parsersSeeDependenciesAndImports() throws {
        let manifest = """
            targets: [
              // .target(name: "Gone", dependencies: ["HubKit"])
              .target(name: "HubCore", dependencies: [.product(name: "Vapor", package: "vapor")]),
              .target(name: "HubModuleDMS", dependencies: ["HubCore", .target(name: "HubModuleInvoice")]),
              .executableTarget(name: "App", dependencies: ["HubKit"])
            ]
            """
        let deps = try Self.manifestDependencies(manifest)
        XCTAssertNil(deps["Gone"])
        XCTAssertEqual(deps["HubCore"], [])
        // auch die Schreibweise `.target(name:)` als Abhängigkeit darf eine Modul-Kopplung nicht verstecken
        XCTAssertEqual(deps["HubModuleDMS"], ["HubCore", "HubModuleInvoice"])
        XCTAssertNil(deps["HubModuleInvoice"])
        XCTAssertEqual(deps["App"], ["HubKit"])
        let source = """
            import Vapor
            @testable import HubKit
            public import struct HubModuleDMS.X
            @_exported import HubCore
            // import HubModuleInvoice
            """
        XCTAssertEqual(try Self.imports(in: source), ["Vapor", "HubKit", "HubModuleDMS", "HubCore"])
    }
}
