//
//  MetricsSubscriber.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  Robust MetricKit subscriber that writes opaque JSON payloads to disk.
//  No table parsing; no Codable structs. Avoids crashes when Apple changes keys.
//

import Foundation
import MetricKit

final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsSubscriber()
    private(set) var isStarted = false

    func start() {
        guard !isStarted else { return }
        MXMetricManager.shared.add(self)
        isStarted = true
        Diagnostics.log(.info, "MetricKit subscriber started (on demand)", category: "metrics")
    }

    func stop() {
        guard isStarted else { return }
        MXMetricManager.shared.remove(self)
        isStarted = false
        Diagnostics.log(.info, "MetricKit subscriber stopped", category: "metrics")
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard !payloads.isEmpty else { return }
        let dir = Diagnostics.diagnosticsDir
        for p in payloads {
            let data = p.jsonRepresentation() // non-optional Data
            let filename = "MX-\(safeTimestamp()).json"
            let url = dir.appendingPathComponent(filename)
            do { try data.write(to: url, options: .atomic) } catch {}
        }
        Diagnostics.log(.info, "Saved \(payloads.count) MXMetricPayload JSON file(s)", category: "metrics")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        let dir = Diagnostics.diagnosticsDir
        for p in payloads {
            let data = p.jsonRepresentation() // non-optional Data
            let filename = "MXDiag-\(safeTimestamp()).json"
            let url = dir.appendingPathComponent(filename)
            do { try data.write(to: url, options: .atomic) } catch {}
        }
        Diagnostics.log(.error, "Received \(payloads.count) diagnostic payload(s) — saved as JSON", category: "metrics")
    }

    // MARK: helpers

    private func safeTimestamp() -> String {
        let raw = ISO8601DateFormatter().string(from: Date())
        // Make FS-safe
        return raw
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
