// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum BatteryTimeSupport {
    static func remainingSeconds(timeToEmptyMinutes: Int?,
                                 externalConnected: Bool,
                                 isCharging: Bool) -> TimeInterval? {
        guard !externalConnected,
              !isCharging,
              let minutes = timeToEmptyMinutes,
              (1..<(7 * 24 * 60)).contains(minutes) else { return nil }
        return TimeInterval(minutes * 60)
    }

    static func formatted(seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0, seconds / 60 < Double(Int.max) else { return nil }
        let totalMinutes = max(1, Int(seconds / 60))
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    // On Apple Silicon, CurrentCapacity is already a percentage and MaxCapacity
    // is 100, so capacity/maxCapacity is a no-op that reproduces the displayed
    // percentage exactly. On Intel, both fields are raw milliamp-hours, so the
    // same ratio is the cell's raw charge fraction, which reads about 1% below
    // the figure macOS itself displays near full charge (e.g. 8519/8606 -> 99%
    // while macOS shows 100%). UISoc, nested in BatteryData, is the value macOS
    // uses for "State of Charge (%)" on-screen, so prefer it whenever it is a
    // plausible percentage and only fall back to the raw ratio otherwise.
    static func chargePercent(uiSoc: Int?, capacity: Int?, maxCapacity: Int?) -> Int? {
        if let uiSoc, (0...100).contains(uiSoc) {
            return uiSoc
        }
        guard let capacity, let maxCapacity, maxCapacity > 0 else { return nil }
        let ratio = Int((Double(capacity) / Double(maxCapacity) * 100).rounded())
        // A swollen or newly-calibrated battery can report CurrentCapacity above
        // MaxCapacity, which would otherwise push this past 100%.
        return min(100, max(0, ratio))
    }
}
