//
//  Diagnostics.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  iOS 26-ready diagnostics with:
//  • Rolling text log (app.log) + JSON lines log (app.jsonl)
//  • MetricKit JSON payload capture (MX*.json / MXDiag*.json)
//  • Safe concurrency (no 'sending' warnings), no UIScreen.main deprecations
//  • Rich summary snapshot included in logs (hardware, locale, power, storage)
//  • Share bundle: [report.txt, app.log, app.jsonl, any MX*.json]
//
//  Works in Release. Keep all APIs here stable – DiagnosticsView/MetricsSubscriber depend on them.
//

import Foundation
import OSLog
import UIKit

// MARK: - Internal file logger (serialised by actor)

private actor LogSink {
    static let shared = LogSink()

    private let fm = FileManager.default
    private let dir: URL
    private let textURL: URL
    private let jsonURL: URL
    private let maxBytes: Int = 2 * 1024 * 1024 // 2 MB rollover
    private let textDF: DateFormatter
    private let isoDF: ISO8601DateFormatter

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Diagnostics", isDirectory: true)
        if !fm.fileExists(atPath: d.path) {
            do { try fm.createDirectory(at: d, withIntermediateDirectories: true) } catch {}
        }
        dir = d
        textURL = d.appendingPathComponent("app.log")
        jsonURL = d.appendingPathComponent("app.jsonl")

        let t = DateFormatter()
        t.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        textDF = t

        let i = ISO8601DateFormatter()
        i.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoDF = i

        // Ensure files exist
        if !fm.fileExists(atPath: textURL.path) {
            do { try Data().write(to: textURL) } catch {}
        }
        if !fm.fileExists(atPath: jsonURL.path) {
            do { try Data().write(to: jsonURL) } catch {}
        }
    }

    // MARK: file helpers

    private func append(_ data: Data, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            do {
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } catch {
                // Fallback to overwrite if seek/write failed
                do { try data.write(to: url, options: .atomic) } catch {}
            }
        } else {
            do { try data.write(to: url, options: .atomic) } catch {}
        }
    }

    private func rollIfNeeded(_ url: URL) {
        guard
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue > maxBytes
        else { return }
        let bak = url.deletingPathExtension().appendingPathExtension("1.\(url.pathExtension)")
        do { try fm.removeItem(at: bak) } catch {}
        do {
            try fm.copyItem(at: url, to: bak)
            try Data().write(to: url) // truncate
        } catch {}
    }

    func write(level: Diagnostics.Level, message: String, category: String, context: [String: String]?) {
        // Human-readable
        let line = "\(textDF.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)\n"
        if let d = line.data(using: .utf8) { append(d, to: textURL) }
        rollIfNeeded(textURL)

        // JSON line
        var obj: [String: Any] = [
            "ts": isoDF.string(from: Date()),
            "level": level.rawValue,
            "category": category,
            "message": message
        ]
        if let context {
            for (k, v) in context { obj[k] = v } // flattened string context (Sendable-friendly)
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let out = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) {
            append(out, to: jsonURL)
        }
        rollIfNeeded(jsonURL)
    }

    func tailText(maxBytes: Int) -> String {
        tail(of: textURL, maxBytes: maxBytes) ?? "(no log file yet)"
    }
    func tailJSON(maxBytes: Int) -> String {
        tail(of: jsonURL, maxBytes: maxBytes) ?? "(no JSON log yet)"
    }
    private func tail(of url: URL, maxBytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size: UInt64 = (try? h.seekToEnd()) ?? 0
        let cap = max(0, maxBytes)
        let off: UInt64 = size > UInt64(cap) ? (size - UInt64(cap)) : 0
        try? h.seek(toOffset: off)
        let data = (try? h.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    func fileURL_text() -> URL { textURL }
    func fileURL_json() -> URL { jsonURL }
    func dirURL() -> URL { dir }

    func clearAll() {
        do { try fm.removeItem(at: textURL) } catch {}
        do { try fm.removeItem(at: jsonURL) } catch {}
        do { try Data().write(to: textURL) } catch {}
        do { try Data().write(to: jsonURL) } catch {}

        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension.lowercased() == "json" {
                // keep app.jsonl; remove only MX*.json
                let name = u.lastPathComponent
                if name.hasPrefix("MX") || name.hasPrefix("MXDiag") {
                    do { try fm.removeItem(at: u) } catch {}
                }
            }
        }
    }
}

// MARK: - Public Diagnostics API

enum Diagnostics {
    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    // Bootstrapping ----------------------------------------------------------

