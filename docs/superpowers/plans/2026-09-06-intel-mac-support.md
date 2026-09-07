# Intel Mac Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Vorssaint build, launch, and read its sensors correctly on a 2019 Intel MacBook Pro, in ascending order of risk, without changing Apple Silicon behaviour.

**Architecture:** One build-script line becomes architecture-derived. `CPUTemperaturePlatform` gains an `.intel` case with explicit SMC key allowlists, mirroring how the file already models each Apple Silicon generation. GPU key classification moves from four inlined `hasPrefix("Tg")` checks into one selector method. `PowerSampler` resolves its keys from a candidate list. Fan control needs no code change at all — its key names are already the Intel set — so it is a verification stage, deliberately placed last because it is the only path that writes to hardware.

**Tech Stack:** Swift 6.3.3 (Xcode Command Line Tools, no Xcode.app), `swiftc` driven directly by `build.sh`, custom `@main` test harness in `Tests/MetricsTests.swift` (no XCTest — `swift test` does not work with Command Line Tools), IOKit `AppleSMC` user client.

**Spec:** `docs/superpowers/specs/2026-09-06-intel-mac-support.md`

---

## Global Constraints

- **Never push to the upstream remote.** Upstream declined Intel support (`CONTRIBUTING.md:142`). This is a permanent private fork. Commit locally; never run `git push`.
- **Apple Silicon behaviour must stay byte-identical.** Every existing assertion in `Tests/MetricsTests.swift` must still pass after every task. New enum cases and new branches only; never widen an existing branch.
- **No key enters `Sources/` that the Stage 0 dump did not confirm present** on the target machine. Task 1 produces the evidence; Tasks 3 and 5 consume it.
- **Deployment target stays `14.0`.** Do not raise it to match the host's macOS 26.
- **No SMC write before Task 8.** Tasks 1–7 are read-only with respect to hardware.
- **House style:** two-space Markdown-free Swift, explicit `Set<String>` key tables, comments that explain *why* not *what*. Match the file you are editing.
- **Commit message format:** `type(scope): lowercase imperative phrase`, reusing a scope already present in `git log --oneline`. Relevant scopes here: `metrics`, `build`, `fan-control`.

---

## Execution Modes

This plan is written so the commands are identical either way. Choose one before Task 1.

### Option A — Assistant executes on this machine

The assistant runs every command in Tasks 1–5 and reports output. Tasks 6–8 touch `/Applications`, TCC permissions, a root LaunchDaemon, and fan hardware; the assistant **stops before each of those and asks for explicit confirmation**, then runs them with the user watching.

- Fastest path to a working app, because sensor work needs real hardware readings to verify.
- The build is native. It cannot be containerized — see spec §7.
- Assistant never runs `git push`, `sudo`, or anything under `/Applications` without confirmation.

### Option B — User executes, assistant only writes code

The assistant produces every edit and stops. The user runs `./build.sh --test`, `./build.sh`, and pastes output back. The assistant reads the output and continues.

- Slower loop, because each verification step is a round trip.
- **Task 1 still has to run on the target machine** — its output is an input to Tasks 3 and 5. Without it, those tasks proceed on documented-but-unverified key names, which violates the spec's R5.
- Recommended if the user wants to read every diff before it touches the tree.

**Divergence points:** Tasks 6, 7, and 8 only. In Option A they are confirmation-gated; in Option B they are handed over entirely.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Tools/DumpSMCKeys.swift` | Create | Read-only diagnostic. Prints every `T*`/`P*`/`F*` SMC key with type, size, and decoded value. Not part of the app build, but not standalone either — it compiles against `SMCClient.swift`, `FanControlSupport.swift`, and `TemperatureSensorSelector.swift` together. Matches the existing standalone-tool pattern (`Tools/MakeIcon.swift`, `Tools/MakeGIF.swift`) in that it ships outside the app target, not in its dependency footprint. |
| `docs/superpowers/intel-smc-keys.txt` | Create | Captured output of the above. The evidence Tasks 3 and 5 argue from. |
| `build.sh:62` | Modify | `TARGET` derived from a `sysctl -n hw.optional.arm64` hardware check instead of hardcoded arm64. Not `uname -m`, which reports the calling process's architecture and would answer x86_64 under Rosetta on an Apple Silicon Mac. |
| `Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift` | Modify | Add `.intel` platform, Intel CPU core/auxiliary/GPU key tables, and the shared `isGPUTemperatureKey` classifier. All sensor-key policy stays in this one file. |
| `Sources/Vorssaint/Services/SystemMonitor/SystemMonitor.swift:902-919` | Modify | Route GPU key collection through the new classifier (2 sites). |
| `Sources/Vorssaint/Services/FanControl/FanControlHardware.swift:313-323` | Modify | Same, for the fan curve's sensor discovery (2 sites). |
| `Sources/Vorssaint/Services/Metrics/PowerSampler.swift:50-72` | Modify | Resolve power keys from candidate lists. |
| `Tests/MetricsTests.swift` | Modify | New assertions beside the existing platform and display tests (~line 1798 and ~line 1914). |

Everything else in the repo is architecture-neutral and is not touched.

---

# STAGE 0 — Reconnaissance (no writes, no risk)

## Task 1: SMC key dump tool

Produces the ground truth every later sensor task depends on. Read-only: it
opens the AppleSMC user client, enumerates keys, and reads them. It never calls
`writeBytes`.

**Files:**
- Create: `Tools/DumpSMCKeys.swift`
- Create: `docs/superpowers/intel-smc-keys.txt`

**Interfaces:**
- Consumes: `SMCClient` from `Sources/Vorssaint/Services/SystemMonitor/SMCClient.swift` — `init?()`, `keys(where: (String) -> Bool) -> [Key]`, `readValue(_ key: Key) -> Double?`, and `Key` with `.name: String`, `.dataSize: UInt32`, `.dataType: String`. `readValue` decodes through `SMCValueCodec`, so `FanControlSupport.swift` and `TemperatureSensorSelector.swift` are also compiled in — see Step 2.
- Produces: a tab-separated dump at `docs/superpowers/intel-smc-keys.txt`. Task 3 reads the `T*` rows; Task 5 reads the `P*` rows; Task 7 reads the `F*` rows.

- [ ] **Step 1: Write the dump tool**

Create `Tools/DumpSMCKeys.swift`. It decodes values through `SMCClient.readValue`,
which calls into `SMCValueCodec` (`Sources/Vorssaint/Services/FanControl/FanControlSupport.swift`),
which in turn requires `Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift`.
The tool is not standalone: all four files must be passed to `swiftc` together
(see Step 2). It stays read-only — it never calls `writeValue` or `writeBytes`.

```swift
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
```

- [ ] **Step 2: Compile it**

```bash
mkdir -p build
swiftc -Onone -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Sources/Vorssaint/Services/SystemMonitor/SMCClient.swift \
  Sources/Vorssaint/Services/FanControl/FanControlSupport.swift \
  Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift \
  Tools/DumpSMCKeys.swift \
  -o build/dump-smc-keys
```

Expected: no output, exit 0.

If it fails with `'main' attribute cannot be used in a module that contains top-level code`, add `-parse-as-library` before the source files. If it fails on an unresolved `kIOMainPortDefault`, the SDK is older than expected — stop and report rather than substituting `kIOMasterPortDefault`.

- [ ] **Step 3: Run it and capture the dump**

```bash
./build/dump-smc-keys | tee docs/superpowers/intel-smc-keys.txt
```

Expected: a `# cpu` line naming an Intel processor, then a `# key` header, then
roughly 100–300 tab-separated rows. Confirm all four of these are true before
continuing — they are the assumptions Tasks 3, 5, and 7 rest on:

```bash
grep -cE '^TC' docs/superpowers/intel-smc-keys.txt   # CPU temp keys present, expect >= 2
grep -cE '^TG' docs/superpowers/intel-smc-keys.txt   # GPU temp keys present
grep -E  '^(FNum|F0Ac|F0Mn|F0Mx|F0Tg|F0Md|F0md)' docs/superpowers/intel-smc-keys.txt
grep -E  '^P' docs/superpowers/intel-smc-keys.txt | head -20
```

**Stop and report if `grep -cE '^TC'` returns 0.** That would mean this machine
exposes CPU temperature somewhere other than the `TC*` family, and Task 3's key
tables are wrong for it.

