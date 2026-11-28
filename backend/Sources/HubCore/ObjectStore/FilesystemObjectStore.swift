import Foundation
import NIOCore

/// Filesystem backend. Only for single-host setups with an explicitly configured volume path (ADR 0003: no container FS state,
/// no replicas on several nodes). Writes go to `<root>/.staging/<uuid>` and are renamed atomically after the hash was verified.
public struct FilesystemObjectStore: ObjectStore {
    public let kind = ObjectStoreKind.fs
    public let root: URL
    public init(root: URL) { self.root = root }

    private var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }
    private func url(_ key: ObjectKey) -> URL { root.appendingPathComponent(key.path) }

    private func mkdir(_ u: URL) throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func put(tenant: UUID, stream: ByteStream, expectedSHA256: String?) async throws -> StoredObject {
        let expected = try normalizedExpectedHash(expectedSHA256)
        try mkdir(staging)
        let tmp = staging.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ObjectStoreError.io("create")
        }
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: tmp) } }
        var hasher = StreamHasher()
        do {
            let fd = open(tmp.path, O_WRONLY)
            guard fd >= 0 else { throw ObjectStoreError.io("open") }
            defer { close(fd) }
            for try await chunk in stream {
                hasher.update(chunk)
                try chunk.withUnsafeReadableBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(fd, raw.baseAddress! + off, raw.count - off)
                        guard n > 0 else { throw ObjectStoreError.io("write") }
                        off += n
                    }
                }
            }
        }
        let hash = hasher.finish()
        if let expected, expected != hash { throw ObjectStoreError.hashMismatch }
        let key = try ObjectKey(tenantID: tenant, sha256: hash)
        let target = url(key)
        // Karte 3: Dedup frischt die Änderungszeit auf (Schonfrist des Aufräumlaufs); ist die Datei inzwischen weg, wird sie neu abgelegt.
        if FileManager.default.fileExists(atPath: target.path), utimes(target.path, nil) == 0 {
            return StoredObject(key: key, size: hasher.size, deduplicated: true)
        }
        try mkdir(target.deletingLastPathComponent())
        guard rename(tmp.path, target.path) == 0 else { throw ObjectStoreError.io("rename") }
        committed = true
        return StoredObject(key: key, size: hasher.size, deduplicated: false)
    }

    public func get(_ key: ObjectKey) async throws -> ByteStream {
        guard FileManager.default.fileExists(atPath: url(key).path) else { throw ObjectStoreError.notFound }
        let fd = open(url(key).path, O_RDONLY)
        guard fd >= 0 else { throw ObjectStoreError.notFound }
        // WP-H11: Deskriptor gehört einer Klasse; `deinit` schließt ihn auch, wenn der Strom verworfen wird (Abbruch, Cancel) oder `read` fehlschlägt.
        let handle = DescriptorHandle(fd)
        return ByteStream(unfolding: {
            guard handle.isOpen else { return nil }
            var buf = ByteBuffer()
            do {
                let n = try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: objectStoreChunkSize) { raw in
                    let r = read(handle.fd, raw.baseAddress!, raw.count)
                    if r < 0 { throw ObjectStoreError.io("read") }
                    return r
                }
                if n == 0 { handle.close(); return nil }
                return buf
            } catch {
                handle.close()
                throw error
            }
        })
    }

    public func exists(_ key: ObjectKey) async throws -> Bool { FileManager.default.fileExists(atPath: url(key).path) }

    public func delete(_ key: ObjectKey) async throws {
        guard FileManager.default.fileExists(atPath: url(key).path) else { return }
        try FileManager.default.removeItem(at: url(key))
    }
}

/// Besitzer eines Dateideskriptors: `close()` ist idempotent, `deinit` schließt als Rückfall.
private final class DescriptorHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32
    init(_ fd: Int32) { value = fd }
    var fd: Int32 { lock.withLock { value } }
    var isOpen: Bool { lock.withLock { value >= 0 } }
    func close() {
        lock.withLock {
            if value >= 0 { _ = Foundation.close(value); value = -1 }
        }
    }
    deinit { close() }
}
