// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation
import IOKit

/// Read-only diagnostic. Lists every temperature, power and fan key this Mac's
/// SMC exposes, so a sensor map is written from what the hardware reports
/// rather than from what a key list on the internet claims. Never writes.
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
            let decoded = client.readBytes(key).flatMap { decode($0, type: key.dataType) }
            let shown = decoded.map { String(format: "%.2f", $0) } ?? "-"
            print("\(key.name)\t\(key.dataType)\t\(key.dataSize)\t\(shown)")
        }
    }

    /// Mirrors SMCValueCodec.decode for the types the SMC actually uses for
    /// these keys. Duplicated on purpose to keep this tool dependency-free.
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float32(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78" where bytes.count == 2:
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 256.0
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count == 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }
}