- [ ] **Step 4: Commit**

```bash
git add Tools/DumpSMCKeys.swift docs/superpowers/intel-smc-keys.txt \
        docs/superpowers/specs/2026-09-06-intel-mac-support.md \
        docs/superpowers/plans/2026-09-06-intel-mac-support.md
git commit -m "chore(metrics): add read-only smc key dump tool and intel capture"
```

**Exit criteria for Stage 0:** `docs/superpowers/intel-smc-keys.txt` exists and lists at least two `TC*` keys with plausible temperature values (roughly 20–90).

---

# STAGE 1 — Build and boot (no writes; worst case is an app crash)

## Task 2: Derive the build target from the host architecture

This is the only true build blocker, and it blocks the test suite too: with
`TARGET` hardcoded to arm64, `./build.sh --test` cross-compiles an arm64 test
binary that this Intel host then cannot execute. Every later task's verification
step depends on this one landing first.

**Files:**
- Modify: `build.sh:62`

**Interfaces:**
- Consumes: nothing.
- Produces: a `TARGET` shell variable of the form `<arch>-apple-macosx14.0`, consumed by the five `swiftc` invocations at `build.sh:254,448,454,460,471`.

- [ ] **Step 1: Observe the current failure**

```bash
./build.sh --test
```

Expected: the compile succeeds but the run fails — a `Bad CPU type in executable`
error, or the harness exiting non-zero without printing a check count. Record the
exact message; it is the "before" half of this task's evidence.

- [ ] **Step 2: Make the target architecture-derived**

In `build.sh`, replace line 62:

```bash
TARGET="arm64-apple-macosx14.0"
```

with:

```bash
# Build for the machine doing the building. Upstream only ships Apple Silicon,
# so this was pinned; deriving it keeps arm64 identical and lets an Intel Mac
# build and run its own binary and test harness. The architecture comes from the
# hardware rather than `uname -m`, which reports the calling process's
# architecture and would answer x86_64 for a shell running under Rosetta on an
# Apple Silicon Mac, quietly cross-compiling an Intel build there.
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then
    TARGET="arm64-apple-macosx14.0"
else
    TARGET="x86_64-apple-macosx14.0"
fi
```

- [ ] **Step 3: Verify the target resolves**

```bash
bash -c 'if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then echo "arm64-apple-macosx14.0"; else echo "x86_64-apple-macosx14.0"; fi'
```

Expected on this machine: `x86_64-apple-macosx14.0`

- [ ] **Step 4: Run the test suite**

```bash
./build.sh --test
```

Expected: PASS. The harness prints a check count and exits 0. This is the
baseline every later task must preserve — record the check count.

- [ ] **Step 5: Build the app**

```bash
./build.sh
```

Expected: exit 0, and `build/Vorssaint.app` exists. The script signs ad-hoc or
with the local identity; it does **not** install, because `--install` was not
passed.

- [ ] **Step 6: Launch it and confirm it boots**

```bash
open build/Vorssaint.app
```

Expected: a menu bar icon appears. Click it; the panel opens. Temperature
readings will be blank or absent — that is Task 3's job, not a failure here.

If it crashes, get the reason before proceeding:

```bash
log show --predicate 'process == "Vorssaint"' --last 5m --style compact | tail -50
```

- [ ] **Step 7: Commit**

```bash
git add build.sh
git commit -m "chore(build): derive the swift target from the host architecture"
```

**Exit criteria for Stage 1:** `./build.sh --test` passes, `./build.sh` succeeds, and the app shows a menu bar icon and an openable panel.

---

# STAGE 2 — Temperature sensors (read-only; worst case is a wrong number on screen)

## Task 3: Intel CPU and GPU temperature key selection

**Files:**
- Modify: `Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift`
- Test: `Tests/MetricsTests.swift` (insert near line 1798 and near line 1914)

**Interfaces:**
- Consumes: the `TC*` and `TG*` rows of `docs/superpowers/intel-smc-keys.txt` from Task 1.
- Produces, all on `enum TemperatureSensorSelector`:
  - `CPUTemperaturePlatform.intel` — new enum case.
  - `static func isGPUTemperatureKey(_ key: String, platform: CPUTemperaturePlatform) -> Bool` — new; Task 4 replaces four inlined `hasPrefix("Tg")` checks with it.
  - Existing signatures unchanged: `platform(brandString: String?) -> CPUTemperaturePlatform`, `currentPlatform() -> CPUTemperaturePlatform`, `displayedCPUTemperature(readings: [(key: String, value: Double)], platform: CPUTemperaturePlatform) -> Double?`, `hasCPUCoreSet(platform:) -> Bool`, `isCPUCoreKey(_:platform:) -> Bool`, `isCPUTemperatureKey(_:platform:) -> Bool`.

- [ ] **Step 1: Reconcile the planned key tables against the dump**

Before writing code, check the tables below against Task 1's capture:

```bash
grep -E '^(TC0C|TC1C|TC2C|TC3C|TC4C|TC5C|TC6C|TC7C|TC8C|TC9C)' docs/superpowers/intel-smc-keys.txt
grep -E '^(TC0P|TC0D|TC0E|TC0F|TC0H|TCXC|TCXc|TCSC|TCSA)' docs/superpowers/intel-smc-keys.txt
grep -E '^(TG0P|TG0D|TG1D|TGDD)' docs/superpowers/intel-smc-keys.txt
grep -E '^TCGC' docs/superpowers/intel-smc-keys.txt
```

**Delete from the Swift tables in Step 3 any key the dump does not list.** Do not
add keys the dump lists but these greps missed without checking what they are
first — an unrecognized `TC*` key may be a package or PECI-offset sensor rather
than a core temperature, and adding it would show the wrong number.

Note that `TCGC` is the Intel PECI **GPU** sensor. It starts with `TC` but must
never be classified as CPU. That is the reason these tables are explicit
allowlists instead of a `hasPrefix("TC")` rule.

- [ ] **Step 2: Write the failing tests**

In `Tests/MetricsTests.swift`, immediately after the existing line

```swift
        expect(!TemperatureSensorSelector.hasCPUCoreSet(platform: a18Platform),
               "A18 Pro discovery keeps its fallback readings without inventing a per-core map")
```

insert:

```swift
        expect(TemperatureSensorSelector.platform(
                   brandString: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == .intel,
               "an Intel brand string selects the Intel sensor map")
        expect(TemperatureSensorSelector.platform(
                   brandString: "  Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz\n") == .intel,
               "Intel identification ignores surrounding whitespace")
        expect(!TemperatureSensorSelector.hasCPUCoreSet(platform: .intel),
               "Intel keeps its die and proximity fallback instead of demanding a per-core map")
        expect(TemperatureSensorSelector.isCPUCoreKey("TC0C", platform: .intel),
               "Intel per-core PECI sensors are core keys")
        expect(TemperatureSensorSelector.isCPUTemperatureKey("TC0P", platform: .intel)
               && TemperatureSensorSelector.isCPUTemperatureKey("TC0D", platform: .intel),
               "Intel proximity and die sensors count as CPU temperatures")
        expect(!TemperatureSensorSelector.isCPUTemperatureKey("TCGC", platform: .intel),
               "the Intel PECI GPU sensor is never read as a CPU temperature")
        expect(!TemperatureSensorSelector.isCPUTemperatureKey("Tp01", platform: .intel),
               "Intel never reads an Apple Silicon core key")
        expect(TemperatureSensorSelector.isGPUTemperatureKey("TG0D", platform: .intel),
               "the Intel GPU die sensor is a GPU temperature")
        expect(!TemperatureSensorSelector.isGPUTemperatureKey("TG0D", platform: .appleM4Family),
               "Apple Silicon GPU classification is unchanged by Intel support")
        expect(TemperatureSensorSelector.isGPUTemperatureKey("Tg0f", platform: .appleM4Family),
               "Apple Silicon GPU sensors still classify by their own prefix")
```

Then, immediately after the existing line

```swift
        expectClose(genericCPU ?? -1, 51.6, "generic CPU sensor selection preserves previous hottest behavior")
```

insert:

