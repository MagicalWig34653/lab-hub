import Foundation
import Crypto
import NIOCore

// WP-D5: Minimaler ZIP-Schreiber und -Leser für den Revisions-Export. Bewusst ohne Abhängigkeit (keine neue Lizenz): Methode „stored“ (unkomprimiert, die Dateien sind
// meist schon komprimierte PDFs/Bilder), UTF-8-Namen, Datenbeschreibung nach den Daten (Streaming ohne Vorabwissen der Prüfsumme), kein ZIP64
// (Grenzen: 4 GiB je Archiv/Eintrag, 65535 Einträge; darüber bricht der Export mit `export_too_large` ab). Ausgabe ist byte-deterministisch bei gleicher Eingabe und gleichem Zeitstempel.

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
}

struct ZIPTooLarge: Error {}

final class ZIPWriter {
    private struct Entry { let name: [UInt8]; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    private let dosTime: UInt16, dosDate: UInt16

    init(handle: FileHandle, timestamp: Date) {
        self.handle = handle
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        let year: Int = max((c.year ?? 1980) - 1980, 0)
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let date: Int = (year << 9) | (month << 5) | day
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        dosDate = UInt16(date)
        dosTime = UInt16(time)
    }

    private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    private func write(_ bytes: [UInt8]) throws { try handle.write(contentsOf: Data(bytes)); offset += UInt64(bytes.count) }

    /// Fügt einen Eintrag aus einem Datenstrom hinzu; liefert SHA-256 (Hex) und Größe der Eintragsdaten.
    @discardableResult
    func add(name: String, stream: ByteStream) async throws -> (sha256: String, size: Int64) {
        let nameBytes = Array(name.utf8)
        guard offset < 0xFFFF_FFFF, entries.count < 0xFFFF, nameBytes.count < 0xFFFF else { throw ZIPTooLarge() }
        let start = UInt32(offset)
        try write(u32(0x04034b50) + u16(20) + u16(0x0808) + u16(0) + u16(dosTime) + u16(dosDate) + u32(0) + u32(0) + u32(0) + u16(UInt16(nameBytes.count)) + u16(0) + nameBytes)
        var crc: UInt32 = 0, size: UInt64 = 0, sha = SHA256()
        for try await chunk in stream {
            chunk.withUnsafeReadableBytes { crc = CRC32.update(crc, $0); sha.update(bufferPointer: $0) }
            try handle.write(contentsOf: Data(buffer: chunk))
            size += UInt64(chunk.readableBytes); offset += UInt64(chunk.readableBytes)
            guard offset < 0xFFFF_FFFF else { throw ZIPTooLarge() }
        }
        try write(u32(0x08074b50) + u32(crc) + u32(UInt32(size)) + u32(UInt32(size)))
        entries.append(Entry(name: nameBytes, crc: crc, size: UInt32(size), offset: start))
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(), Int64(size))
    }

    @discardableResult
    func add(name: String, data: Data) async throws -> (sha256: String, size: Int64) {
        var buf = ByteBuffer(); buf.writeBytes(data)
        let once = UnsafeSendableBox<ByteBuffer?>(buf)
        return try await add(name: name, stream: ByteStream(unfolding: { defer { once.value = nil }; return once.value }))
    }

    func finish() throws {
        let cdStart = offset
        for e in entries {
            try write(u32(0x02014b50) + u16(20) + u16(20) + u16(0x0808) + u16(0) + u16(dosTime) + u16(dosDate) + u32(e.crc) + u32(e.size) + u32(e.size)
                      + u16(UInt16(e.name.count)) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(e.offset) + e.name)
        }
        let cdSize = offset - cdStart
        guard cdStart < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else { throw ZIPTooLarge() }
        try write(u32(0x06054b50) + u16(0) + u16(0) + u16(UInt16(entries.count)) + u16(UInt16(entries.count)) + u32(UInt32(cdSize)) + u32(UInt32(cdStart)) + u16(0))
    }
}

/// Liest Archive im Format des `ZIPWriter` (Zentralverzeichnis, Methode stored). Für Prüfungen (Tests, Prüfwerkzeug); lädt das Archiv in den Speicher (gemappt).
enum ZIPReader {
    struct Item { let name: String; let data: Data; let crc: UInt32 }
    struct Malformed: Error {}

    static func read(_ zip: Data) throws -> [Item] {
        let bytes = [UInt8](zip)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard bytes.count >= 22 else { throw Malformed() }
        var eocd = bytes.count - 22
        while eocd >= 0, u32(eocd) != 0x06054b50 { eocd -= 1 }
        guard eocd >= 0 else { throw Malformed() }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [Item] = []
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50, u16(p + 10) == 0 else { throw Malformed() }
            let crc = u32(p + 16), size = u32(p + 24), nameLen = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLen <= bytes.count, local + 30 <= bytes.count else { throw Malformed() }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
            guard dataStart + size <= bytes.count else { throw Malformed() }
            out.append(Item(name: name, data: Data(bytes[dataStart..<(dataStart + size)]), crc: UInt32(crc)))
            p += 46 + nameLen + extra + comment
        }
        return out
    }
}
