//
//  MetricsSubscriber.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
@preconcurrency import MetricKit

final class MetricsSubscriber: NSObject {
    static let shared = MetricsSubscriber()

    @MainActor
    func start() {
        if #available(iOS 14.0, *) {
            MXMetricManager.shared.add(self)
            Diagnostics.log(.info, "MetricKit subscriber added", category: "metrics")
        }
    }

    func savedPayloads() -> [URL] {
        let dir = Diagnostics.diagnosticsDir()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("MX") && $0.pathExtension == "json" }
    }

    // Must be callable from MetricKit's background queue.
    nonisolated private func save(data: Data, prefix: String) {
        let url = Diagnostics.diagnosticsDir()
            .appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url, options: .atomic)
            Diagnostics.log(.info, "Saved \(prefix) payload: \(url.lastPathComponent)", category: "metrics")
        } catch {
            Diagnostics.log(.error, "Failed to save \(prefix): \(error)", category: "metrics")
        }
    }
}

@available(iOS 14.0, *)
extension MetricsSubscriber: MXMetricManagerSubscriber {

    // Runs on com.apple.metrickit.manager.queue
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            let data = p.jsonRepresentation()
            self.save(data: data, prefix: "MXMetric")
        }
    }

    // Runs on com.apple.metrickit.manager.queue
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let data = p.jsonRepresentation()
            self.save(data: data, prefix: "MXDiag")
        }
    }
}
