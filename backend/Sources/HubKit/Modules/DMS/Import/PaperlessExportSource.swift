import Foundation

// WP-D6: Quelle `export`: Verzeichnis eines `document_exporter`-Exports (manifest.json + Dateien). Nur Lesen, nie die Paperless-Datenbank.
// Das Verzeichnis liegt im Worker unter `DMS_IMPORT_ROOT/<mandanten-uuid>/<pfad>` (gleiche Schutzregeln wie der Konsumordner: Pfad relativ, Auflösen von Links
// darf die Mandantenwurzel nicht verlassen, Dateien werden nur als reguläre Dateien ohne Link gelesen). Benutzer- und Gruppeneinträge des Manifests (sie enthalten
// Kennwort-Hashes) werden nur gezählt, ihre Felder nie gelesen. Das Manifest wird vollständig geladen (Obergrenze `maxManifestBytes`); ein Stream-Parser fehlt (offen).

struct PaperlessExportSource: PaperlessSource {
    static let maxManifestBytes: Int64 = 128 * 1024 * 1024
    let key: String
    let dir: URL
    private let refs: PLReferences
    private let docs: [PLDoc]

    /// Das Verzeichnis der Quelle; nil, wenn es fehlt, kein Verzeichnis ist oder (nach Auflösen von Links) die Mandantenwurzel verlässt.
    static func resolve(root: String, tenant: UUID, path: String) -> URL? {
        DMSFolderScan.resolve(root: root, tenant: tenant, path: path)
    }

    /// Pfadsyntax einer Quelle (wie beim Konsumordner): relativ, ohne `..`, ohne führenden Punkt je Segment, nur einfache Zeichen.
    static func validPath(_ p: String) -> Bool {
        guard !p.isEmpty, p.count <= 200, !p.hasPrefix("/"), p.range(of: "^[A-Za-z0-9_. /-]+$", options: .regularExpression) != nil else { return false }
        return !p.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0.hasPrefix(".") }
    }

    init(dir: URL, key: String) throws {
        self.dir = dir; self.key = key
        let manifest = dir.appendingPathComponent("manifest.json")
        var st = stat()
        guard lstat(manifest.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ImportError("manifest_missing") }
        guard Int64(st.st_size) <= Self.maxManifestBytes else { throw ImportError("manifest_too_large") }
        guard let data = try? Data(contentsOf: manifest), let tree = try? JSONDecoder().decode(StrictJSON.self, from: data), case .array(let entries) = tree
        else { throw ImportError("manifest_invalid") }
        (refs, docs) = Self.parse(entries.map(\.native))
    }

    private static func parse(_ entries: [Any]) -> (PLReferences, [PLDoc]) {
        var refs = PLReferences()
        var docs: [Int64: PLDoc] = [:]
        var notes: [Int64: [PLNote]] = [:]
        var fields: [Int64: [PLFieldValue]] = [:]
        for case let e as [String: Any] in entries {
            guard let model = e["model"] as? String else { continue }
            if model == "auth.user" { refs.userCount += 1; continue }       // Felder (Kennwort-Hash) nie lesen
            if model == "auth.group" { refs.groupCount += 1; continue }
            guard let pk = PL.int(e["pk"]), let f = e["fields"] as? [String: Any] else { continue }
            func entity() -> PLEntity? {
                guard let name = PL.str(f["name"]) else { return nil }
                var x = PLEntity(id: pk, name: name)
                x.match = (f["match"] as? String) ?? ""
                x.algorithm = Int(PL.int(f["matching_algorithm"]) ?? 0)
                x.insensitive = (f["is_insensitive"] as? Bool) ?? true
                x.color = PL.str(f["color"])
                x.template = PL.str(f["path"])
                x.dataType = PL.str(f["data_type"])
                if let extra = f["extra_data"] as? [String: Any], let opts = extra["select_options"] as? [Any] {
                    x.options = opts.compactMap { o in
                        if let s = o as? String { return PLOption(id: nil, label: s) }
                        if let d = o as? [String: Any], let label = PL.str(d["label"]) { return PLOption(id: PL.str(d["id"]) ?? PL.int(d["id"]).map(String.init), label: label) }
                        return nil
                    }
                }
                return x
            }
            switch model {
            case "documents.correspondent": if let x = entity() { refs.correspondents.append(x) }
            case "documents.documenttype": if let x = entity() { refs.types.append(x) }
            case "documents.tag": if let x = entity() { refs.tags.append(x) }
            case "documents.storagepath": if let x = entity() { refs.paths.append(x) }
            case "documents.customfield": if let x = entity() { refs.fields.append(x) }
            case "documents.document":
                var d = PLDoc(id: pk)
                d.title = (f["title"] as? String) ?? ""
                d.content = (f["content"] as? String) ?? ""
                d.created = f["created"] as? String
                d.added = f["added"] as? String
                d.asn = PL.int(f["archive_serial_number"])
                d.correspondent = PL.int(f["correspondent"])
                d.type = PL.int(f["document_type"])
                d.path = PL.int(f["storage_path"])
                d.tags = ((f["tags"] as? [Any]) ?? []).compactMap(PL.int)
                d.owner = PL.int(f["owner"])
                d.checksum = PL.str(f["checksum"])
                d.archiveChecksum = PL.str(f["archive_checksum"])
                d.originalName = PL.str(f["original_filename"]) ?? PL.str(f["filename"])
                d.originalRef = PL.str(e["__exported_file_name__"])
                d.archiveRef = PL.str(e["__exported_archive_name__"])
                d.archiveAvailable = d.archiveRef != nil
                docs[pk] = d
            case "documents.note":
                if let doc = PL.int(f["document"]), let text = PL.str(f["note"]) { notes[doc, default: []].append(PLNote(id: pk, text: text, created: f["created"] as? String)) }
            case "documents.customfieldinstance":
                guard let doc = PL.int(f["document"]), let field = PL.int(f["field"]) else { continue }
                for k in ["value_text", "value_url", "value_date", "value_int", "value_float", "value_monetary", "value_bool", "value_select"] {
                    if let raw = f[k], !(raw is NSNull) { fields[doc, default: []].append(PLFieldValue(field: field, value: PLValue(native: raw))); break }
                }
            default: continue
            }
        }
        for id in docs.keys { docs[id]?.notes = notes[id] ?? []; docs[id]?.fields = fields[id] ?? [] }
        return (refs, docs.values.sorted { $0.id < $1.id })
    }

    func references() async throws -> PLReferences { refs }

    func pages(size: Int, _ body: ([PLDoc], Int?) async throws -> Void) async throws {
        var i = 0
        while i < docs.count {
            try Task.checkCancellation()
            try await body(Array(docs[i..<min(i + size, docs.count)]), docs.count)
            i += size
        }
    }

    func materialize(_ doc: PLDoc, _ role: PLFileRole, maxBytes: Int64) async throws -> LocalFile? {
        guard let rel = role == .original ? doc.originalRef : doc.archiveRef, let url = safeURL(rel) else { return nil }
        do { return try LocalFile.measure(url, temporary: false, maxBytes: maxBytes) }
        catch let e as ImportError { throw e }
        catch { return nil }
    }

    /// Datei im Exportverzeichnis: relativ, ohne `..`, keine Verknüpfung, reguläre Datei, nach Auflösen von Links noch im Verzeichnis.
    private func safeURL(_ rel: String) -> URL? {
        guard !rel.hasPrefix("/"), !rel.contains("\0"), !rel.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let url = dir.appendingPathComponent(rel)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(dir.path) else { return nil }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return url
    }
}