```swift
        let intelCoreCPU = TemperatureSensorSelector.displayedCPUTemperature(
            readings: [("TC0P", 48.0), ("TC0C", 71.5), ("TC1C", 66.0)],
            platform: .intel
        )
        expectClose(intelCoreCPU ?? -1, 71.5, "Intel prefers the hottest per-core PECI sensor")
        let intelFallbackCPU = TemperatureSensorSelector.displayedCPUTemperature(
            readings: [("TC0P", 48.0), ("TC0D", 55.25)],
            platform: .intel
        )
        expectClose(intelFallbackCPU ?? -1, 55.25,
                    "Intel falls back to die and proximity when no core sensor reports")
        let intelInvalidCPU = TemperatureSensorSelector.displayedCPUTemperature(
            readings: [("TC0P", 0.5), ("TC0D", 130.0)],
            platform: .intel
        )
        expect(intelInvalidCPU == nil, "Intel discards implausible readings rather than showing them")
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
./build.sh --test
```

Expected: FAIL to compile, with errors of the form `type 'CPUTemperaturePlatform' has no member 'intel'` and `type 'TemperatureSensorSelector' has no member 'isGPUTemperatureKey'`.

- [ ] **Step 4: Add the `.intel` case to the platform enum**

In `TemperatureSensorSelector.swift`, change:

```swift
    case unmappedAppleSilicon
    case generic
```

to:

```swift
    case unmappedAppleSilicon
    case intel
    case generic
```

- [ ] **Step 5: Add the Intel key tables**

Immediately after the `appleM5CPUCoreKeys` declaration, insert:

```swift
    // Intel sensor names are explicit rather than prefix-matched because TCGC
    // is the PECI *GPU* sensor: a "TC" prefix rule would report it as the CPU
    // temperature. Trim this to what Tools/DumpSMCKeys.swift reports on the
    // machine — a key that is absent simply never resolves, but a key that
    // means something else shows a wrong number.
    private static let intelCPUCoreKeys: Set<String> = [
        "TC0C", "TC1C", "TC2C", "TC3C", "TC4C",
        "TC5C", "TC6C", "TC7C", "TC8C", "TC9C",
    ]

    private static let intelCPUAuxiliaryKeys: Set<String> = [
        "TC0P", "TC0D", "TC0E", "TC0F",
        "TC0H", "TCXC", "TCXc", "TCSC", "TCSA",
    ]

    private static let intelGPUKeys: Set<String> = [
        "TG0P", "TG0D", "TG1D", "TGDD",
    ]
```

- [ ] **Step 6: Detect Intel in `platform(brandString:)`**

Change:

```swift
    static func platform(brandString: String?) -> CPUTemperaturePlatform {
        let brand = brandString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Preserve the established Tp/Te reading path for this supported chip
        // until a verified per-core map is available.
        if brand == "Apple A18 Pro" { return .generic }
```

to:

```swift
    static func platform(brandString: String?) -> CPUTemperaturePlatform {
        let brand = brandString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An Intel Mac reports its vendor here and reads an entirely separate
        // sensor family, so it is decided before any Apple mapping is tried.
        if brand.hasPrefix("Intel") { return .intel }
        // Preserve the established Tp/Te reading path for this supported chip
        // until a verified per-core map is available.
        if brand == "Apple A18 Pro" { return .generic }
```

- [ ] **Step 7: Route `.intel` through the four classification methods**

In `displayedCPUTemperature`, change:

```swift
        switch platform {
        case .generic:
            return valid.map { $0.value }.max()
```

to:

```swift
        switch platform {
        case .generic, .intel:
            return valid.map { $0.value }.max()
```

In `hasCPUCoreSet`, change:

```swift
        case .unmappedAppleSilicon, .generic: return false
```

to:

```swift
        case .unmappedAppleSilicon, .generic, .intel: return false
```

In `isCPUCoreKey`, change:

```swift
        case .unmappedAppleSilicon, .generic:
            return false
        }
```

to:

```swift
        case .intel:
            return intelCPUCoreKeys.contains(key)
        case .unmappedAppleSilicon, .generic:
            return false
        }
```

In `isCPUTemperatureKey`, change:

```swift
    static func isCPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        if platform == .unmappedAppleSilicon { return false }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return true }
        return platform == .appleM3Family && key.hasPrefix("Tf")
    }
```

to:

```swift
    static func isCPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        if platform == .unmappedAppleSilicon { return false }
        // Tested before the Apple prefixes so an Intel Mac can only ever read
        // keys this file has vetted.
        if platform == .intel {
            return intelCPUCoreKeys.contains(key) || intelCPUAuxiliaryKeys.contains(key)
        }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return true }
        return platform == .appleM3Family && key.hasPrefix("Tf")
    }

    /// GPU sensors are named per platform the same way CPU ones are. Four call
    /// sites used to inline the Apple Silicon prefix; they share this instead so
    /// the two families cannot drift apart.
    static func isGPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        if platform == .intel { return intelGPUKeys.contains(key) }
        return key.hasPrefix("Tg")
    }
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
./build.sh --test
```

Expected: PASS, with a check count higher than Task 2's baseline by exactly 13.
Any pre-existing assertion that now fails is a regression against constraint R4 —
stop and fix rather than adjusting the old assertion.

- [ ] **Step 9: Commit**

```bash
git add Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift Tests/MetricsTests.swift
git commit -m "feat(metrics): map intel cpu and gpu temperature sensors"
```

---

## Task 4: Route GPU key collection through the shared classifier

Task 3 added `isGPUTemperatureKey` but nothing calls it yet, so Intel GPU
temperature is still blank. This task replaces the four inlined checks.

**Files:**
- Modify: `Sources/Vorssaint/Services/SystemMonitor/SystemMonitor.swift:902-919`
- Modify: `Sources/Vorssaint/Services/FanControl/FanControlHardware.swift:313-323`

**Interfaces:**
- Consumes: `TemperatureSensorSelector.isGPUTemperatureKey(_:platform:)` from Task 3.
- Produces: no new API. `SystemMonitor.gpuKeys` and `FanControlHardware.TemperatureKeys.gpu` become correct on Intel.

- [ ] **Step 1: Find every call site**

```bash
grep -rn 'hasPrefix("Tg")' --include='*.swift' Sources
```

Expected: exactly four lines — `SystemMonitor.swift:905`, `SystemMonitor.swift:919`, `FanControlHardware.swift:316`, `FanControlHardware.swift:323`. If the count differs, reconcile before editing.

- [ ] **Step 2: Update `SystemMonitor`**

Change:

```swift
        let all = client.keys { name in
            TemperatureSensorSelector.isCPUTemperatureKey(name, platform: cpuTemperaturePlatform)
                || name.hasPrefix("Tg")
                || name.range(of: "^TB[0-9]T$", options: .regularExpression) != nil
        }
```

to:

```swift
        let all = client.keys { name in
            TemperatureSensorSelector.isCPUTemperatureKey(name, platform: cpuTemperaturePlatform)
                || TemperatureSensorSelector.isGPUTemperatureKey(name, platform: cpuTemperaturePlatform)
                || name.range(of: "^TB[0-9]T$", options: .regularExpression) != nil
        }
```

and change:

```swift
        gpuKeys = all.filter { $0.name.hasPrefix("Tg") }
```

to:

```swift
        gpuKeys = all.filter {
            TemperatureSensorSelector.isGPUTemperatureKey($0.name, platform: cpuTemperaturePlatform)
        }
```

- [ ] **Step 3: Update `FanControlHardware`**

Change:

```swift
        let keys = client.keys { name in
            TemperatureSensorSelector.isCPUTemperatureKey(name, platform: temperaturePlatform)
                || name.hasPrefix("Tg")
        }
```

to:

```swift
        let keys = client.keys { name in
            TemperatureSensorSelector.isCPUTemperatureKey(name, platform: temperaturePlatform)
                || TemperatureSensorSelector.isGPUTemperatureKey(name, platform: temperaturePlatform)
        }
```

and change:

```swift
            gpu: keys.filter { $0.name.hasPrefix("Tg") }
```

to:

```swift
            gpu: keys.filter {
                TemperatureSensorSelector.isGPUTemperatureKey($0.name, platform: temperaturePlatform)
            }
```

- [ ] **Step 4: Confirm no call site was missed**

```bash
grep -rn 'hasPrefix("Tg")' --include='*.swift' Sources
```

Expected: no output.

- [ ] **Step 5: Run the tests**

```bash
./build.sh --test
```

