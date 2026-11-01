import Foundation
import Crypto
import NIOCore

/// Pull-based byte stream (backpressure via `AsyncThrowingStream(unfolding:)`); chunks, never the whole object.
public typealias ByteStream = AsyncThrowingStream<ByteBuffer, any Error>

public enum ObjectStoreKind: String, Sendable { case fs, db, s3 }

/// Content-addressed key: `<tenant>/<sha256[0:2]>/<sha256>` (docs/ARCHITEKTUR.md 4.5).
public struct ObjectKey: Hashable, Sendable, CustomStringConvertible {
    public let tenantID: UUID
    public let sha256: String   // lowercase hex, 64 chars
    public init(tenantID: UUID, sha256: String) throws {
        guard ObjectKey.isValidHash(sha256) else { throw ObjectStoreError.invalidHash }
        self.tenantID = tenantID; self.sha256 = sha256
    }
    public var path: String { "\(tenantID.uuidString.lowercased())/\(sha256.prefix(2))/\(sha256)" }
    public var description: String { path }
    public static func isValidHash(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

public struct StoredObject: Sendable, Equatable {
    public let key: ObjectKey
    public let size: Int64
    /// true: identical bytes already existed, nothing was stored again.
    public let deduplicated: Bool
}

public enum ObjectStoreError: Error, Equatable, CustomStringConvertible {
    case hashMismatch, notFound, invalidHash, io(String)
    /// Stabile Fehlercodes; Meldungen deutsch, ohne Nutzdaten.
    public var description: String {
        switch self {
        case .hashMismatch: return "object_hash_mismatch: Prüfsumme stimmt nicht überein"
        case .notFound: return "object_not_found: Objekt nicht gefunden"
        case .invalidHash: return "object_invalid_hash: Ungültige Prüfsumme"
        case .io(let d): return "object_io: Speicherfehler (\(d))"
        }
    }
}

public protocol ObjectStore: Sendable {
    var kind: ObjectStoreKind { get }
    /// Streams `stream` into the store. If `expectedSHA256` is given and differs from the computed hash, throws
    /// `hashMismatch` and stores nothing. Identical bytes (same tenant) are stored once.
    func put(tenant: UUID, stream: ByteStream, expectedSHA256: String?) async throws -> StoredObject
    /// Throws `notFound`. The returned stream is lazy.
    func get(_ key: ObjectKey) async throws -> ByteStream
    func exists(_ key: ObjectKey) async throws -> Bool
    /// Hard delete, idempotent (only after the retention/deletion concept decided it).
    func delete(_ key: ObjectKey) async throws
}

/// Chunk size used by all backends for reading and writing.
let objectStoreChunkSize = 1 << 20

/// Incremental SHA-256 over a stream.
struct StreamHasher {
    private var hasher = SHA256()
    private(set) var size: Int64 = 0
    mutating func update(_ buffer: ByteBuffer) {
        buffer.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
        size += Int64(buffer.readableBytes)
    }
    mutating func finish() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}

/// Reference-boxed mutable state for `unfolding` closures (access is strictly sequential).
final class UnsafeSendableBox<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

func normalizedExpectedHash(_ h: String?) throws -> String? {
    guard let h else { return nil }
    let l = h.lowercased()
    guard ObjectKey.isValidHash(l) else { throw ObjectStoreError.invalidHash }
    return l
}
