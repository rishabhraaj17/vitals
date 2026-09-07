# Spec: Intel Mac support for Vorssaint (private fork)

**Date:** 2026-09-06
**Status:** Approved for planning
**Target machine:** MacBook Pro 2019, Intel Core i7-9750H, macOS 26.6.1, Swift 6.3.3 (Command Line Tools), macOS SDK 26.5

---

## 1. Problem

Vorssaint ships as an Apple Silicon–only menu bar app (`README.md:208`, badge at
`README.md:29`, `CONTRIBUTING.md:20`). The owner of this fork runs a 2019 Intel
MacBook Pro and wants the app working on that machine.

Upstream has **explicitly declined Intel support** (`CONTRIBUTING.md:142`, in the
list of scope refusals alongside third-party integrations and a plugin system).
This work is therefore a **permanent private fork**. Nothing produced here is
ever pushed to the upstream remote.

## 2. Findings from source audit

The codebase is far more portable than its documentation claims.

**No architectural blockers exist.** There is no IOReport usage, no arm64
intrinsics or inline assembly, no Apple-Silicon-only framework, no
`hw.optional.arm64` gating. `AppUpdatesService.swift:435` already emits
`x86_64` correctly under `#if arch(arm64)/#else` for Sparkle feed filtering.

**One build blocker.** `build.sh:62` hardcodes `TARGET="arm64-apple-macosx14.0"`,
consumed at five `swiftc` invocations (lines 254, 448, 454, 460, 471).

**Three functional gaps**, all in SMC sensor key selection:

| Gap | Location | Effect on Intel |
|---|---|---|
| CPU temp keys | `TemperatureSensorSelector.isCPUTemperatureKey` accepts only `Tp*`/`Te*` (`:127`) | Intel's `TC0P`/`TC0D`/`TCXC` never collected → CPU temperature blank |
| GPU temp keys | `hasPrefix("Tg")` at `SystemMonitor.swift:905,919` and `FanControlHardware.swift:316,323` | Intel's `TG0P`/`TG0D` never collected → GPU temperature blank |
| Power keys | `PowerSampler` reads only `PSTR`/`PDTR` (`:51-53`) | Apple Silicon key names; degrades to `nil` (no crash), power gauge blank |

**Working unchanged on Intel:**

- `SMCClient` — the AppleSMC user-client ABI is Intel-origin.
- Fan discovery and control — `FNum`, `F<i>Ac`, `F<i>Mn`, `F<i>Mx`, `F<i>Tg`,
  `F<i>Md`/`F<i>md` (`FanControlHardware.swift:246-280`) are the classic Intel
  SMC key set used by smcFanControl and Macs Fan Control for fifteen years.
  **Zero code changes required — verification only.**
- Battery temperature — regex `^TB[0-9]T$` matches Intel's `TB0T`/`TB1T`/`TB2T`.
- GPU usage via IOAccelerator (`SystemMonitor.swift:1022` even references Intel
  dual graphics).
- All HID, audio, window management, clipboard, and UI code.

## 3. Safety analysis

Established before planning, because it determines the staging order.

**No hardware corruption risk.** No firmware, NVRAM, EFI, kext, or `diskutil`
operations exist anywhere in `Sources/`. The only hardware writes are SMC fan
keys, called from exactly one file (`FanControlHardware.swift`), and they are
bounded:

- Writes target keys resolved by literal name, never by index scan.
- `SMCClient.writeBytes` rejects `bytes.count != key.dataSize`, size capped at 32
  — the fixed-layout `SMCParamStruct` cannot be overrun.
- `FanControlPolicy.coolingTargetRPM` interpolates strictly between the fan's own
  hardware-reported `F<i>Mn` and `F<i>Mx`; `validBounds` rejects non-finite or
  insane values.
- `FanControlPolicy.restoreReason` is a watchdog restoring automatic mode on time
  limit, lost heartbeat (app crash), verification failure, **temperature sensors
  unavailable**, or `ProcessInfo` thermal state serious/critical.

The temperature gap in §2 is therefore **fail-safe**: with no matching CPU keys,
curve mode trips `temperatureFailures` → `.temperatureUnavailable` → restores
automatic cooling.

**One privileged component.** `Sources/FanControlHelper` runs as a root
LaunchDaemon via SMAppService (`Resources/com.vorssaint.utils.fan-control.plist`),
refusing to start unless `geteuid() == 0` (`main.swift:592`). It is opt-in,
installed only when fan control is enabled.

**Real risks, all software-level and reversible:**

1. Orphaned TCC grants — macOS ties Accessibility and Screen Recording to the
   binary hash. An ad-hoc signature orphans grants while System Settings still
   shows them granted. Recovery: `tccutil reset Accessibility com.vorssaint.utils`.
2. Cleaner and Uninstaller delete files (94 deletion call sites, mostly
   `~/Library`). **Unchanged by this work** — same risk any user of the app takes.