Expected: PASS, same check count as Task 3 (these files are not in the test compile list; this step guards against a syntax error).

- [ ] **Step 6: Build, launch, and read the real sensors**

```bash
./build.sh && open build/Vorssaint.app
```

Open the panel's System tab. Expected: a CPU temperature in roughly 35–65 °C at
idle, and a GPU temperature if this machine's discrete GPU is powered.

Cross-check against an independent reading:

```bash
sudo powermetrics --samplers smc -i1 -n1 2>/dev/null | grep -i temp
```

Expected: the app's number is within a couple of degrees of the reference. If
the app shows a number ~15 °C higher than the CPU reference, suspect `TCGC` or
another GPU sensor leaking into the CPU set — recheck Task 3 Step 1.

- [ ] **Step 7: Stress the reading briefly**

```bash
yes > /dev/null & yes > /dev/null & sleep 45; kill %1 %2
```

Expected: the displayed temperature climbs during the load and falls after. A
number that never moves means a stale cache, not a live sensor.

- [ ] **Step 8: Commit**

```bash
git add Sources/Vorssaint/Services/SystemMonitor/SystemMonitor.swift \
        Sources/Vorssaint/Services/FanControl/FanControlHardware.swift
git commit -m "fix(metrics): collect gpu sensors through the shared platform classifier"
```

**Exit criteria for Stage 2:** CPU temperature displays a plausible live value that responds to load, verified against `powermetrics`.

---

# STAGE 3 — Power sensors (read-only; worst case is a blank gauge)

## Task 5: Resolve power keys from a candidate list

`PowerSampler` reads `PSTR` and `PDTR`, which are Apple Silicon names. On Intel
they may be absent, in which case the gauge stays blank — correct behaviour, but
worth improving if the dump shows usable keys.

**Files:**
- Modify: `Sources/Vorssaint/Services/Metrics/PowerSampler.swift:50-72`

**Interfaces:**
- Consumes: the `P*` rows of `docs/superpowers/intel-smc-keys.txt` from Task 1.
- Produces: no API change. `PowerSampler.sample() -> PowerReading` keeps its signature; `systemWatts` and `adapterWatts` resolve on more machines.

- [ ] **Step 1: Decide whether this task is needed at all**

```bash
grep -E '^(PSTR|PDTR)' docs/superpowers/intel-smc-keys.txt
```

If **both** are present with plausible watt values, `PowerSampler` already works
on this machine. Skip to Step 6, note the skip in the commit-free handoff, and
move to Stage 4. If either is missing, continue.

```bash
grep -E '^P' docs/superpowers/intel-smc-keys.txt
```

Read the list and pick replacements: a total-system-power key for `systemWatts`
and a DC-in/adapter key for `adapterWatts`. Values should read as watts (single
digits to ~100), not milliwatts or amps.

- [ ] **Step 2: Replace the single-key constants with candidate lists**

Change:

```swift
    /// `PSTR` = System Total Power. `PDTR` = DC-In (adapter) Total Power.
    /// They stay separate because adapter input can include connected devices.
    private static let systemPowerKey = "PSTR"
    private static let adapterPowerKey = "PDTR"
```

to:

```swift
    /// `PSTR` = System Total Power. `PDTR` = DC-In (adapter) Total Power.
    /// They stay separate because adapter input can include connected devices.
    /// Each is a list because the SMC names these differently across machines;
    /// the first key the controller actually exposes wins, and a machine that
    /// exposes none reports nil rather than a number from the wrong sensor.
    private static let systemPowerKeys = ["PSTR"]
    private static let adapterPowerKeys = ["PDTR"]
```

**Append** the keys chosen in Step 1 to the appropriate list, keeping the Apple
Silicon name first so those machines resolve on the first probe exactly as
before. Add no key whose dump value did not read as plausible watts.

- [ ] **Step 3: Resolve the first key that exists**

Change:

```swift
            if !resolvedKeys {
                resolvedKeys = true
                systemKey = smc.key(named: Self.systemPowerKey)
                adapterKey = smc.key(named: Self.adapterPowerKey)
            }
```

to:

```swift
            if !resolvedKeys {
                resolvedKeys = true
                systemKey = Self.systemPowerKeys.lazy.compactMap { smc.key(named: $0) }.first
                adapterKey = Self.adapterPowerKeys.lazy.compactMap { smc.key(named: $0) }.first
            }
```

- [ ] **Step 4: Run the tests**

```bash
./build.sh --test
```

Expected: PASS, same check count as Task 4. (`PowerSampler` is not in the test compile list — this step catches syntax errors only.)

- [ ] **Step 5: Build and read the gauge**

```bash
./build.sh && open build/Vorssaint.app
```

Expected: the System tab shows a system wattage in a plausible range (roughly
8–90 W for this machine). Unplug the charger: the adapter figure should drop out
and battery flow should go negative. Replug: it returns.

- [ ] **Step 6: Commit**

```bash
git add Sources/Vorssaint/Services/Metrics/PowerSampler.swift
git commit -m "fix(metrics): resolve power sensors from a candidate key list"
```

**Exit criteria for Stage 3:** either the power gauge shows plausible live watts, or it is confirmed blank because this machine genuinely exposes no such key — both are acceptable outcomes.

---

# STAGE 4 — Installation and permissions (writes to disk; worst case is orphaned TCC grants)

## Task 6: Install to /Applications with a stable signature

**Confirmation gate.** In Option A the assistant stops here and asks before
running anything in this task.

Until now the app has run from `build/`. Features gated on Accessibility and
Screen Recording need a stable code signature, because macOS ties those grants
to the binary hash — an ad-hoc rebuild orphans them silently while System
Settings still shows them as granted.

**Files:** none modified. This task is procedure and verification.

**Interfaces:**
- Consumes: the working build from Task 4.
- Produces: `/Applications/Vorssaint.app` with a stable local signing identity.

- [ ] **Step 1: Take a rollback point**

```bash
tmutil localsnapshot 2>/dev/null || echo "no snapshot support; continue only if you accept that"
git status --short
```

Expected: `git status` clean apart from anything intentionally in progress.

- [ ] **Step 2: Confirm a stable identity exists**

```bash
security find-identity -v -p codesigning | grep -E 'Developer ID Application|Vorssaint Utils Signing'
```

If neither appears, create the local one — it is free, offline, and idempotent:

```bash
./Tools/setup-signing.sh
```

Expected: exit 0, and the grep above now lists `Vorssaint Utils Signing`.

- [ ] **Step 3: Install**

```bash
./build.sh --install
```

Expected: exit 0, and `/Applications/Vorssaint.app` exists. Note that `build.sh`
re-executes itself for the install step (`VORSSAINT_INSTALL_CHILD`); that is
normal.

- [ ] **Step 4: Verify the signature is not ad-hoc**

```bash
codesign -dv /Applications/Vorssaint.app 2>&1 | grep -E 'Authority|Signature'
```

Expected: an `Authority=` line. A line reading `Signature=adhoc` means TCC grants
will not survive the next rebuild — fix the identity before granting any
permission, or Step 6 will have to be repeated every build.

- [ ] **Step 5: Launch the installed copy**

```bash
open /Applications/Vorssaint.app
```

Expected: menu bar icon appears; the panel still shows the Stage 2 temperatures.

- [ ] **Step 6: Grant permissions one at a time**

Enable one TCC-gated feature, grant its prompt, confirm it works, then move to
the next. Granting all at once makes a failure impossible to attribute.

Suggested order, least to most invasive: Accessibility (window snapping, app
switcher) → Screen Recording (Dock previews, screenshot) → Input Monitoring
(SuperKey, keyboard debounce).

If a feature reports "not permitted" while System Settings shows it granted, the
grant is orphaned:

```bash
tccutil reset Accessibility com.vorssaint.utils
```

then re-grant.

- [ ] **Step 7: Record what works**

Append a short list of working and broken features to
`docs/superpowers/intel-status.md`, then commit:

```bash
git add docs/superpowers/intel-status.md
git commit -m "docs: record intel feature status after install"
```

**Exit criteria for Stage 4:** the app runs from `/Applications` with a non-ad-hoc signature, and TCC-gated features work or their failures are recorded.

---

# STAGE 5 — Fan telemetry (read-only; worst case is a wrong RPM on screen)

