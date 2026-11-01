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
        if FileManager.default.fileExists(atPath: target.path) {
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
        let box = UnsafeSendableBox(fd)
        return ByteStream(unfolding: {
            guard box.value >= 0 else { return nil }
            var buf = ByteBuffer()
            let n = try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: objectStoreChunkSize) { raw in
                let r = read(box.value, raw.baseAddress!, raw.count)
                if r < 0 { throw ObjectStoreError.io("read") }
                return r
            }
            if n == 0 { close(box.value); box.value = -1; return nil }
            return buf
        })
    }

    public func exists(_ key: ObjectKey) async throws -> Bool { FileManager.default.fileExists(atPath: url(key).path) }

    public func delete(_ key: ObjectKey) async throws {
        guard FileManager.default.fileExists(atPath: url(key).path) else { return }
        try FileManager.default.removeItem(at: url(key))
    }
}
