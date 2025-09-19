//
//  Diagnostics.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
import os
import UIKit
import Darwin // for mach task_info()

enum Diagnostics {
    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    // Actor that owns the rolling log file.
    private static let store = LogStore()

    // Memory sampler timer
    private static var memTimer: DispatchSourceTimer?

    // MARK: - Bootstrap / lifecycle

    static func bootstrap() {
        markLaunch()
        MetricsSubscriber.shared.start()
        log(.info, "Diagnostics bootstrap complete")
    }

    static func markLaunch() {
        let url = markerURL()
        try? "running".data(using: .utf8)?.write(to: url, options: .atomic)
    }

    static func markCleanExit() {
        try? FileManager.default.removeItem(at: markerURL())
    }

    static var didCrashLastLaunch: Bool {
        FileManager.default.fileExists(atPath: markerURL().path)
    }

    // MARK: - Logging

    /// `nonisolated` so it can be called from background queues (e.g. MetricKit).
    nonisolated static func log(
        _ level: Level = .info,
        _ message: String,
        category: String = "app",
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let logger = Logger(subsystem: subsystem(), category: category)
        switch level {
        case .debug: logger.debug("\(category): \(message, privacy: .public)")
        case .info:  logger.log("\(category): \(message, privacy: .public)")
        case .warn:  logger.warning("\(category): \(message, privacy: .public)")
        case .error: logger.error("\(category): \(message, privacy: .public)")
        }

        let ts = timestamp()
        let lineStr = "[\(ts)] [\(level.rawValue)] [\(category)] \(message) (\(file):\(line) \(function))"
        Task.detached(priority: .utility) { await store.append(lineStr) }
    }

    static func tail(_ maxBytes: Int = 64 * 1024) async -> String {
        await store.tail(maxBytes)
    }

    // MARK: - Memory sampler

    /// Log one memory sample immediately. Marked `nonisolated` so it’s safe from any thread.
    nonisolated static func logMemory(_ label: String = "") {
        let mb = footprintMB()
        if mb >= 0 {
            log(.info, "footprint=\(String(format: "%.1f", mb)) MB \(label)", category: "mem")
        } else {
            log(.warn, "footprint=<unavailable> \(label)", category: "mem")
        }
    }

