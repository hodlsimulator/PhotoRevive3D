//
//  Diagnostics.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  iOS 26-ready diagnostics with:
//  • Rolling text log (app.log) + JSON lines log (app.jsonl)
//  • MetricKit JSON payload capture (MX*.json / MXDiag*.json)
//  • Safe concurrency, no UIScreen.main deprecations
//  • Rich summary snapshot (hardware, locale, power, storage, store environment)
//  • Share bundle: [report.txt, app.log, app.jsonl, any MX*.json]
//

import Foundation
import OSLog
import UIKit
import StoreKit

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
            _ = try? fm.createDirectory(at: d, withIntermediateDirectories: true)
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

        if !fm.fileExists(atPath: textURL.path) { _ = try? Data().write(to: textURL) }
        if !fm.fileExists(atPath: jsonURL.path) { _ = try? Data().write(to: jsonURL) }
    }

    private func append(_ data: Data, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            do {
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } catch {
                _ = try? data.write(to: url, options: .atomic)
            }
        } else {
            _ = try? data.write(to: url, options: .atomic)
        }
    }

    private func rollIfNeeded(_ url: URL) {
        guard
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue > maxBytes
        else { return }

        let bak = url.deletingPathExtension().appendingPathExtension("1.\(url.pathExtension)")
        _ = try? fm.removeItem(at: bak)
        if (try? fm.copyItem(at: url, to: bak)) != nil {
            _ = try? Data().write(to: url) // truncate
        }
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
        if let context { for (k, v) in context { obj[k] = v } }

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
        _ = try? fm.removeItem(at: textURL)
        _ = try? fm.removeItem(at: jsonURL)
        _ = try? Data().write(to: textURL)
        _ = try? Data().write(to: jsonURL)

        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension.lowercased() == "json" {
                let name = u.lastPathComponent
                if name.hasPrefix("MX") || name.hasPrefix("MXDiag") {
                    _ = try? fm.removeItem(at: u)
                }
            }
        }
    }
}

// MARK: - Store environment cache (StoreKit 2)

private actor StoreEnvironmentCache {
    static let shared = StoreEnvironmentCache()
    private var cached: String?

    func get() async -> String {
        if let c = cached { return c }
        do {
            let result = try await AppTransaction.shared // VerificationResult<AppTransaction>
            let envString: String
            switch result {
            case .verified(let appTx):
                switch appTx.environment {
                case .production: envString = "production"
                case .sandbox:    envString = "sandbox"
                default:          envString = "unknown"
                }
            case .unverified:
                envString = "unknown"
            }
            cached = envString
            return envString
        } catch {
            cached = "unknown"
            return "unknown"
        }
    }
}

// MARK: - Public Diagnostics API

enum Diagnostics {
    enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    // Bootstrapping ----------------------------------------------------------

    /// Call once at app start. Writes crash marker and logs a summary snapshot.
    @MainActor
    static func bootstrap() {
        let marker = crashMarkerURL()
        let crashed = FileManager.default.fileExists(atPath: marker.path)
        UserDefaults.standard.set(crashed, forKey: "Diagnostics.didCrashLastLaunch")
        _ = try? "running".write(to: marker, atomically: true, encoding: .utf8)

        log(.info, "Diagnostics bootstrap: didCrashLastLaunch=\(crashed ? "YES":"NO")", category: "diagnostics")
        Task { await logSummarySnapshot(trigger: "bootstrap") }
    }

    /// Remove crash marker at clean exit (e.g. scene to background).
    @MainActor
    static func markCleanExit() {
        _ = try? FileManager.default.removeItem(at: crashMarkerURL())
        log(.info, "Marked clean exit (removed crash marker)", category: "diagnostics")
    }

    nonisolated static var didCrashLastLaunch: Bool {
        UserDefaults.standard.bool(forKey: "Diagnostics.didCrashLastLaunch")
    }
    
    // PhotoRevive3D/Diagnostics/Diagnostics.swift — inside `enum Diagnostics`

    nonisolated static func clearAll() async {
        await LogSink.shared.clearAll()
        await LogSink.shared.write(
            level: .info,
            message: "Diagnostics cleared",
            category: "diagnostics",
            context: nil
        )
    }

    // Logging ---------------------------------------------------------------