## Task 7: Verify fan reading without enabling control

`FanControlHardware` discovers `FNum`, `F<i>Ac`, `F<i>Mn`, `F<i>Mx`, `F<i>Tg`,
and `F<i>Md`/`F<i>md` — the classic Intel key set. **No code change is
expected.** This task proves the read path before anything writes.

**Files:** none modified unless a discovery failure is found.

**Interfaces:**
- Consumes: the `F*` rows of `docs/superpowers/intel-smc-keys.txt` from Task 1; `SystemMonitor.fanTelemetryCount`.
- Produces: a verified-or-refuted assumption that Task 8 depends on.

- [ ] **Step 1: Confirm the keys from the dump**

```bash
grep -E '^(FNum|F[0-9](Ac|Mn|Mx|Tg|Md|md))' docs/superpowers/intel-smc-keys.txt
```

Expected: `FNum` with a value of 1 or 2 (this machine has two fans), and a
matching `Ac`/`Mn`/`Mx`/`Tg`/`Md` set for each fan index. Confirm `F0Mn < F0Mx`
and both are plausible RPM values (roughly 1000–7000).

**If `FNum` is absent or any per-fan key is missing, stop.** `discoverControlledFans`
throws `.unsupported` in that case and Stage 6 is not possible on this machine —
which is a safe outcome, not a bug to work around.

- [ ] **Step 2: Read the live telemetry in the app**

```bash
open /Applications/Vorssaint.app
```

Expected: the System tab shows fan RPM matching the `F0Ac`/`F1Ac` values in the
dump, within normal variation.

- [ ] **Step 3: Confirm the reading tracks reality**

```bash
yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null & \
  yes > /dev/null & yes > /dev/null & sleep 120; kill %1 %2 %3 %4 %5 %6
```

Expected: RPM climbs during the load as the SMC's own thermal management
responds, and settles afterwards. This confirms the read path is live and, just
as importantly, that automatic fan management is working normally — which is the
state Task 8 must be able to return to.

- [ ] **Step 4: Record the resting values**

Write down idle and loaded RPM for each fan, and `F0Mn`/`F0Mx`. Task 8 compares
against these to prove it restored automatic mode.

**Exit criteria for Stage 5:** fan RPM displays live values that respond to load, and the min/max bounds are recorded.

---

# STAGE 6 — Fan control (SMC writes, root helper; highest risk, entered last)

## Task 8: Enable fan control with a rehearsed abort

**Hard confirmation gate.** In Option A the assistant stops and asks. Do not
begin unless all of the following are true:

- Stages 0–5 complete, with fan telemetry verified live in Task 7.
- The Mac is on AC power.
- Activity Monitor is open on the Energy tab, or `sudo powermetrics --samplers smc` is running in a spare terminal.
- Nothing important is unsaved anywhere.

**Files:** none modified. `FanControlHardware` already uses the Intel key set;
this task verifies the write path and the watchdog.

**Interfaces:**
- Consumes: verified telemetry and bounds from Task 7.
- Produces: a confirmed-working or confirmed-abandoned fan control feature.

**Abort procedure — read before starting:**

1. Quit Vorssaint. `FanControlPolicy.restoreReason` returns `.heartbeatLost` when the heartbeat ages past its limit, and the helper restores automatic mode.
2. If fans still sound wrong after a minute, shut down and reset the SMC: with the Mac off, hold the left Control + left Option + right Shift for 7 seconds, then add the power button for 7 more, release, and power on.
3. An SMC reset restores every fan key to its default. Nothing in this app survives it.

- [ ] **Step 1: Confirm the watchdog logic before trusting it**

```bash
grep -n "restoreReason\|heartbeatLimit\|verificationFailureLimit\|temperatureFailureLimit" \
  Sources/Vorssaint/Services/FanControl/FanControlSupport.swift
```

Read `restoreReason` and confirm it still restores on time limit, heartbeat loss,
verification failure, temperature unavailability, and thermal pressure. This is
the safety net; do not proceed if it has been altered.

- [ ] **Step 2: Confirm the helper is the only privileged component**

```bash
grep -rn "SMAppService\|LaunchDaemon" --include='*.swift' Sources | head
codesign -dv /Applications/Vorssaint.app/Contents/Library/LaunchServices/com.vorssaint.utils.fan-control 2>&1 | head -3
```

Expected: the helper binary exists and is signed with the same identity as the app.

- [ ] **Step 3: Enable fan control in the app and approve the helper**

Turn on fan control in the app's Features page. macOS will ask to approve a
background item; approve it.

```bash
sudo launchctl list | grep vorssaint
```

Expected: `com.vorssaint.utils.fan-control` listed.

- [ ] **Step 4: Make the smallest possible manual change**

Set manual mode to the **lowest cooling level above the current automatic
speed** — never below it. Raising fan speed is always thermally safe; lowering
it is the only direction that can matter.

Expected: RPM moves toward the requested target within a few seconds, and the
value stays within the `F0Mn`/`F0Mx` bounds recorded in Task 7. `coolingTargetRPM`
interpolates between those bounds, so a value outside them indicates the bounds
were misread — abort and recheck Task 7.

- [ ] **Step 5: Test the heartbeat watchdog deliberately**

While manual mode is active, force-quit the app:

```bash
pkill -9 Vorssaint
```

Expected: within the heartbeat limit, fans return to automatic behaviour and RPM
tracks temperature again. **This is the single most important verification in the
plan.** If fans stay pinned at the manual target after the app is gone, stop
using fan control, run the abort procedure, and record it as unsupported.

- [ ] **Step 6: Test the temperature watchdog**

Relaunch, set a curve rather than a manual level. Because Stage 2 fixed CPU
sensor reading, curves should now find temperatures. Confirm the curve responds
to load rather than restoring to automatic — a restore here would mean Task 3's
key tables did not actually resolve on this machine.

- [ ] **Step 7: Record the outcome**

Append the result to `docs/superpowers/intel-status.md` — working, or abandoned
and why — then commit:

```bash
git add docs/superpowers/intel-status.md
git commit -m "docs(fan-control): record intel fan control verification outcome"
```

**Exit criteria for Stage 6:** fan control drives the fans, the heartbeat watchdog demonstrably restores automatic mode when the app dies, and the outcome is written down. Or: it is abandoned, with the reason recorded and the feature left off.

---

# STAGE 7 — Publishing (no hardware risk; the risks here are legal, reputational, and to other people's machines)

Two mutually exclusive routes. **Route A** (Tasks 9–10) publishes a patch set:
users apply it to their own upstream checkout and build locally. **Route B**
(Tasks 9, 11–13) publishes a renamed fork with binaries.

Route B is a superset of Route A's Task 9 and roughly ten times the work, most
of it not code. Do Route A first. Graduate to Route B only if demand appears —
retiring a published app is far harder than starting one.

**Why the rename in Route B is not cosmetic.** The bundle identifier is not
confined to `build.sh`. It is compiled into self-protection, uninstall, Dock,
XPC, and update-verification logic, and the maintainer's Apple Team ID is pinned
in three places. Task 11 enumerates them. Skipping any one produces a build that
is broken, unsafe, or falsely claims the maintainer's identity.

## Task 9: Make upstream unpushable, and tell upstream what you are doing

`origin` currently points at upstream **for push as well as fetch**. The
standing instruction never to push is one `git push` away from being violated by
muscle memory. Turn it into something the tooling refuses.

**Files:**
- Modify: `docs/superpowers/intel-status.md` (created in Task 6)

**Interfaces:**
- Consumes: nothing.
- Produces: an `origin` remote that cannot be pushed to, and a recorded upstream conversation.

- [ ] **Step 1: Confirm the hazard**

```bash
git remote -v
```

Expected: `origin  https://github.com/vorssaint/vorssaint-utils.git (push)`. That
push URL is the thing to remove.

- [ ] **Step 2: Disable the push path**

```bash
git remote set-url --push origin DISABLED
```

- [ ] **Step 3: Verify it now fails closed**

```bash
git remote -v
git push --dry-run origin 2>&1 | head -3
```

Expected: the push URL reads `DISABLED`, and the dry run fails with a "does not
appear to be a git repository" style error. A dry run that *succeeds* means the
URL did not take — stop and fix it before any later task creates a commit.

- [ ] **Step 4: Add your own remote when you have one**