    /// Start logging memory footprint every second.
    static func startMemorySampler(tag: String = "") {
        if memTimer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(1))
        t.setEventHandler {
            let mb = footprintMB()
            if mb >= 0 {
                log(.info, "footprint=\(String(format: "%.1f", mb)) MB \(tag)", category: "mem")
            }
        }
        memTimer = t
        t.resume()
        log(.info, "Memory sampler STARTED \(tag)", category: "mem")
    }

    /// Stop the periodic memory sampler.
    static func stopMemorySampler() {
        memTimer?.cancel()
        memTimer = nil
        log(.info, "Memory sampler STOPPED", category: "mem")
    }

    /// Returns current process physical footprint in MB (or -1 on failure).
    nonisolated private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return -1 }
        let bytes = UInt64(info.phys_footprint)
        return Double(bytes) / 1_048_576.0
    }

    // MARK: - Clear / purge

    /// Clears the rolling logs (current + backup), removes saved MetricKit payloads, and clears the crash marker.
    static func clearAll() async {
        await store.clear()

        let fm = FileManager.default
        let dir = diagnosticsDir()

        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in files {
                let name = url.lastPathComponent
                if (name.hasPrefix("MX") && url.pathExtension == "json") || name == "RUNNING.marker" {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Report / share

    static func makeTextReport() async throws -> URL {
        let summary = await MainActor.run { deviceSummary() }

        let header = """
        ==== PhotoRevive3D Diagnostics ====
        Time: \(timestamp())
        \(summary)
        Last run crashed: \(didCrashLastLaunch ? "YES" : "NO")
        ===================================

        --- Recent Log (last 64KB) ---
        """

        var body = header
        body += await tail(64 * 1024)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Diagnostics-\(Int(Date().timeIntervalSince1970)).txt")

        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func collectShareURLs() async -> [URL] {
        var urls: [URL] = []
        if let rep = try? await makeTextReport() {
            urls.append(rep)
        }
        urls.append(contentsOf: MetricsSubscriber.shared.savedPayloads())
        return urls
    }

    // MARK: - Crash JSON helpers

    /// Raw JSON for the most recent saved MX diagnostic.
    static func lastCrashJSON() -> String? {
        let dir = diagnosticsDir()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let candidates = files.filter { $0.lastPathComponent.hasPrefix("MXDiag-") && $0.pathExtension == "json" }
        guard let latest = candidates.max(by: { (a, b) -> Bool in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }) else {
            return nil
        }
        return try? String(contentsOf: latest, encoding: .utf8)
    }

    /// Very small summary parsed from the latest crash JSON (termination reason, signal/exception, footprint).
    static func lastCrashSummary() -> String? {
        guard let text = lastCrashJSON(),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Pick first available diagnostic bucket
        let buckets = ["crashDiagnostics", "cpuExceptionDiagnostics", "hangDiagnostics"]
        var diag: [String: Any]? = nil
        for key in buckets {
            if let arr = root[key] as? [[String: Any]], let first = arr.first {
                diag = first
                break
            }
        }
        guard let diag else { return "No crash diagnostics array found." }

        var lines: [String] = []

        // Timestamp (from top level if present)
        if let ts = root["timeStampEnd"] as? String {
            lines.append("time=\(ts)")
        }

        // Meta fields (where signal/exception live in your sample)
        if let meta = diag["diagnosticMetaData"] as? [String: Any] {
            let sig = intFrom(meta["signal"])
            let exc = intFrom(meta["exceptionType"])
            let excCode = intFrom(meta["exceptionCode"])

            var parts: [String] = []
            if let s = sig { parts.append("signal=\(s) (\(signalName(s)))") }
            if let e = exc { parts.append("exceptionType=\(e) (\(machExceptionName(e)))") }
            if let c = excCode { parts.append("code=\(c)") }
            if !parts.isEmpty { lines.append(parts.joined(separator: "  ")) }

            var env: [String] = []
            if let bid = meta["bundleIdentifier"] as? String { env.append("bundle=\(bid)") }
            if let v = meta["appVersion"] as? String, let b = meta["appBuildVersion"] as? String {
                env.append("app=\(v) (\(b))")
            }
            if let os = meta["osVersion"] as? String { env.append("os=\(os)") }
            if let device = meta["deviceType"] as? String { env.append("device=\(device)") }
            if let pidAny = meta["pid"] { env.append("pid=\(pidAny)") }
            if !env.isEmpty { lines.append(env.joined(separator: "  ")) }
        }

        // Some payloads include this at top-level
        if let term = diag["terminationReason"] {
            lines.append("terminationReason=\(term)")
        }

        // Extract a "top frame" (prefer our app) from callStackTree
        if let tree = diag["callStackTree"] as? [String: Any],
           let stacks = tree["callStacks"] as? [[String: Any]] {
            // Prefer the attributed (crashing) thread if present
            let chosen = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
            if let frames = chosen?["callStackRootFrames"] as? [[String: Any]],
               let (name, off) = firstUsefulFrame(from: frames, preferBinary: "PhotoRevive3D") {
                let hex = String(off, radix: 16, uppercase: true)
                lines.append("top=\(name) +0x\(hex)")
            }
        }

        return lines.isEmpty ? "Crash diagnostic present but no standard fields." : lines.joined(separator: "\n")
    }

    // MARK: - Helpers (place inside Diagnostics)

    private static func intFrom(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
    }

    private static func firstUsefulFrame(from frames: [[String: Any]], preferBinary: String) -> (name: String, offset: Int)? {
        // Breadth-first search through root frames + subFrames
        var queue: [[String: Any]] = frames
        var fallback: (String, Int)? = nil

        while !queue.isEmpty {
            let f = queue.removeFirst()
            let name = f["binaryName"] as? String
            let off = intFrom(f["offsetIntoBinaryTextSegment"])
            if let subs = f["subFrames"] as? [[String: Any]] {
                queue.append(contentsOf: subs)
            }
            if let name, let off {
                if name == preferBinary { return (name, off) }
                if fallback == nil { fallback = (name, off) }
            }
        }
        return fallback
    }

    private static func signalName(_ s: Int) -> String {
        switch s {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 3: return "SIGQUIT"
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 7: return "SIGEMT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 12: return "SIGSYS"
        case 13: return "SIGPIPE"
        case 14: return "SIGALRM"
        case 15: return "SIGTERM"
        default: return "SIG\(s)"
        }
    }

    private static func machExceptionName(_ e: Int) -> String {
        switch e {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 7: return "EXC_SYSCALL"
        case 8: return "EXC_MACH_SYSCALL"
        case 9: return "EXC_RPC_ALERT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        case 13: return "EXC_CORPSE_NOTIFY"
        default: return "EXC_\(e)"
        }
    }

    // MARK: - Paths / helpers

    private static func markerURL() -> URL {
        diagnosticsDir().appendingPathComponent("RUNNING.marker")
    }

    /// Pure Foundation; safe from any context.
    nonisolated static func diagnosticsDir() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Subsystem for os.Logger; keep it callable from any context.
    nonisolated static func subsystem() -> String {
        Bundle.main.bundleIdentifier ?? "PhotoRevive3D"
    }

    @MainActor static func deviceSummary() -> String {
        let b = Bundle.main
        let v = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let d = UIDevice.current
        return "App \(v) (\(build)) — iOS \(d.systemVersion) — \(d.model)"
    }

    nonisolated static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

// MARK: - Actor: rolling file store

actor LogStore {
    private let fm = FileManager.default
    private let fileURL: URL
    private let backupURL: URL
    private let maxBytes = 512 * 1024

    init() {
        let dir = Diagnostics.diagnosticsDir()
        self.fileURL = dir.appendingPathComponent("app.log")
        self.backupURL = dir.appendingPathComponent("app.1.log")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch { /* ignore */ }
        }
        rotateIfNeeded()
    }

    func tail(_ maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let off = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: off)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func clear() {
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: fileURL)
        fm.createFile(atPath: fileURL.path, contents: nil)
    }

    private func rotateIfNeeded() {
        guard
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
            let size = (attrs[.size] as? NSNumber)?.intValue
        else { return }

        if size > maxBytes {
            try? fm.removeItem(at: backupURL)
            try? fm.moveItem(at: fileURL, to: backupURL)
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
    }
}