    /// Call once at app start. Writes crash marker and logs a summary snapshot.
    @MainActor
    static func bootstrap() {
        let marker = crashMarkerURL()
        let crashed = FileManager.default.fileExists(atPath: marker.path)
        UserDefaults.standard.set(crashed, forKey: "Diagnostics.didCrashLastLaunch")
        do { try "running".write(to: marker, atomically: true, encoding: .utf8) } catch {}

        log(.info, "Diagnostics bootstrap: didCrashLastLaunch=\(crashed ? "YES":"NO")", category: "diagnostics")
        logSummarySnapshot(trigger: "bootstrap")
    }

    /// Remove crash marker at clean exit (e.g. scene to background).
    @MainActor
    static func markCleanExit() {
        do { try FileManager.default.removeItem(at: crashMarkerURL()) } catch {}
        log(.info, "Marked clean exit (removed crash marker)", category: "diagnostics")
    }

    nonisolated static var didCrashLastLaunch: Bool {
        UserDefaults.standard.bool(forKey: "Diagnostics.didCrashLastLaunch")
    }

    // Logging ---------------------------------------------------------------

    /// Thread-safe logging to OSLog + text file + JSONL. String-only context to avoid Sendable warnings.
    nonisolated static func log(_ level: Level,
                                _ message: String,
                                category: String = "app",
                                context: [String: Any]? = nil) {
        // OSLog
        let logger = Logger(subsystem: "PhotoRevive3D", category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info:  logger.info("\(message, privacy: .public)")
        case .warn:  logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        // Flatten context to [String:String] (Sendable-friendly)
        var sctx: [String: String]? = nil
        if let context {
            var tmp: [String: String] = [:]
            for (k, v) in context { tmp[k] = String(describing: v) }
            sctx = tmp
        }

        // Write via actor (no 'detached' to quiet "sending" warnings)
        Task(priority: .utility) { @Sendable in
            await LogSink.shared.write(level: level, message: message, category: category, context: sctx)
        }
    }

    /// Quick helper to record memory/thermal snapshot.
    nonisolated static func logMemory(_ note: String = "") {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        log(.info, "thermal=\(thermal) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON":"OFF") \(note)",
            category: "mem",
            context: ["thermal": thermal, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled])
    }

    /// Writes a rich hardware/app summary into the JSON log (and a simple text line).
    @MainActor
    static func logSummarySnapshot(trigger: String) {
        let b = Bundle.main
        let name = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "PhotoRevive3D"
        let ver  = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (b.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let d = UIDevice.current

        // Screen metrics without UIScreen.main (iOS 26 deprecation)
        let screenInfo = currentScreenInfo()
        let tz = TimeZone.current.identifier
        let loc = Locale.current.identifier

        var ctx: [String: Any] = [
            "trigger"    : trigger,
            "appName"    : name,
            "appVersion" : ver,
            "appBuild"   : build,
            "bundleID"   : b.bundleIdentifier ?? "?",
            "deviceModel": d.model,
            "system"     : "\(d.systemName) \(d.systemVersion)",
            "locale"     : loc,
            "timezone"   : tz,
            "debug"      : _isDebugBuild(),
            "release"    : !_isDebugBuild(),
            "testFlight" : _isTestFlight()
        ]

        if let s = screenInfo {
            ctx["screenPx"] = ["w": s.pxWidth, "h": s.pxHeight, "scale": s.scale]
        }

        // Battery snapshot
        let was = d.isBatteryMonitoringEnabled
        d.isBatteryMonitoringEnabled = true
        ctx["battery"] = ["level": d.batteryLevel, "state": d.batteryState.rawValue]
        d.isBatteryMonitoringEnabled = was

        if let free = _bytesFree() { ctx["diskFreeBytes"] = free }

        log(.info, "Summary snapshot (\(trigger)) — Device: \(d.model) (\(d.systemName) \(d.systemVersion))",
            category: "diagnostics", context: ctx)
    }

    // Share/report ----------------------------------------------------------

    /// Returns shareable URLs: report.txt, app.log, app.jsonl, and any MetricKit JSON payloads.
    @MainActor
    static func collectShareURLs() async -> [URL] {
        // Ensure a fresh summary exists
        logSummarySnapshot(trigger: "share")

        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PhotoRevive3D"
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var lines = [String]()
        lines.append("=== PhotoRevive3D Diagnostics Report ===")
        lines.append("Generated: \(timestamp)")
        lines.append("App: \(name) \(ver) (\(build))")
        lines.append("Bundle: \(bundle.bundleIdentifier ?? "?")")
        lines.append("Device: \(UIDevice.current.model) (\(UIDevice.current.systemName) \(UIDevice.current.systemVersion))")
        lines.append("Last run crashed: \(didCrashLastLaunch ? "YES" : "NO")")
        lines.append("")

        let tailStr = await LogSink.shared.tailText(maxBytes: 200_000)
        lines.append("=== Log Tail (200000 bytes max) ===")
        lines.append(tailStr)
        lines.append("=== End ===")

        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoRevive3D-report-\(Int(Date().timeIntervalSince1970)).txt")
        do { try lines.joined(separator: "\n").data(using: .utf8)?.write(to: reportURL, options: .atomic) } catch {}

        // Attach text + JSON logs
        let textURL = await LogSink.shared.fileURL_text()
        let jsonURL = await LogSink.shared.fileURL_json()

        // Attach any MetricKit JSON payloads
        var extras: [URL] = []
        let dir = await LogSink.shared.dirURL()
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            extras = items.filter { $0.pathExtension.lowercased() == "json" && ($0.lastPathComponent.hasPrefix("MX") || $0.lastPathComponent.hasPrefix("MXDiag")) }
        }

        return [reportURL, textURL, jsonURL] + extras
    }

