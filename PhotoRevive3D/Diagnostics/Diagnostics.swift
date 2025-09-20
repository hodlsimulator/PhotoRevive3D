//
//  Diagnostics.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  Unified logging to OSLog and a rolling on-device log file.
//  Includes a "Share Logs" helper, crash-marker handling, MetricKit helpers,
//  and convenience accessors used by DiagnosticsView/MetricsSubscriber.
//  Works in Release. Actor-safe.
//

import Foundation
import OSLog
import UIKit

// MARK: - File logger actor (serialises file writes; actor-safe)

private actor LogSink {
    static let shared = LogSink()

    private let fm = FileManager.default
    private let logDir: URL
    private let logURL: URL
    private let maxBytes: Int = 2 * 1024 * 1024 // 2 MB rollover
    private let df: DateFormatter

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.logDir = dir
        self.logURL = dir.appendingPathComponent("app.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.df = formatter

        // Ensure file exists
        if !fm.fileExists(atPath: logURL.path) {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    private func timestamp() -> String {
        df.string(from: Date())
    }

    private func ensureExists() {
        if !fm.fileExists(atPath: logURL.path) {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    private func rollIfNeeded() {
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes else { return }

        let bak = logURL.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: logURL, to: bak)
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    func write(level: Diagnostics.Level, message: String, category: String) {
        ensureExists()
        let line = "\(timestamp()) [\(level.rawValue)] [\(category)] \(message)\n"

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                try? line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }

        rollIfNeeded()
    }

    func tail(maxBytes: Int) -> String {
        ensureExists()
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return "(no log file yet)" }
        defer { try? h.close() }

        let size: UInt64 = (try? h.seekToEnd()) ?? 0
        let cap = max(0, maxBytes) // guard negatives
        let off: UInt64
        if size > UInt64(cap) {
            off = size - UInt64(cap) // safe: only subtract when size > cap
        } else {
            off = 0
        }

        try? h.seek(toOffset: off)
        let data = (try? h.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? "(unreadable log)"
    }

    func logFileURL() -> URL {
        ensureExists()
        return logURL
    }

    func diagnosticsDirURL() -> URL {
        return logDir
    }
}

// MARK: - Public API

enum Diagnostics {

    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    // Crash marker -------------------------------------------------------------

    /// Call once at app start (see App.init()).
    @MainActor
    static func bootstrap() {
        // Determine crash marker from last run
        let marker = crashMarkerURL()
        let crashed = FileManager.default.fileExists(atPath: marker.path)

        // Persist for this launch (readable anywhere without actor hops)
        UserDefaults.standard.set(crashed, forKey: "Diagnostics.didCrashLastLaunch")

        // Place a marker for *this* run immediately
        try? "running".write(to: marker, atomically: true, encoding: .utf8)

        // IMPORTANT: Do NOT start MetricKit at launch; start on-demand from a diagnostics screen if desired.
        log(.info, "Diagnostics bootstrap: didCrashLastLaunch=\(crashed ? "YES":"NO")", category: "diagnostics")
    }

    /// Remove the crash marker to indicate a clean exit/background transition.
    @MainActor
    static func markCleanExit() {
        let marker = crashMarkerURL()
        try? FileManager.default.removeItem(at: marker)
        log(.info, "Marked clean exit (removed crash marker)", category: "diagnostics")
    }

    /// True if the previous launch did not remove its marker (i.e., crashed/killed).
    nonisolated
    static var didCrashLastLaunch: Bool {
        UserDefaults.standard.bool(forKey: "Diagnostics.didCrashLastLaunch")
    }

    // Logging -----------------------------------------------------------------

    /// Thread-safe logging; callable from any context (background or main).
    nonisolated
    static func log(_ level: Level, _ message: String, category: String = "app") {
        // OSLog (immediate)
        let logger = Logger(subsystem: "PhotoRevive3D", category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info:  logger.info("\(message, privacy: .public)")
        case .warn:  logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        // File (async via actor)
        Task.detached(priority: .utility) {
            await LogSink.shared.write(level: level, message: message, category: category)
        }
    }

    /// Lightweight memory/thermal note; callable from any context.
    nonisolated
    static func logMemory(_ note: String = "") {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair:    thermal = "fair"
        case .serious: thermal = "serious"
        case .critical:thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let msg = "[mem] \(note) thermal=\(thermal) uptime=\(String(format: "%.0fs", ProcessInfo.processInfo.systemUptime))"
        log(.info, msg, category: "mem")
    }

    // Share/report ------------------------------------------------------------

    /// Builds a short report + returns `[report.txt, app.log]` for sharing.
    @MainActor
    static func collectShareURLs() async -> [URL] {
        // Build report header on main (safe to touch UIKit here)
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PhotoRevive3D"
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var lines = [String]()
        lines.append("=== PhotoRevive3D Diagnostics Report ===")
        lines.append("Generated: \(timestamp)")
        lines.append("App: \(name) \(ver) (\(build))")
        lines.append("Bundle: \(bundle.bundleIdentifier ?? "?")")
        lines.append(deviceSummary)
        lines.append("Last run crashed: \(didCrashLastLaunch ? "YES" : "NO")")
        lines.append("")

        // Tail of file via actor
        let tailStr = await LogSink.shared.tail(maxBytes: 200_000)
        lines.append("=== Log Tail (200000 bytes max) ===")
        lines.append(tailStr)
        lines.append("=== End ===")

        // Write report
        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoRevive3D-report-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: reportURL, options: .atomic)
        } catch {
            log(.error, "Failed to write report: \(error)", category: "diagnostics")
        }

        // Return report + current log file
        let logURL = await LogSink.shared.logFileURL()
        return [reportURL, logURL]
    }

    // Convenience used by DiagnosticsView ------------------------------------

    /// Diagnostics directory URL (for MetricKit files, etc.)
    nonisolated
    static var diagnosticsDir: URL {
        // Mirror LogSink’s directory without crossing the actor.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Tail of the rolling log (defaults to 64 KB). Synchronous helper for UI.
    /// NOTE: Avoids overflow by guarding subtraction.
    nonisolated
    static func tail(maxBytes: Int = 64 * 1024) -> String {
        let log = diagnosticsDir.appendingPathComponent("app.log")
        guard let h = try? FileHandle(forReadingFrom: log) else { return "(no log file yet)" }
        defer { try? h.close() }

        let size: UInt64 = (try? h.seekToEnd()) ?? 0
        let cap = max(0, maxBytes)
        let off: UInt64 = (size > UInt64(cap)) ? (size - UInt64(cap)) : 0

        try? h.seek(toOffset: off)
        let data = (try? h.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? "(unreadable log)"
    }

    /// Delete app.log, backup log, MetricKit JSON payloads, and the crash marker.
    nonisolated
    static func clearAll() async {
        let fm = FileManager.default
        let dir = diagnosticsDir

        // Logs
        let log = dir.appendingPathComponent("app.log")
        let bak = dir.appendingPathComponent("app.1.log")
        try? fm.removeItem(at: log)
        try? fm.removeItem(at: bak)
        try? "".write(to: log, atomically: true, encoding: .utf8)

        // MetricKit JSON
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension.lowercased() == "json" {
                try? fm.removeItem(at: url)
            }
        }

        // Crash marker
        try? fm.removeItem(at: crashMarkerURL())

        // Note in the fresh log
        await LogSink.shared.write(level: .info, message: "Diagnostics cleared", category: "diagnostics")
    }

    /// Human-readable device summary (used in the Diagnostics screen/report).
    @MainActor
    static var deviceSummary: String {
        let d = UIDevice.current
        return "Device: \(d.model) (\(d.systemName) \(d.systemVersion))"
    }

    /// ISO-style timestamp string (used by DiagnosticsView).
    nonisolated
    static var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Latest MetricKit diagnostic JSON (if any), as a String.
    nonisolated
    static var lastCrashJSON: String? {
        let dir = diagnosticsDir
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        // Prefer MXDiag*.json; fall back to any MX*.json
        let candidates = files.filter { $0.lastPathComponent.hasPrefix("MXDiag") && $0.pathExtension.lowercased() == "json" }
        let pool = candidates.isEmpty ? files.filter { $0.lastPathComponent.hasPrefix("MX") && $0.pathExtension.lowercased() == "json" } : candidates
        guard !pool.isEmpty else { return nil }

        let latest = pool.max(by: { (a, b) -> Bool in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return da < db
        })!

        return try? String(contentsOf: latest, encoding: .utf8)
    }

    /// Very small summary derived from the latest MX diagnostic JSON.
    nonisolated
    static var lastCrashSummary: String? {
        guard let json = lastCrashJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // MXDiagnosticPayload JSON typically has "crashDiagnostics": [ { ... } ]
        if let arr = obj["crashDiagnostics"] as? [[String: Any]],
           let first = arr.first {
            let signal = (first["signal"] as? String) ?? ""
            let exceptionType = (first["exceptionType"] as? NSNumber)?.stringValue ?? ""
            let termination = (first["terminationReason"] as? String) ?? ""
            var topSymbol: String = ""

            if let tree = first["callStackTree"] as? [String: Any],
               let stacks = tree["callStacks"] as? [[String: Any]],
               let firstStack = stacks.first,
               let frames = firstStack["frames"] as? [[String: Any]],
               let top = frames.first {
                topSymbol = (top["symbol"] as? String)
                    ?? (top["binaryName"] as? String)
                    ?? ""
            }

            var parts: [String] = []
            if !signal.isEmpty { parts.append("signal \(signal)") }
            if !exceptionType.isEmpty { parts.append("exceptionType \(exceptionType)") }
            if !termination.isEmpty { parts.append(termination) }
            if !topSymbol.isEmpty { parts.append("top: \(topSymbol)") }

            return parts.isEmpty ? "Crash payload present" : parts.joined(separator: " — ")
        }

        // Some payloads may have "hangDiagnostics" or others; indicate presence.
        if obj["hangDiagnostics"] != nil { return "Hang payload present" }
        if obj["cpuExceptionDiagnostics"] != nil { return "CPU exception payload present" }
        return nil
    }

    // MARK: - Internals

    nonisolated
    private static func crashMarkerURL() -> URL {
        diagnosticsDir.appendingPathComponent("crash.marker")
    }
}
