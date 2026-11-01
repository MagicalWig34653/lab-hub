import XCTVapor
import Fluent
import SQLKit
import Crypto
import NIOCore
@testable import HubKit

// MARK: - Helpers (synthetic data only)

func sha256Hex(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

func streamOf(_ bytes: [UInt8], chunk: Int = 4096) -> ByteStream {
    let box = UnsafeSendableBox(0)
    return ByteStream(unfolding: {
        let i = box.value
        guard i < bytes.count else { return nil }
        let j = min(i + chunk, bytes.count); box.value = j
        return ByteBuffer(bytes: bytes[i..<j])
    })
}

func collect(_ s: ByteStream) async throws -> [UInt8] {
    var out: [UInt8] = []
    for try await b in s { out.append(contentsOf: b.readableBytesView) }
    return out
}

/// Lazily generated deterministic stream of `mib` MiB; never materialised.
func syntheticStream(mib: Int) -> ByteStream {
    let produced = UnsafeSendableBox(0)
    var block = [UInt8](repeating: 0, count: 1 << 20)
    for i in 0..<block.count { block[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
    let frozen = block
    return ByteStream(unfolding: {
        guard produced.value < mib else { return nil }
        var b = frozen
        let n = produced.value; produced.value += 1
        b[0] = UInt8(truncatingIfNeeded: n); b[1] = UInt8(truncatingIfNeeded: n >> 8)
        return ByteBuffer(bytes: b)
    })
}

func peakRSSBytes() -> Int {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    #if os(Linux)
    return Int(u.ru_maxrss) * 1024
    #else
    return Int(u.ru_maxrss)
    #endif
}

/// Contract run against one backend; `physicalCount` counts physically stored objects of a tenant.
struct ObjectStoreContract {
    let store: any ObjectStore
    let physicalCount: @Sendable (UUID) async throws -> Int
    var streamMiB = Int(ProcessInfo.processInfo.environment["LH_TEST_STREAM_MIB"] ?? "") ?? 1024

    // AK-D1-1
    func putGetExistsDelete() async throws {
        let t = UUID(), data = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        let h = sha256Hex(data)
        let stored = try await store.put(tenant: t, stream: streamOf(data), expectedSHA256: h)
        XCTAssertEqual(stored.key.sha256, h); XCTAssertEqual(stored.size, 10_000); XCTAssertFalse(stored.deduplicated)
        let exists1 = try await store.exists(stored.key); XCTAssertTrue(exists1)
        let back = try await collect(try await store.get(stored.key)); XCTAssertEqual(back, data)
        try await store.delete(stored.key)
        let exists2 = try await store.exists(stored.key); XCTAssertFalse(exists2)
        try await store.delete(stored.key)   // idempotent
        do { _ = try await store.get(stored.key); XCTFail("expected notFound") } catch { XCTAssertEqual(error as? ObjectStoreError, .notFound) }
    }

    // AK-D1-1 (empty object, no expected hash given)
    func emptyObjectAndComputedHash() async throws {
        let s = try await store.put(tenant: UUID(), stream: streamOf([]), expectedSHA256: nil)
        XCTAssertEqual(s.size, 0); XCTAssertEqual(s.key.sha256, sha256Hex([]))
        let body = try await collect(try await store.get(s.key)); XCTAssertEqual(body, [])
    }

    // AK-D1-2
    func wrongHashFailsAndStoresNothing() async throws {
        let t = UUID(), data = Array("synthetic".utf8)
        let wrong = String(repeating: "0", count: 64)
        do { _ = try await store.put(tenant: t, stream: streamOf(data), expectedSHA256: wrong); XCTFail("expected hashMismatch") }
        catch { XCTAssertEqual(error as? ObjectStoreError, .hashMismatch) }
        do { _ = try await store.put(tenant: t, stream: streamOf(data), expectedSHA256: "xyz"); XCTFail("expected invalidHash") }
        catch { XCTAssertEqual(error as? ObjectStoreError, .invalidHash) }
        let count = try await physicalCount(t); XCTAssertEqual(count, 0)
        let ex = try await store.exists(try ObjectKey(tenantID: t, sha256: sha256Hex(data))); XCTAssertFalse(ex)
    }

    // AK-D1-3
    func dedup() async throws {
        let t = UUID(), data = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 / 7) }   // spans several chunks
        let a = try await store.put(tenant: t, stream: streamOf(data, chunk: 100_000), expectedSHA256: nil)
        let b = try await store.put(tenant: t, stream: streamOf(data, chunk: 333_333), expectedSHA256: sha256Hex(data))
        XCTAssertEqual(a.key, b.key); XCTAssertFalse(a.deduplicated); XCTAssertTrue(b.deduplicated)
        let c1 = try await physicalCount(t); XCTAssertEqual(c1, 1)
        let back = try await collect(try await store.get(a.key)); XCTAssertEqual(back, data)
        // other tenant: same bytes, separate object, not reachable via foreign key
        let t2 = UUID()
        let foreign = try ObjectKey(tenantID: t2, sha256: a.key.sha256)
        let exF = try await store.exists(foreign); XCTAssertFalse(exF)
        let o = try await store.put(tenant: t2, stream: streamOf(data), expectedSHA256: nil)
        XCTAssertFalse(o.deduplicated)
        try await store.delete(a.key)
        let stillThere = try await store.exists(o.key); XCTAssertTrue(stillThere)
    }

    // AK-D1-1 (stateless: concurrent identical puts, possibly from different instances) + AK-D1-3
    func concurrentIdenticalPuts(second: any ObjectStore) async throws {
        let t = UUID(), data = (0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        let h = sha256Hex(data)
        let s1 = store
        let results = try await withThrowingTaskGroup(of: StoredObject.self) { g -> [StoredObject] in
            for i in 0..<6 {
                let st: any ObjectStore = i.isMultiple(of: 2) ? s1 : second
                g.addTask { try await st.put(tenant: t, stream: streamOf(data, chunk: 50_000), expectedSHA256: h) }
            }
            var r: [StoredObject] = []; for try await x in g { r.append(x) }; return r
        }
        XCTAssertEqual(Set(results.map(\.key)).count, 1)
        let c = try await physicalCount(t); XCTAssertEqual(c, 1)
        let back = try await collect(try await second.get(results[0].key)); XCTAssertEqual(back, data)
    }

    // AK-D1-1 streaming
    func streamingLargeObjectBoundedMemory() async throws {
        let t = UUID()
        // expected hash from a first lazy pass
        var h = SHA256(); var total: Int64 = 0
        for try await b in syntheticStream(mib: streamMiB) { b.withUnsafeReadableBytes { h.update(bufferPointer: $0) }; total += Int64(b.readableBytes) }
        let expected = h.finalize().map { String(format: "%02x", $0) }.joined()
        let before = peakRSSBytes()
        let stored = try await store.put(tenant: t, stream: syntheticStream(mib: streamMiB), expectedSHA256: expected)
        XCTAssertEqual(stored.size, total)
        var rh = SHA256(); var read: Int64 = 0
        for try await b in try await store.get(stored.key) { b.withUnsafeReadableBytes { rh.update(bufferPointer: $0) }; read += Int64(b.readableBytes) }
        XCTAssertEqual(read, total)
        XCTAssertEqual(rh.finalize().map { String(format: "%02x", $0) }.joined(), expected)
        let growth = peakRSSBytes() - before
        XCTAssertLessThan(growth, 256 << 20, "peak memory grew by \(growth >> 20) MiB for \(streamMiB) MiB object")
        try await store.delete(stored.key)
    }
}

// MARK: - Filesystem

final class FilesystemObjectStoreTests: XCTestCase {
    var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-os-\(UUID().uuidString)")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func contract() -> ObjectStoreContract {
        let root = self.root!
        return ObjectStoreContract(store: FilesystemObjectStore(root: root), physicalCount: { tenant in
            let dir = root.appendingPathComponent(tenant.uuidString.lowercased())
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
            return e.allObjects.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
        })
    }

    func testAKD1_1_putGetExistsDelete() async throws { try await contract().putGetExistsDelete() }
    func testAKD1_1_emptyObject() async throws { try await contract().emptyObjectAndComputedHash() }
    func testAKD1_2_wrongHashFails() async throws {
        try await contract().wrongHashFailsAndStoresNothing()
        // no staging leftovers
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path)) ?? []
        XCTAssertEqual(left, [])
    }
    func testAKD1_3_dedup() async throws { try await contract().dedup() }
    func testAKD1_1_concurrentTwoInstances() async throws {
        try await contract().concurrentIdenticalPuts(second: FilesystemObjectStore(root: root))
    }
    func testAKD1_1_streaming1GiBBoundedMemory() async throws { try await contract().streamingLargeObjectBoundedMemory() }
}

