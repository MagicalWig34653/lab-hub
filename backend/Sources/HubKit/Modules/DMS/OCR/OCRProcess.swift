import Foundation

// WP-O2: Fremdprozesse (pdfinfo, pdftotext, ocrmypdf) mit hartem Zeit- und Speicherlimit. Ghostscript und Tesseract laufen ausschließlich als
// eigene Prozesse (kein Linken, siehe docs/LIZENZEN.md). Ausgabe geht in Dateien im Arbeitsverzeichnis (tmpfs), nie in Pipes (kein Deadlock).

struct OCRProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum OCRProcessError: Error, Equatable {
    case launchFailed(String)
}

private final class RunningProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markFinished() {
        lock.lock(); finished = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
        }
    }

    /// Abbruch von außen: SIGKILL für die Prozessgruppe (Linux: `timeout(1)` legt eine eigene Gruppe an, Kinder bleiben darin), sonst nur für den Prozess.
    /// SIGTERM an `timeout` kam im Test nicht an (vererbte Signalmaske des Foundation-Threads), SIGKILL ist unabhängig davon.
    func kill() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, process.isRunning else { return }
        let pid = process.processIdentifier
        #if os(Linux)
        _ = Foundation.kill(-pid, SIGKILL)
        #endif
        _ = Foundation.kill(pid, SIGKILL)
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

enum OCRProcess {
    /// Startet `executable` (Suche über PATH). `memoryBytes`: Adressraumlimit (`ulimit -v`, nur Linux). `timeout`: Sekunden; danach wird die ganze Prozessgruppe beendet
    /// (Linux: `timeout(1)` mit TERM, nach 5 s KILL, Exit 124/137; Swift-Zeitgeber als Rückfall nach timeout + 10 s).
    static func run(_ executable: String, _ arguments: [String], workDir: URL, timeout: TimeInterval, memoryBytes: Int64? = nil,
                    environment: [String: String] = [:], maxCapture: Int = 4 << 20) async throws -> OCRProcessResult {
        let id = UUID().uuidString
        let outURL = workDir.appendingPathComponent(".out-\(id)"), errURL = workDir.appendingPathComponent(".err-\(id)")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil), FileManager.default.createFile(atPath: errURL.path, contents: nil)
        else { throw OCRProcessError.launchFailed("workdir") }
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
        let outHandle = try FileHandle(forWritingTo: outURL), errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? outHandle.close(); try? errHandle.close() }

        let running = RunningProcess()
        let p = running.process
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        var script = ""
        #if os(Linux)
        if let memoryBytes { script += "ulimit -v \(max(memoryBytes / 1024, 65536)) || exit 125; " }
        script += "exec timeout --signal=TERM --kill-after=5 \(timeout) \"$@\""
        #else
        script += "exec \"$@\""
        #endif
        p.arguments = ["-c", script, "sh", executable] + arguments
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        p.environment = env
        p.standardOutput = outHandle; p.standardError = errHandle; p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { _ in running.markFinished() }
        do { try p.run() } catch { throw OCRProcessError.launchFailed("\(error)") }

        let started = Date()
        let timedOut = TimeoutFlag()
        #if os(Linux)
        let backstop = timeout + 10
        #else
        let backstop = timeout
        #endif
        let timer = Task {
            try? await Task.sleep(for: .milliseconds(Int(backstop * 1000)))
            if !Task.isCancelled { timedOut.set(); running.kill() }
        }
        await withTaskCancellationHandler { await running.wait() } onCancel: { running.kill() }
        timer.cancel()
        #if os(Linux)
        let status = p.terminationStatus
        if status == 124 || (status == 137 && Date().timeIntervalSince(started) >= timeout) { timedOut.set() }
        #endif

        func read(_ url: URL) -> String {
            guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? h.close() }
            return String(decoding: (try? h.read(upToCount: maxCapture)) ?? Data(), as: UTF8.self)
        }
        return OCRProcessResult(exitCode: p.terminationStatus, stdout: read(outURL), stderr: read(errURL), timedOut: timedOut.value)
    }
}