Once the publish repo exists (Task 10 Step 6 or Task 13), add it under its own
name so pushes are always explicit about their destination:

```bash
git remote add publish <your repo URL>
git push publish HEAD:main
```

Never re-point `origin`.

- [ ] **Step 5: Tell upstream**

Open an issue on `vorssaint/vorssaint-utils` stating: Intel port working on a
2019 MacBook Pro, intent to publish as a patch set (or renamed fork), asking
whether they object and whether they have a naming preference.

They declined Intel support *in their codebase*, which is not the same as
objecting to a derivative existing. This costs one issue and removes all
ambiguity about the trademark boundary. Do it before publishing, not after.

- [ ] **Step 6: Record the outcome and commit**

Append the issue URL and any reply to `docs/superpowers/intel-status.md`.

```bash
git add docs/superpowers/intel-status.md
git commit -m "docs: record upstream notification and disabled push remote"
```

---

## Task 10: Patch-set publication (Route A)

**Files:**
- Create: `Tools/make-patch.sh`

**Interfaces:**
- Consumes: the commits from Tasks 1–5, and the upstream tag they are based on (`v3.3.3`).
- Produces: `dist/intel-port-<base>.patch` and `dist/INSTALL.md`. Both land in `dist/`, which is already in `.gitignore` — they are artifacts to upload, not files to commit.

- [ ] **Step 1: Write the script**

Create `Tools/make-patch.sh`:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds one patch carrying the Intel port, and proves it applies to a pristine
# checkout of the upstream tag it targets rather than asserting that it does.
set -euo pipefail

cd "$(dirname "$0")/.."

BASE="${1:-v3.3.3}"
OUT="dist"
PATCH="$PWD/$OUT/intel-port-$BASE.patch"

if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "✗ unknown base '$BASE' — pass an upstream tag, e.g. ./Tools/make-patch.sh v3.3.3" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ working tree is dirty; commit or stash first" >&2
    exit 1
fi

mkdir -p "$OUT"

# Planning notes and this machine's own sensor capture are working material, not
# part of the port. Tools/DumpSMCKeys.swift does ship: anyone adapting this to a
# different Intel Mac needs it to build their own key tables.
git diff --binary "$BASE"..HEAD -- . ':(exclude)docs/superpowers' > "$PATCH"

if [[ ! -s "$PATCH" ]]; then
    echo "✗ patch is empty — is HEAD actually ahead of $BASE?" >&2
    exit 1
fi

# A patch nobody has applied is a guess. Apply it to a throwaway worktree at the
# base commit; anything that conflicts fails the build here rather than in a
# stranger's terminal.
TMPROOT="$(mktemp -d)"
WORKTREE="$TMPROOT/base"
cleanup() {
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    rm -rf "$TMPROOT"
}
trap cleanup EXIT
git worktree add --detach --quiet "$WORKTREE" "$BASE"
if ! git -C "$WORKTREE" apply --check "$PATCH"; then
    echo "✗ patch does not apply cleanly to $BASE" >&2
    exit 1
fi

sed "s/__BASE__/$BASE/g" > "$OUT/INSTALL.md" <<'EOF'
# Intel Mac port for Vorssaint __BASE__

Unofficial. Not affiliated with or endorsed by the Vorssaint maintainer, who has
declined Intel support upstream. This is a source patch, not a build: you compile
it yourself, so the result is signed by you and stays on your machine.

Tested on: MacBook Pro 2019 (Core i7-9750H), macOS 26.6.1.

## Requirements

- An Intel Mac running macOS 14 or newer
- Xcode Command Line Tools (`xcode-select --install`)

## Apply and build

```bash
git clone https://github.com/vorssaint/vorssaint-utils.git
cd vorssaint-utils
git checkout __BASE__
git apply /path/to/intel-port-__BASE__.patch
./build.sh --test
./build.sh
open build/Vorssaint.app
```

## Sensors on a different Intel Mac

The CPU and GPU temperature key tables in
`Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift` were built
from one machine. If temperatures read blank or wrong on yours, dump your own
SMC keys and adjust:

```bash
swiftc -Onone -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Sources/Vorssaint/Services/SystemMonitor/SMCClient.swift \
  Sources/Vorssaint/Services/FanControl/FanControlSupport.swift \
  Sources/Vorssaint/Services/Metrics/TemperatureSensorSelector.swift \
  Tools/DumpSMCKeys.swift -o build/dump-smc-keys
./build/dump-smc-keys
```

`TCGC` is the PECI GPU sensor. It starts with `TC` but is not a CPU temperature —
do not add it to the CPU tables.

## Fan control

Off by default and verified last, because it is the only path that writes to the
SMC and it installs a root helper. Read the safety notes in the patch's plan
before enabling it. If fans misbehave, quit the app; the watchdog restores
automatic mode. An SMC reset clears anything it leaves behind.

## Licence

GPL-3.0-or-later, same as upstream. The Vorssaint name, icon, and branding are
not covered by that licence and are not redistributed here.
EOF

echo "✓ $PATCH"
echo "  $(grep -c '' "$PATCH") lines, applies cleanly to $BASE"
echo "✓ $PWD/$OUT/INSTALL.md"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Tools/make-patch.sh
```

- [ ] **Step 3: Run it**

```bash
./Tools/make-patch.sh v3.3.3
```

Expected: two `✓` lines. A dirty-tree or empty-patch error means an earlier task
was left uncommitted — fix that rather than loosening the check.

- [ ] **Step 4: Confirm the patch carries what it should, and nothing it should not**

```bash
grep -E '^(diff --git|\+\+\+ )' dist/intel-port-v3.3.3.patch | grep -c 'docs/superpowers'
git apply --stat dist/intel-port-v3.3.3.patch
```

Expected: the first command prints `0`. The stat listing should show only
`build.sh`, the four Swift sources from Tasks 2–5, `Tests/MetricsTests.swift`,
and `Tools/DumpSMCKeys.swift`.

- [ ] **Step 5: Rehearse the instructions exactly as a stranger would**

```bash
TMP="$(mktemp -d)" && git clone --quiet --branch v3.3.3 --depth 1 \
  https://github.com/vorssaint/vorssaint-utils.git "$TMP/v" && \
  git -C "$TMP/v" apply "$PWD/dist/intel-port-v3.3.3.patch" && \
  echo "APPLIES CLEAN" && rm -rf "$TMP"