3. Untested Intel code paths → app crashes, contained by the process boundary.

## 4. Requirements

**R1.** `./build.sh` produces a running app on x86_64 without breaking the arm64
build. The change must be architecture-agnostic, not an "Intel fork" of the
build script.

**R2.** CPU temperature reads correctly on Intel, preferring per-core PECI
sensors and falling back to proximity/die.

**R3.** GPU temperature reads correctly on Intel.

**R4.** Apple Silicon behaviour is **byte-identical** after every change. Every
existing assertion in `Tests/MetricsTests.swift` must still pass.

**R5.** Sensor key sets are derived from a **read-only dump of the actual
machine**, not from guesswork. No key is added to the source that the dump did
not confirm present.

**R6.** Power readings resolve from a candidate list so absent keys degrade to
`nil` rather than showing a wrong number.

**R7.** Work proceeds in ascending risk order. No SMC write occurs until every
read-only path is verified.

**R8.** Nothing is ever pushed to the upstream remote.

## 5. Non-goals

- Universal binary / `lipo`. Single-arch native build is sufficient.
- Notarization and DMG distribution. This build never leaves the machine.
- Upstreaming. Declined by upstream; not attempted.
- Fixing Intel-specific bugs in features unrelated to architecture.
- Docker. See §7.

## 6. Design decisions

**D1 — `.intel` as a first-class platform case, not a widened `.generic`.**
`.generic` currently means "unknown, take the hottest plausible sensor".
Widening it would change Apple Silicon fallback behaviour and violate R4. A new
`case intel` in `CPUTemperaturePlatform` keeps every existing branch untouched.

**D2 — Explicit key allowlists, not prefix matching.** The file already models
Apple Silicon as explicit `Set<String>` per generation. Matching that style
avoids a real bug: Intel's `TCGC` (PECI **GPU**) starts with `TC` and a
`hasPrefix("TC")` rule would silently report GPU temperature as CPU temperature.

**D3 — `hasCPUCoreSet(.intel) == false`.** This routes non-core `TC*` keys into
`fallbackCPUKeys` (`SystemMonitor.swift:915-918`), so a machine without per-core
PECI sensors still shows proximity/die temperature instead of nothing.

**D4 — Shared `isGPUTemperatureKey` helper.** Four call sites currently inline
`hasPrefix("Tg")`. A single selector method keeps CPU and GPU classification in
one file and prevents the four sites drifting apart.

**D5 — `TARGET="$(uname -m)-apple-macosx14.0"`.** One line, correct on both
architectures, no branching.

**D6 — Candidate-list key resolution in `PowerSampler`.** Generalizes the
existing single-key lookup; correct regardless of which keys the dump finds.

## 7. Execution environment

The user's standing instruction is that experiments run strictly inside Docker.
**This is not achievable for the build**, and the constraint is waived by
necessity, not by preference:

- Docker on macOS is a Linux VM (`docker info` → `linux/x86_64`). Building
  requires `swiftc` against the macOS SDK, AppKit, IOKit, `codesign`, and
  `actool` — none exist in a Linux container, and Apple's SDK is not licensed
  for one. There is no macOS-in-Docker path.
- Even a hypothetical container build could not be *run*: the app requires
  `AppleSMC`, `IOHIDEventSystem`, and the window server.
- The target hardware *is* the development machine, so the build must be native
  regardless.

Mitigation: isolation is achieved through the staging ladder in §8 and by
keeping the app out of `/Applications` until Stage 4, rather than through
containerization.

## 8. Risk staging ladder

Each stage is independently verifiable and independently abandonable. A stage
begins only when the previous stage's exit criteria are met.

| Stage | Content | Writes? | Privilege | Worst case |
|---|---|---|---|---|
| 0 | Read-only SMC key dump | none | user | none |
| 1 | Build + boot, run from `build/` | none | user | app crash |
| 2 | Intel CPU/GPU temperature sensors | none | user | wrong number shown |
| 3 | Intel power sensors | none | user | blank gauge |
| 4 | Signed install to `/Applications`, TCC-gated features | disk | user | orphaned TCC grants |
| 5 | Fan telemetry (read `F<i>Ac`) | none | user | wrong RPM shown |
| 6 | Fan control | **SMC** | **root** | fans wrong until quit; SMC reset clears |

Stage 6 is entered only with explicit confirmation, on AC power, with Activity
Monitor open, and with an abort procedure rehearsed.

## 9. Acceptance

- `./build.sh --test` passes with zero failures, before and after every task.
- The app launches on the 2019 Intel MacBook Pro and shows a menu bar icon.
- CPU and GPU temperatures display plausible values matching an independent
  reference reading.
- No file under `Sources/` contains a key the Stage 0 dump did not confirm.
- `git remote -v` push targets are never invoked.
