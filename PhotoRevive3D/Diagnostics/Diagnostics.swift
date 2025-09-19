//
//  Diagnostics.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
import os
import UIKit

enum Diagnostics {
    enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    // Actor that owns the rolling log file.
    private static let store = LogStore()

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
        // Create a local logger so there’s no actor-isolated stored property.
        let logger = Logger(subsystem: subsystem(), category: category)
        switch level {
        case .debug: logger.debug("\(category): \(message, privacy: .public)")
        case .info:  logger.log("\(category): \(message, privacy: .public)")
        case .warn:  logger.warning("\(category): \(message, privacy: .public)")
        case .error: logger.error("\(category): \(message, privacy: .public)")
        }

        // Rolling file log (persists across crashes).
        let ts = timestamp()
        let lineStr = "[\(ts)] [\(level.rawValue)] [\(category)] \(message) (\(file):\(line) \(function))"
        Task.detached(priority: .utility) { await store.append(lineStr) }
    }

    static func tail(_ maxBytes: Int = 64 * 1024) async -> String {
        await store.tail(maxBytes)
    }

    // MARK: - Clear / purge

    /// Clears the rolling logs (current + backup), removes saved MetricKit payloads, and clears the crash marker.
    static func clearAll() async {
        await store.clear()

        let fm = FileManager.default
        let dir = diagnosticsDir()

        // Remove MetricKit payloads and the RUNNING marker.
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
        // Hop to main actor explicitly for the summary
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
            } catch {
                /* ignore */
            }
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
