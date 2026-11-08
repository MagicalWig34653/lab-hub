import XCTest
import Foundation
import AsyncHTTPClient
@testable import HubKit

// WP-H10: Befunde 3 (Import-Ziel), 6 (Pfadpräfix, Manifest-Race) und 7 (Schlüssellänge). Keine Datenbank, nur synthetische Daten.

final class H10HardeningTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-h10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Befund 6

    /// AK-H10-6: Ein Geschwisterverzeichnis mit gleichem Präfix (`exp2` neben `exp`) besteht die Prüfung nicht; Dateien im Verzeichnis selbst schon.
    func testAKH10_6_siblingDirectoryWithSamePrefixIsRejected() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let exp = root.appendingPathComponent("exp"), exp2 = root.appendingPathComponent("exp2")
        try FileManager.default.createDirectory(at: exp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exp2, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: exp.appendingPathComponent("manifest.json"))
        try Data("%PDF-1.4 synthetic".utf8).write(to: exp.appendingPathComponent("a.pdf"))
        try Data("%PDF-1.4 outside".utf8).write(to: exp2.appendingPathComponent("secret.pdf"))
        // Link `exp/escape` -> `exp2`: der aufgelöste Elternpfad `…/exp2` beginnt mit `…/exp`
        try FileManager.default.createSymbolicLink(at: exp.appendingPathComponent("escape"), withDestinationURL: exp2)
        let source = try PaperlessExportSource(dir: exp, key: "export:exp")
        XCTAssertNotNil(source.safeURL("a.pdf"))
        XCTAssertNil(source.safeURL("escape/secret.pdf"), "Geschwisterverzeichnis mit gleichem Präfix darf nicht passieren")
        XCTAssertNil(source.safeURL("../exp2/secret.pdf"))
        XCTAssertTrue(PaperlessExportSource.isInside("/r/exp/sub", root: "/r/exp"))
        XCTAssertTrue(PaperlessExportSource.isInside("/r/exp", root: "/r/exp"))
        XCTAssertFalse(PaperlessExportSource.isInside("/r/exp2", root: "/r/exp"))
        XCTAssertFalse(PaperlessExportSource.isInside("/r/exp2/x", root: "/r/exp"))
        XCTAssertFalse(PaperlessExportSource.isInside("/r", root: "/r/exp"))
    }

    /// AK-H10-6: Das Manifest wird ohne Symlink-Race gelesen: ein Link als `manifest.json` (auch auf eine Datei im Geschwisterverzeichnis) wird nicht verfolgt; eine zwischen Prüfung
    /// und Öffnen ausgetauschte Datei wird am Deskriptor erkannt (`openContained` verweigert Links und fremde Lage).
    func testAKH10_6_manifestSymlinkIsNeverFollowed() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let exp = root.appendingPathComponent("exp"), exp2 = root.appendingPathComponent("exp2")
        try FileManager.default.createDirectory(at: exp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exp2, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: exp2.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: exp.appendingPathComponent("manifest.json"), withDestinationURL: exp2.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try PaperlessExportSource(dir: exp, key: "k")) { XCTAssertEqual(($0 as? ImportError)?.code, "manifest_missing") }
        // direkter Test von openContained: Datei in exp2 ist für exp „außerhalb“, ein Link wird nicht geöffnet, eine normale Datei schon
        let outside = exp2.appendingPathComponent("manifest.json")
        XCTAssertNil(PaperlessExportSource.openContained(outside, within: exp))
        XCTAssertNil(PaperlessExportSource.openContained(exp.appendingPathComponent("manifest.json"), within: exp))
        try Data("[]".utf8).write(to: exp.appendingPathComponent("ok.json"))
        let fd = try XCTUnwrap(PaperlessExportSource.openContained(exp.appendingPathComponent("ok.json"), within: exp))
        close(fd)
        try FileManager.default.removeItem(at: exp.appendingPathComponent("manifest.json"))
        try Data("[]".utf8).write(to: exp.appendingPathComponent("manifest.json"))
        XCTAssertNoThrow(try PaperlessExportSource(dir: exp, key: "k"))
        // Messung mit Deskriptorprüfung: Datei durch Link ersetzt -> `file_unsafe`, nie der Inhalt außerhalb
        let target = exp.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4 x".utf8).write(to: target)
        XCTAssertNoThrow(try LocalFile.measure(target, temporary: false, maxBytes: 1000, within: exp))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: exp2.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try LocalFile.measure(target, temporary: false, maxBytes: 1000, within: exp)) { XCTAssertEqual(($0 as? ImportError)?.code, "file_unsafe") }
    }

    // MARK: Befund 7

    /// AK-H10-7: Schlüssel unter 32 Byte werden nicht verwendet; ein gesetzter, aber zu kurzer Schlüssel verhindert den Start (klare Meldung mit Erzeugungshinweis).
    func testAKH10_7_secretKeyMinimumLength() throws {
        XCTAssertNil(SecretBox(secretKey: String(repeating: "k", count: 31)))
        XCTAssertNotNil(SecretBox(secretKey: String(repeating: "k", count: 32)))
        XCTAssertNil(SecretBox(secretKey: "kurz-aber-ueber-16-Zeichen"), "früher genügten 16 Zeichen")
        XCTAssertNotNil(SecretBox(secretKey: Data((0..<32).map { UInt8($0) }).base64EncodedString()), "openssl rand -base64 32 (44 Zeichen)")
        XCTAssertTrue(SecretBox.isTooShort("abc")); XCTAssertFalse(SecretBox.isTooShort(nil)); XCTAssertFalse(SecretBox.isTooShort("")); XCTAssertFalse(SecretBox.isTooShort(String(repeating: "k", count: 32)))
        let base = ["DB_HOST": "127.0.0.1", "DB_PASSWORD": "x"]
        XCTAssertThrowsError(try HubConfig.fromEnvironment(base.merging(["SECRET_KEY": "zu-kurz"]) { $1 })) { e in
            let text = String(describing: e)
            XCTAssertTrue(text.contains("32") && text.contains("openssl rand -base64 32"), text)
            XCTAssertFalse(text.contains("zu-kurz"), "der Schlüssel steht nie in der Meldung")
        }
        XCTAssertNoThrow(try HubConfig.fromEnvironment(base.merging(["SECRET_KEY": String(repeating: "k", count: 32)]) { $1 }))
        XCTAssertNoThrow(try HubConfig.fromEnvironment(base), "ohne Schlüssel startet der Hub (nur keine Mail-/API-Quellen)")
    }

    // MARK: Befund 3 (Import)

    private func endpoint(_ raw: String, _ policy: PaperlessEndpoint.Policy = .init()) throws -> PaperlessEndpoint { try PaperlessEndpoint.parse(raw, policy: policy) }

    /// AK-H10-3: Paperless-Ziel: alle Schreibweisen interner Adressen werden schon beim Parsen abgelehnt, mit Betreiber-Erlaubnis nicht.
    func testAKH10_3_paperlessRejectsInternalNotations() throws {
        for h in ["https://127.1", "https://2130706433", "https://0x7f000001", "https://[::ffff:127.0.0.1]", "https://10.1.2.3", "https://172.16.5.5", "https://192.168.0.10",
                  "https://169.254.169.254", "https://[fc00::1]", "https://[fe80::1]", "https://100.64.0.1", "https://printer.local", "https://localhost:8443"] {
            XCTAssertThrowsError(try endpoint(h), h) { XCTAssertEqual(($0 as? ImportError)?.code, "host_not_allowed", h) }
        }
        XCTAssertNoThrow(try endpoint("https://paperless.example.org"))
        var op = PaperlessEndpoint.Policy(); op.allowInternalTargets = true
        XCTAssertNoThrow(try endpoint("https://10.1.2.3", op))
        XCTAssertTrue(PaperlessEndpoint.Policy.fromEnvironment(["DMS_ALLOW_INTERNAL_TARGETS": "true"]).allowInternal)
        XCTAssertFalse(PaperlessEndpoint.Policy.fromEnvironment([:]).allowInternal)
    }

    /// AK-H10-3: Vor dem Lauf wird aufgelöst: zeigt ein harmlos aussehender Name (DNS-Rebinding) auf eine interne Adresse, scheitert der Lauf mit `host_not_allowed`;
    /// bei öffentlicher Adresse wird genau diese IP für den Connect geliefert (kein zweiter Lookup).
    func testAKH10_3_paperlessResolvesAndPinsVerifiedAddress() async throws {
        var policy = PaperlessEndpoint.Policy()
        let e = try endpoint("https://paperless.example.org", policy)
        policy.resolver = { _ in [.v4([93, 184, 216, 34])] }
        let pinned = try await PaperlessEndpoint.vetTarget(e, policy: policy)
        XCTAssertEqual(pinned, "93.184.216.34")
        for evil in [[NetworkTarget.IP.v4([127, 0, 0, 1])], [.v4([93, 184, 216, 34]), .v4([169, 254, 169, 254])], [.v6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1])]] {
            policy.resolver = { _ in evil }
            do { _ = try await PaperlessEndpoint.vetTarget(e, policy: policy); XCTFail("\(evil)") } catch let err as ImportError { XCTAssertEqual(err.code, "host_not_allowed") }
        }
        policy.resolver = { _ in [] }
        do { _ = try await PaperlessEndpoint.vetTarget(e, policy: policy); XCTFail() } catch let err as ImportError { XCTAssertEqual(err.code, "source_unreachable") }
        // Betreiber erlaubt interne Ziele
        policy.allowInternalTargets = true; policy.resolver = { _ in [.v4([10, 0, 0, 5])] }
        let internalPinned = try await PaperlessEndpoint.vetTarget(e, policy: policy)
        XCTAssertEqual(internalPinned, "10.0.0.5")
        // IP-Literal: nichts umzulenken
        let lit = try endpoint("https://10.0.0.5", policy)
        let none = try await PaperlessEndpoint.vetTarget(lit, policy: policy)
        XCTAssertNil(none)
        let client = PaperlessAPISource.makeClient(host: e.host, pinnedIP: internalPinned)
        try await client.shutdown()
    }
}
