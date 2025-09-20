//
//  MetricsSubscriber.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  inimal MetricKit subscriber that saves diagnostic payloads as JSON
//  into Diagnostics.diagnosticsDir. Safe to include in Release builds.
//

import Foundation

#if canImport(MetricKit)
import MetricKit

@available(iOS 14.0, *)
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {

    static let shared = MetricsSubscriber()

    func start() {
        MXMetricManager.shared.add(self)
        Diagnostics.log(.info, "MetricKit subscriber started (on demand)", category: "metrics")
    }

    func stop() {
        MXMetricManager.shared.remove(self)
        Diagnostics.log(.info, "MetricKit subscriber stopped", category: "metrics")
    }

    // Diagnostic payloads (crash, hang, etc.)
    // Keep lightweight and non-UI; avoid @MainActor here.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let dir = Diagnostics.diagnosticsDir
        var saved = 0

        for (idx, payload) in payloads.enumerated() {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = f.string(from: Date())
            let url = dir.appendingPathComponent("MXDiag-\(stamp)-\(idx).json")

            let dict = payload.dictionaryRepresentation()
            if JSONSerialization.isValidJSONObject(dict),
               let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
                do { try data.write(to: url, options: .atomic); saved += 1 } catch { }
            } else if let data = String(describing: dict).data(using: .utf8) {
                try? data.write(to: url, options: .atomic)
                saved += 1
            }
        }

        Diagnostics.log(.info, "MetricKit: saved \(saved)/\(payloads.count) diagnostic payload(s)", category: "metrics")
    }

    // Metric payloads (not persisted here)
    func didReceive(_ payloads: [MXMetricPayload]) {
        Diagnostics.log(.info, "MetricKit: received \(payloads.count) metric payload(s)", category: "metrics")
    }
}

#else
final class MetricsSubscriber {
    static let shared = MetricsSubscriber()
    func start() {}
    func stop() {}
}
#endif