// MARK: - Config (AK-D1-4)

final class ObjectStoreConfigTests: XCTestCase {
    func testAKD1_4_fsWithReplicasWarns() throws {
        let w = try ObjectStoreConfig(kind: .fs, fsPath: "/data/objects", replicas: 3).validate()
        XCTAssertEqual(w.count, 1); XCTAssertTrue(w[0].contains("3 Repliken"))
        XCTAssertEqual(try ObjectStoreConfig(kind: .fs, fsPath: "/data/objects", replicas: 1).validate(), [])
        XCTAssertEqual(try ObjectStoreConfig(kind: .db, replicas: 5).validate(), [])
    }

    func testAKD1_4_fromEnvironment() throws {
        let c = try ObjectStoreConfig.fromEnvironment(["OBJECT_STORE": "fs", "OBJECT_STORE_FS_PATH": "/data/o", "HUB_REPLICAS": "2"])
        XCTAssertEqual(c, ObjectStoreConfig(kind: .fs, fsPath: "/data/o", replicas: 2))
        XCTAssertFalse(try c.validate().isEmpty)
        XCTAssertEqual(try ObjectStoreConfig.fromEnvironment([:]).kind, .db)
    }

    func testAKD1_4_noContainerFilesystemDefault() {
        // fs needs an explicit absolute volume path (ADR 0003); relative or missing is rejected
        XCTAssertThrowsError(try ObjectStoreConfig(kind: .fs).validate())
        XCTAssertThrowsError(try ObjectStoreConfig(kind: .fs, fsPath: "relative/dir").validate())
        XCTAssertThrowsError(try ObjectStoreConfig.fromEnvironment(["OBJECT_STORE": "bogus"]))
        XCTAssertThrowsError(try ObjectStoreConfig.fromEnvironment(["HUB_REPLICAS": "0"]))
    }