    /// Thread-safe logging to OSLog + text file + JSONL.
    /// Context is flattened to [String:String] to avoid Sendable/data-race warnings.
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

        // Flatten context → [String:String] (immutable let to avoid captured-var warnings)
        let sctx: [String: String]? = {
            guard let context else { return nil }
            var tmp: [String: String] = [:]
            for (k, v) in context { tmp[k] = String(describing: v) }
            return tmp
        }()

        // Write via actor
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
        let lp = ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "OFF"
        log(.info,
            "thermal=\(thermal) lowPower=\(lp) \(note)",
            category: "mem",
            context: ["thermal": thermal, "lowPower": lp])
    }

    /// Writes a rich hardware/app summary into the JSON log (and a simple text line).
    @MainActor
    static func logSummarySnapshot(trigger: String) async {
        let b = Bundle.main
        let name = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "PhotoRevive3D"
        let ver  = (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (b.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let d = UIDevice.current

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
            "release"    : !_isDebugBuild()
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

        // Resolve store environment via StoreKit 2
        let env = await StoreEnvironmentCache.shared.get()
        ctx["storeEnvironment"] = env
        ctx["testFlight"] = (env == "sandbox") // TestFlight uses the sandbox environment for IAP

        log(.info,
            "Summary snapshot (\(trigger)) — Device: \(d.model) (\(d.systemName) \(d.systemVersion))",
            category: "diagnostics",
            context: ctx)
    }

    // Share/report ----------------------------------------------------------

    /// Returns shareable URLs: report.txt, app.log, app.jsonl, and any MetricKit JSON payloads.
    @MainActor
    static func collectShareURLs() async -> [URL] {
        await logSummarySnapshot(trigger: "share")

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

        let tailStr = await LogSink.shared.tailText(maxBytes: 200_000)
        lines.append("=== Log Tail (200000 bytes max) ===")
        lines.append(tailStr)
        lines.append("=== End ===")

        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoRevive3D-report-\(Int(Date().timeIntervalSince1970)).txt")
        _ = try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: reportURL, options: .atomic)

        let textURL = await LogSink.shared.fileURL_text()
        let jsonURL = await LogSink.shared.fileURL_json()

        // Attach any MetricKit JSON payloads we’ve saved
        var extras: [URL] = []
        let dir = await LogSink.shared.dirURL()
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            extras = items.filter { $0.pathExtension.lowercased() == "json" }
        }

        return [reportURL, textURL, jsonURL] + extras
    }

    // Async tails for UI (so views don’t need LogSink)
    nonisolated static func tailTextAsync(maxBytes: Int) async -> String { await LogSink.shared.tailText(maxBytes: maxBytes) }
    nonisolated static func tailJSONAsync(maxBytes: Int) async -> String { await LogSink.shared.tailJSON(maxBytes: maxBytes) }

    // UI helpers ------------------------------------------------------------

    nonisolated static var diagnosticsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            _ = try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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

    // MetricKit JSON helpers (opaque JSON)

    nonisolated static var lastCrashJSON: String? {
        let dir = diagnosticsDir
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let candidates = files.filter { $0.lastPathComponent.hasPrefix("MXDiag") && $0.pathExtension.lowercased() == "json" }
        let pool = candidates.isEmpty ? files.filter { $0.lastPathComponent.hasPrefix("MX") && $0.pathExtension.lowercased() == "json" } : candidates
        guard !pool.isEmpty else { return nil }
        let latest = pool.max(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        })!
        return try? String(contentsOf: latest, encoding: .utf8)
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
            let parts = [
                signal.isEmpty ? nil : "signal \(signal)",
                exceptionType.isEmpty ? nil : "exceptionType \(exceptionType)",
                termination.isEmpty ? nil : termination,
                topSymbol.isEmpty ? nil : "top: \(topSymbol)"
            ].compactMap { $0 }
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

    private static func _isDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private static func currentScreenInfo() -> (pxWidth: Int, pxHeight: Int, scale: CGFloat)? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let screen = scenes.first(where: { $0.activationState == .foregroundActive })?.screen
            ?? scenes.first?.screen
        guard let sc = screen else { return nil }
        let size = sc.bounds.size
        let scale = sc.scale
        return (Int(size.width * scale), Int(size.height * scale), scale)
    }
}
