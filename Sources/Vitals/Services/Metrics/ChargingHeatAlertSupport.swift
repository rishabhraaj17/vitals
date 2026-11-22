// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The "hot while charging" alert. Heat wears a battery fastest while it sits
/// on the charger near full, so this alert only watches the battery
/// temperature while external power is connected — charging or holding.
/// Off the charger it reports nothing, which resets its `SustainedAlertGate`,
/// so unplugging cancels a pending alert and plugging back in starts afresh.
enum ChargingHeatAlertSupport {
    static let defaultThreshold = 38
    static let thresholdRange = 30...50

    static func watchedTemperature(batteryTemperature: Double?, onExternalPower: Bool) -> Double? {
        onExternalPower ? batteryTemperature : nil
    }
}