    func testS3NotYetAvailable() {
        XCTAssertThrowsError(try ObjectStoreConfig(kind: .s3).validate())
    }
}

// MARK: - Postgres

final class PostgresObjectStoreTests: XCTestCase {
    var app: Application!
    var db: (any SQLDatabase)!

    override func setUp() async throws {
        let e = ProcessInfo.processInfo.environment
        let env = ["DB_HOST": e["TEST_DB_HOST"] ?? "127.0.0.1", "DB_PORT": e["TEST_DB_PORT"] ?? "15432",
                   "DB_NAME": e["TEST_DB_NAME"] ?? "labhub", "DB_USER": e["TEST_DB_USER"] ?? "labhub",
                   "DB_PASSWORD": e["TEST_DB_PASSWORD"] ?? "devtest-pw", "DB_TLS": "disable"]
        app = try await Application.make(.testing)
        try configure(app, environment: env)
        do { _ = try await (app.db(.psql) as! any SQLDatabase).raw("SELECT 1").all() }
        catch { try await app.asyncShutdown(); app = nil; throw XCTSkip("Keine Postgres-Datenbank erreichbar") }
        db = (app.db(.psql) as! any SQLDatabase)
        for t in ["object_chunks", "files", "jobs", "idempotency_keys", "counters", "schema_version", "_fluent_migrations"] {
            try await db.raw("DROP TABLE IF EXISTS \(unsafeRaw: t)").run()
        }
        try await migrateWithLock(app)
    }
    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    private func contract() -> ObjectStoreContract {
        let db = self.db!
        return ObjectStoreContract(store: PostgresObjectStore(db), physicalCount: { tenant in
            let rows = try await db.raw("SELECT count(DISTINCT sha256) AS n FROM object_chunks WHERE tenant_id = \(bind: tenant)").first()
            return Int(try rows!.decode(column: "n", as: Int64.self))
        })
    }

    func testAKD1_1_putGetExistsDelete() async throws { try await contract().putGetExistsDelete() }
    func testAKD1_1_emptyObject() async throws { try await contract().emptyObjectAndComputedHash() }
    func testAKD1_2_wrongHashFails() async throws { try await contract().wrongHashFailsAndStoresNothing() }
    func testAKD1_3_dedup() async throws { try await contract().dedup() }
    func testAKD1_1_concurrentTwoInstances() async throws {
        // second instance = second store object on the same database (separate pool access)
        try await contract().concurrentIdenticalPuts(second: PostgresObjectStore(db))
    }
    func testAKD1_1_streaming1GiBBoundedMemory() async throws { try await contract().streamingLargeObjectBoundedMemory() }

    func testFilesTableDedupAndMigrationRevert() async throws {
        let t = UUID(), store = PostgresObjectStore(db), files = FileRecordService(db)
        let a = try await store.put(tenant: t, stream: streamOf(Array("same".utf8)), expectedSHA256: nil)
        let b = try await store.put(tenant: t, stream: streamOf(Array("same".utf8)), expectedSHA256: nil)
        let id1 = try await files.register(a, backend: .db), id2 = try await files.register(b, backend: .db)
        XCTAssertEqual(id1, id2)
        let n = try await db.raw("SELECT count(*) AS n FROM files WHERE tenant_id = \(bind: t)").first()!.decode(column: "n", as: Int64.self)
        XCTAssertEqual(n, 1)
        var v = try await db.raw("SELECT version FROM schema_version").first()!.decode(column: "version", as: Int.self)
        XCTAssertEqual(v, 5)
        try await CreateFiles().revert(on: app.db(.psql))
        v = try await db.raw("SELECT version FROM schema_version").first()!.decode(column: "version", as: Int.self)
        XCTAssertEqual(v, 4)
        let gone = try await db.raw("SELECT to_regclass('files')::text AS t").first()!.decode(column: "t", as: String?.self)
        XCTAssertNil(gone)
        try await CreateFiles().prepare(on: app.db(.psql))   // re-apply works
    }
}
