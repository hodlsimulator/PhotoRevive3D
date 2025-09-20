//
//  MetricsSubscriber.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  Robust MetricKit subscriber. Saves raw JSON payloads (no strict decoding).
//  Avoids UI/table crashes caused by shape drift across iOS versions.
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

    // MARK: - MXMetricManagerSubscriber

    // Daily/periodic metrics
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard !payloads.isEmpty else { return }
        let dir = Diagnostics.diagnosticsDir
        let formatter = ISO8601DateFormatter()
        for p in payloads {
            let data = p.jsonRepresentation() // Data (non-optional)
            let tsRaw = formatter.string(from: Date())
            let ts = tsRaw.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
            let url = dir.appendingPathComponent("MX-\(ts).json")
            do { try data.write(to: url, options: .atomic) } catch {}
        }
        Diagnostics.log(.info, "Saved \(payloads.count) MXMetricPayload JSON file(s)", category: "metrics")
    }

    // Crash/hang/CPU diagnostics
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        let dir = Diagnostics.diagnosticsDir
        let formatter = ISO8601DateFormatter()
        for p in payloads {
            let data = p.jsonRepresentation() // Data (non-optional)
            let tsRaw = formatter.string(from: Date())
            let ts = tsRaw.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
            let url = dir.appendingPathComponent("MXDiag-\(ts).json")
            do { try data.write(to: url, options: .atomic) } catch {}
        }
        Diagnostics.log(.error, "Received \(payloads.count) diagnostic payload(s) — saved as JSON", category: "metrics")
    }
}