```

Expected: `APPLIES CLEAN`. This checks the published instructions against a real
clone, which is not the same thing as the worktree check inside the script — a
shallow clone can expose path or mode assumptions the local repo hides.

- [ ] **Step 6: Publish**

A plain new repository suits this route: it holds the `.patch`, `INSTALL.md`,
the `LICENSE` from upstream, and a README. Forking the whole codebase to store
one diff file is awkward ergonomically — this is a convenience call, not a
requirement. `TRADEMARKS.md` constrains the **build you distribute** (name,
icon, bundle identifier, signing identity, update feed), not where you host the
source. A GitHub fork is permitted; for Route B it is arguably preferable, since
it preserves upstream history and makes rebasing trivial (see Task 13).

The README's **first line** states this is unofficial and unaffiliated. Naming
the upstream project is expected, not risky: GPL §5(a) requires prominent notice
of modification, and referring to a mark to describe provenance is different
from adopting it as your identity. "Based on Vorssaint, GPL-3.0-or-later,
unofficial and not endorsed" is correct; "Vorssaint Intel Edition" is not, and
upstream's icon is off-limits in either case.

Do not include a built `.app` or `.dmg`. The moment a binary ships, the whole of
Task 11 applies to it.

- [ ] **Step 7: Commit the tool**

```bash
git add Tools/make-patch.sh
git commit -m "chore: add patch-set builder for the intel port"
```

**Exit criteria for Route A:** the patch applies cleanly to a fresh shallow clone of `v3.3.3`, and the published repo states its unofficial status before anything else.

---

## Task 11: Rebrand every identity constant (Route B)

Only if shipping binaries. `TRADEMARKS.md` requires a different name, icon,
bundle identifier, signing identity, and update feed. The identifier is the hard
part: it is compiled into behaviour, not just displayed.

**Files:**
- Modify: `build.sh:43-52,64`
- Modify: `Sources/Vorssaint/Core/AppInfo.swift:8-14`
- Modify: `Sources/Vorssaint/Services/FanControl/FanControlXPC.swift:7-12`
- Modify: `Sources/Vorssaint/Services/Update/UpdateInstallerSupport.swift:66,116`
- Modify: `Sources/Vorssaint/Services/Cleaner/CleanerSupport.swift` (`isProtectedBundleID`)
- Modify: `Sources/Vorssaint/Services/DockClick/DockClickSupport.swift:31-35`
- Modify: `Sources/Vorssaint/Services/QuickTools/ScreenshotSharingSupport.swift:43`
- Rename: `Resources/com.vorssaint.utils.fan-control.plist`
- Modify: `Tests/MetricsTests.swift` (12 assertions pin the old identifiers)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a build whose identity is entirely your own. Task 12 depends on the new bundle ID existing before it repoints endpoints.

- [ ] **Step 1: Choose the identity and set it once**

Pick a name that cannot be mistaken for the original, then export these for the
rest of the task. Every command below uses them literally.

```bash
export FORK_NAME="YourName"                       # display name, no "Vorssaint"
export FORK_EXEC="YourName"                       # executable name
export FORK_ID="com.yourdomain.yourname"          # reverse-DNS you control
export FORK_TEAM="XXXXXXXXXX"                     # YOUR Apple Team ID
export FORK_IDENTITY="YourName Signing"           # your signing identity
```

`FORK_ID` must not contain `vorssaint` anywhere — Step 5 explains why that
specific substring matters.

- [ ] **Step 2: Find every occurrence before changing any**

```bash
grep -rn "com\.vorssaint" --include='*.swift' Sources | grep -v Localizations | wc -l
grep -rn "3D485NHW29" --include='*.swift' Sources
grep -rn "com\.vorssaint\.utils" Tests/MetricsTests.swift | wc -l
ls Resources/com.vorssaint.utils.fan-control.plist
```

Expected: roughly 25 Swift hits, exactly 3 Team ID hits, 12 test hits, and the
plist. Record these counts; Step 8 checks them back to zero.

- [ ] **Step 3: Change the Team ID — and do not "fix" the helper by deleting the check**

`FanControlIdentifiers.teamID` (`FanControlXPC.swift:7`) is how the **root
LaunchDaemon authenticates the app talking to it**. `UpdateInstallerSupport.swift:66,116`
are how the updater verifies a downloaded build before installing it.

All three currently pin `3D485NHW29`, the upstream maintainer's Apple Team ID.
Leaving them is a false claim of their identity; more practically, your
differently-signed build fails its own checks.

In `FanControlXPC.swift`:

```swift
    static let teamID = "3D485NHW29"
```

becomes your `FORK_TEAM` value. Likewise both `subject.OU` literals in
`UpdateInstallerSupport.swift`, and the `identifier "com.vorssaint.utils"` in the
`VERIFY_REQ` on line 116 becomes your `FORK_ID`.

**If fan control then fails to connect, the fix is a correct Team ID, never a
weakened requirement.** Removing the check would leave a root daemon accepting
commands from any process on the machine. If you cannot get a real Team ID, ship
with fan control disabled instead.

- [ ] **Step 4: Change the app identity in `build.sh`**

Replace the `APP_NAME`, `EXECUTABLE`, and `APP_BUNDLE_ID` values in both the
`DEV` and release branches (`build.sh:43-52`) with your `FORK_*` values, and
`LEGACY_IDENTITY` (`build.sh:64`) with `FORK_IDENTITY`. `FAN_HELPER_ID` and
`NOW_PLAYING_ADAPTER_ID` derive from `APP_BUNDLE_ID` and need no separate edit.

- [ ] **Step 5: Restore the app's self-protection**

`CleanerSupport.isProtectedBundleID` decides what the Cleaner and Uninstaller
refuse to touch. It matches the literal substring `.com.vorssaint.`:

```swift
        if wrapped.contains(".com.apple.") || wrapped.contains(".com.vorssaint.")
```

Once your bundle ID no longer contains `vorssaint`, **your own app stops being
protected from its own Cleaner.** Add your prefix alongside rather than replacing
Apple's:

```swift
        if wrapped.contains(".com.apple.") || wrapped.contains(".com.vorssaint.")
            || wrapped.contains(".\(yourLoweredPrefix).")
```

Keep the `com.vorssaint` entry: users may still have the original installed, and
your build should not offer to clean it.

Apply the same reasoning to `DockClickSupport.isOwnBundleIdentifier` — add your
two identifiers; the tap must not target your own windows.

- [ ] **Step 6: Rename the helper plist**

```bash
git mv "Resources/com.vorssaint.utils.fan-control.plist" \
       "Resources/$FORK_ID.fan-control.plist"
```

`Tests/MetricsTests.swift:13558` loads this file **by literal path** and
asserts its `Label` matches the helper ID. Update both the path and the expected
label there, or the suite fails on a missing file.

- [ ] **Step 7: Update `AppInfo` and remaining identifiers**

In `AppInfo.swift:8-14`, replace `name`, `copyright`, and all five URLs.
The donation, Discord, and social links point at the upstream maintainer —
shipping them in your build sends your users' goodwill and support requests to
someone who did not agree to receive them. Point them at your own, or delete the
entries and the UI that surfaces them.

Then `ScreenshotSharingSupport.developerBundleIdentifier` (`:43`), and the
remaining `com.vorssaint.*` `DispatchQueue` labels. The queue labels are
cosmetic — they only appear in crash logs and debuggers — but leaving them makes
your crash reports read as upstream's.

- [ ] **Step 8: Verify nothing was missed**

```bash
grep -rn "com\.vorssaint" --include='*.swift' Sources | grep -v Localizations
grep -rn "3D485NHW29" --include='*.swift' Sources
```

Expected: the only surviving hits are the deliberate `com.vorssaint` entries in
`isProtectedBundleID` and `isOwnBundleIdentifier` from Step 5. Zero Team ID hits.

- [ ] **Step 9: Run the tests and fix the pinned assertions**

```bash
./build.sh --test
```

Expected: initially FAIL, on assertions at `MetricsTests.swift:4732, 4745, 9786,
9787, 10774, 10775, 13558, 13561, 18699, 24646, 24648, 24649`. Update each to
your identifiers. Where an assertion checks that the *upstream* ID is protected
(`:4732`), keep it and add one for yours — both should be true.

Re-run until PASS.

- [ ] **Step 10: Build and confirm the identity is real**

```bash
./build.sh
codesign -dv --verbose=2 "build/$FORK_NAME.app" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier'
```

Expected: `Identifier=` your bundle ID, `TeamIdentifier=` your team, no mention of
`vorssaint` or `3D485NHW29`.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "chore: rebrand identity for independent distribution"
```

---

## Task 12: Repoint or disable every outbound endpoint (Route B)

Three services upload to infrastructure the upstream maintainer pays for and
controls. Shipping them unchanged consumes someone else's bandwidth without
consent and routes *your users'* screenshots and recordings through a service
they did not choose. This is the sharpest item in Stage 7 and the easiest to
overlook, because nothing about it fails visibly.

**Files:**
- Modify: `Sources/Vorssaint/Services/Feedback/FeedbackService.swift:61`
- Modify: `Sources/Vorssaint/Services/QuickTools/ScreenshotSharingSupport.swift:42`
- Modify: `Sources/Vorssaint/Services/Recorder/RecordingSharingSupport.swift:48`
- Modify: `Sources/Vorssaint/Services/Update/UpdateService.swift:30`
- Modify: `Sources/Vorssaint/Services/Update/UpdateShowcaseMedia.swift:13`

**Interfaces:**
- Consumes: the new bundle ID from Task 11.
- Produces: a build that contacts only hosts you control.

- [ ] **Step 1: Enumerate what the build talks to**

```bash
grep -rnoE "https://[a-zA-Z0-9./_-]*vorssaint[a-zA-Z0-9./_-]*" \
  --include='*.swift' Sources | sort -u
```

Expected: eight URLs across `AppInfo.swift` (handled in Task 11), the three
sharing endpoints, and `UpdateShowcaseMedia.swift`.

- [ ] **Step 2: Fix the updater first — it is the one that breaks users**

`UpdateService.swift:30` reads:

```swift
    private let repository = "vorssaint/vorssaint-utils"
```

