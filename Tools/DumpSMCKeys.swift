// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation
import IOKit

/// Read-only diagnostic. Lists every temperature, power and fan key this Mac's
/// SMC exposes, so a sensor map is written from what the hardware reports
/// rather than from what a key list on the internet claims. Never writes.
///
/// Compiles against SMCClient.swift, which itself calls into SMCValueCodec
/// (FanControlSupport.swift) and TemperatureSensorSelector.swift. All four
/// files must be passed to swiftc together; see the plan for the command.
@main
struct DumpSMCKeys {
    static func main() {
        guard let client = SMCClient() else {
            FileHandle.standardError.write(Data("cannot open AppleSMC\n".utf8))
            exit(1)
        }

        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        print("# cpu\t\(String(cString: buffer))")

        // Only the three families this port cares about. The rest of the SMC is
        // irrelevant here and some of it is slow to enumerate.
        let keys = client.keys { $0.hasPrefix("T") || $0.hasPrefix("P") || $0.hasPrefix("F") }
        print("# key\ttype\tsize\tvalue")
        for key in keys.sorted(by: { $0.name < $1.name }) {
            let decoded = client.readValue(key)
            let shown = decoded.map { String(format: "%.2f", $0) } ?? "-"
            print("\(key.name)\t\(key.dataType)\t\(key.dataSize)\t\(shown)")
        }
    }
}