    // UI helpers ------------------------------------------------------------

    /// Async tails for UI (avoid referencing LogSink from other files)
    static func tailTextAsync(maxBytes: Int) async -> String {
        await LogSink.shared.tailText(maxBytes: maxBytes)
    }
    static func tailJSONAsync(maxBytes: Int) async -> String {
        await LogSink.shared.tailJSON(maxBytes: maxBytes)
    }

    nonisolated static var diagnosticsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {}
        }
        return dir
    }

    nonisolated static func clearAll() async {
        await LogSink.shared.clearAll()
        await LogSink.shared.write(level: .info, message: "Diagnostics cleared", category: "diagnostics", context: nil)
    }

    @MainActor
    static var deviceSummary: String {
        let d = UIDevice.current
        return "Device: \(d.model) (\(d.systemName) \(d.systemVersion))"
    }

    nonisolated static var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    // MetricKit JSON helpers

    nonisolated static var lastCrashJSON: String? {
        let dir = diagnosticsDir
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let candidates = files.filter { $0.lastPathComponent.hasPrefix("MXDiag") && $0.pathExtension.lowercased() == "json" }
        let pool = candidates.isEmpty ? files.filter { $0.lastPathComponent.hasPrefix("MX") && $0.pathExtension.lowercased() == "json" } : candidates
        guard !pool.isEmpty else { return nil }
        let latest = pool.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }!
        return try? String(contentsOf: latest, encoding: .utf8) // use encoding: to avoid iOS 18 deprecation
    }

    nonisolated static var lastCrashSummary: String? {
        guard let json = lastCrashJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let arr = obj["crashDiagnostics"] as? [[String: Any]], let first = arr.first {
            let signal = (first["signal"] as? String) ?? ""
            let exceptionType = (first["exceptionType"] as? NSNumber)?.stringValue ?? ""
            let termination = (first["terminationReason"] as? String) ?? ""
            var topSymbol = ""
            if
                let tree = first["callStackTree"] as? [String: Any],
                let stacks = tree["callStacks"] as? [[String: Any]],
                let firstStack = stacks.first,
                let frames = firstStack["frames"] as? [[String: Any]],
                let top = frames.first
            {
                topSymbol = (top["symbol"] as? String) ?? (top["binaryName"] as? String) ?? ""
            }
            var parts: [String] = []
            if !signal.isEmpty { parts.append("signal \(signal)") }
            if !exceptionType.isEmpty { parts.append("exceptionType \(exceptionType)") }
            if !termination.isEmpty { parts.append(termination) }
            if !topSymbol.isEmpty { parts.append("top: \(topSymbol)") }
            return parts.isEmpty ? "Crash payload present" : parts.joined(separator: " — ")
        }
        if obj["hangDiagnostics"] != nil { return "Hang payload present" }
        if obj["cpuExceptionDiagnostics"] != nil { return "CPU exception payload present" }
        return nil
    }

    // MARK: - Internals

    nonisolated private static func crashMarkerURL() -> URL {
        diagnosticsDir.appendingPathComponent("crash.marker")
    }

    private static func _bytesFree() -> Int64? {
        let u = diagnosticsDir
        if let vals = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let n = vals.volumeAvailableCapacityForImportantUsage { return n }
        return nil
    }

    @MainActor
    private static func currentScreenInfo() -> (scale: CGFloat, pxWidth: Int, pxHeight: Int)? {
        // Prefer the key window’s screen; fall back to first window scene’s screen
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let win = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            let s = win.screen
            let scale = s.scale
            let size = s.bounds.size
            return (scale, Int(size.width * scale), Int(size.height * scale))
        }
        if let s = scenes.first?.screen {
            let scale = s.scale
            let size = s.bounds.size
            return (scale, Int(size.width * scale), Int(size.height * scale))
        }
        return nil
    }

    private static func _isDebugBuild() -> Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func _isTestFlight() -> Bool {
        #if DEBUG
        false
        #else
        if let r = Bundle.main.appStoreReceiptURL?.lastPathComponent, r == "sandboxReceipt" { return true }
        return false
        #endif
    }
}