Left alone, your Intel users are offered upstream's **arm64** releases, and the
updater replaces your working build with one that cannot run on their Mac.
Change it to your publish repository.

- [ ] **Step 3: Disable the sharing endpoints unless you are running your own**

The honest default is off. Unless you are actually hosting an equivalent
service, disable upload rather than repointing it at a host that does not exist —
a failing upload with a confusing error is worse than an absent button.

For each of `FeedbackService.swift:61`, `ScreenshotSharingSupport.swift:42`, and
`RecordingSharingSupport.swift:48`: either set your own base URL, or remove the
feature and the UI that offers it. Do not leave `screenshots.vorssaint.com`.

- [ ] **Step 4: Point the showcase media at your own release, or remove it**

`UpdateShowcaseMedia.swift:13` downloads an `.mp4` from upstream's releases and
verifies it against a pinned SHA-256. Either host your own asset and update
`releaseVersion`, `mediaAssetName`, and `mediaSHA256` together, or remove the
showcase. **Never keep the URL and change the hash, or the reverse** — the hash
is what makes the download safe.

- [ ] **Step 5: Prove nothing upstream remains**

```bash
grep -rn "vorssaint\.com\|vorssaint/vorssaint-utils" --include='*.swift' Sources
```

Expected: no output.

- [ ] **Step 6: Watch the built app's actual traffic**

Build, launch, exercise update-check and any sharing feature you kept, and
confirm no connection to a `vorssaint.com` host. A `grep` proves what is in the
source; this proves what the binary does.

- [ ] **Step 7: Run the tests and commit**

```bash
./build.sh --test
git add -A
git commit -m "chore: repoint outbound endpoints away from upstream infrastructure"
```

---

## Task 13: Brand assets, disclosure, and first release (Route B)

**Files:**
- Replace: `Resources/Brand`, `Resources/Images` app icon assets
- Replace: `docs/assets/readme/`
- Rewrite: `README.md`
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Settle the repository relationship**

`TRADEMARKS.md` governs the build you distribute, not where the source lives, so
both options are open. A **GitHub fork** is the better default for this route:
it preserves upstream's commit history (which strengthens rather than weakens
your GPL attribution position), makes `git fetch upstream && git rebase` routine
as upstream releases land, and shows a "forked from vorssaint/vorssaint-utils"
banner that is accurate provenance disclosure. Two practical notes: forks have
Issues disabled by default — enable it in repository settings — and a fork can
be renamed freely, which you will want, since the repo name should match your
product name rather than upstream's.

A detached repository (push a fresh history, no fork relationship) is also
permitted, but you lose easy rebasing and must state provenance entirely in
prose. Choose the fork unless you have a specific reason not to.

Either way, keep `origin` pointing at upstream for fetch only (Task 9) and push
to `publish`.

- [ ] **Step 2: Replace the icon and brand assets**

`TRADEMARKS.md` names the icon explicitly. Generate your own with the existing
tool rather than editing upstream's:

```bash
grep -n "AppIcon\|iconset\|actool" build.sh | head
```

Follow that path with your own artwork. A recoloured version of upstream's icon
is still upstream's icon.

- [ ] **Step 3: Rewrite the README with disclosure first**

The first paragraph — above the fold, before features or screenshots — must
state: this is an unofficial fork, not affiliated with or endorsed by the
Vorssaint maintainer, GPL-3.0-or-later, and what you changed. GPL §5(a) requires
carrying prominent notices of modification; putting it first is also simply
honest.

Remove upstream's Trendshift badges, Discord invite, and download counters.
Those measure someone else's project.

- [ ] **Step 4: State changes as the licence requires**

Keep `LICENSE` unchanged. Keep every existing copyright notice and SPDX header —
add yours to files you substantially changed rather than replacing theirs. Keep
`TRADEMARKS.md` in the tree: it still governs what you may not use.

- [ ] **Step 5: Decide the signing story before releasing**

```bash
security find-identity -v -p codesigning
```

Without an Apple Developer Program membership ($99/yr) you cannot notarize, and
every user meets a Gatekeeper block needing right-click-open or
`xattr -d com.apple.quarantine`. Document that plainly in the README.

Note this interacts with Task 11 Step 3: no Developer Program means no real Team
ID, which means fan control's XPC authentication cannot be satisfied honestly.
Ship with fan control off in that case.

- [ ] **Step 6: Release**

```bash
./build.sh --test && ./build.sh
```

Tag and publish through your own remote (`publish`, from Task 9 Step 4). Attach
`INSTALL.md` notes covering Gatekeeper and Intel-only support.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "docs: rebrand readme and release notes for independent distribution"
```

**Exit criteria for Route B:** `grep -rn "vorssaint" Sources README.md` returns only the deliberate self-protection entries; the app is signed with your identity; the README discloses unofficial status in its first paragraph.

---

## Rollback

Per stage, cheapest first:

| Stage | Undo |
|---|---|
| 7 | Delete or unpublish the release; `git remote remove publish`. Note that anything already downloaded cannot be recalled — this is the one stage whose effects are not fully reversible, which is why Route A is recommended first |
| 6 | Disable fan control in the app; `sudo launchctl bootout system/com.vorssaint.utils.fan-control`; SMC reset if fans misbehave |
| 4 | `./Tools/uninstall.sh`; `tccutil reset Accessibility com.vorssaint.utils` and likewise for `ScreenCapture`, `ListenEvent` |
| 1–3, 5 | `git revert` the task's commit; rebuild |
| all | `git reset --hard <sha of the commit before Task 1>` — the tree returns to upstream state |

Nothing in Stages 0–6 writes outside `/Applications`, `~/Library`, the repo, and
(from Stage 6 only) one root LaunchDaemon. Stage 7 additionally writes to
`dist/` (gitignored) and, at Task 10 Step 6 or Task 13 Step 6, to a remote
repository you control.

---

## Self-Review

**Spec coverage.** R1 → Task 2. R2 → Task 3. R3 → Tasks 3 and 4. R4 → constraint plus the "same check count" assertions in Tasks 3–5 and the explicit Apple Silicon regression tests in Task 3 Step 2. R5 → Task 1, enforced at Task 3 Step 1 and Task 5 Step 1. R6 → Task 5. R7 → the stage ordering with exit criteria. R8 → Global Constraints, hardened at Task 9 Steps 2–3, which disable the push URL on `origin` outright.

Stage 7 is not derived from the spec: it was added after the spec was written, when the user decided to publish. Its governing document is `TRADEMARKS.md`, whose requirements map to tasks as — name, icon, bundle identifier, signing identity → Task 11; update feed → Task 12 Step 2; "any other branding that could imply endorsement" → Task 11 Step 7 (donation, Discord, social links) and Task 13 Steps 2–3. GPL §5(a) modification notices → Task 13 Steps 3–4. If Stage 7 outgrows this, it should be split into its own spec and plan.

**Placeholder scan.** Every code step carries the literal before-and-after text. Three steps call for judgement, all deliberate and all with an explicit decision rule and stop condition rather than a "TBD": trimming key tables to the dump (Task 3 Step 1) and choosing power keys (Task 5 Step 1), because the spec forbids committing keys the hardware did not confirm; and choosing the fork identity (Task 11 Step 1), which is the user's to make. Task 11's later steps consume that choice through the `FORK_*` variables set there, so its commands stay literal.

**Type consistency.** `CPUTemperaturePlatform.intel` is introduced in Task 3 Step 4 and used with that spelling in Tasks 3 and 4. `isGPUTemperatureKey(_:platform:)` is defined in Task 3 Step 7 and called with that exact signature at all four sites in Task 4. `systemPowerKeys`/`adapterPowerKeys` are renamed from the singular forms in Task 5 Step 2 and consumed under the new names in Step 3. `SystemMonitor` passes `cpuTemperaturePlatform`; `FanControlHardware` passes `temperaturePlatform` — these are the existing property names in each file and are not interchangeable. In Stage 7, `FORK_ID` set in Task 11 Step 1 is the same value consumed by Task 11 Step 6's `git mv` and by Task 12's endpoint work.

**Known coupling.** Task 11 Step 3 (Team ID) and Task 13 Step 5 (signing) are the same decision seen twice: no Apple Developer Program membership means no real Team ID, which means fan control's XPC authentication cannot be satisfied honestly and the feature ships disabled. Both steps say so; if one changes, change the other.
