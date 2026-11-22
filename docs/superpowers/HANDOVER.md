# Vitals — handover

Written 2026-09-08. Read this first if you are picking the project up cold.

Vitals is a private fork of [Vorssaint](https://github.com/vorssaint/vorssaint-utils)
that adds Intel Mac support, which upstream has declined
(`CONTRIBUTING.md:142` lists it among refused scope). It is renamed so it can be
distributed lawfully under upstream's `TRADEMARKS.md`.

**Status: complete and working.** The app is built, installed, and reading real
sensors on a 2019 Intel MacBook Pro. Nothing is left half-done.

---

## 1. Resume in 30 seconds

| | |
|---|---|
| Branch | `intel-port`, 16 commits, base `43ef5e9` |
| Pushed to | `publish` = `git@github.com:rishabhraaj17/vitals.git` |
| `main` | **not merged yet** — deliberately held |
| Installed | `/Applications/Vitals.app` |
| Tests | `./build.sh --test` → **10670 checks** |

```bash
./build.sh --test          # ~3 min
./build.sh                 # ~20 min, builds to build/stage/Vitals.app
./build.sh --install       # rebuilds, installs to /Applications
./Tools/uninstall.sh       # removes Vitals only
```

The merge that was pending:

```bash
git checkout main && git merge intel-port && git push publish main
```

---

## 2. Hard rules

1. **Never push to `origin`.** It is upstream. Its push URL is deliberately set
   to `DISABLED`, so a push fails closed. Push only to `publish`. Restore with
   `git remote set-url --push origin <url>` if you ever genuinely need to.
2. **Never weaken a code-signing requirement to make fan control work.** The
   requirement is what authenticates callers to a daemon running as root.
   Relaxing it is a privilege-escalation hole, not a feature. See §5.
3. **Never add a sensor key the hardware has not confirmed.** Dump first
   (§4). Guessed keys were wrong four times in this project.
4. **Do not touch a co-installed upstream Vorssaint.** It is a separate product
   from a different developer, not an older version of this one. Getting this
   wrong shipped two real bugs; see §6.
5. **Keep every `SPDX-License-Identifier` and `Copyright (C) 2026 Vorssaint`
   header.** They record upstream's authorship; removing them breaches GPL-3.0.
   Add a second copyright line if you like — never replace theirs.

---

## 3. The machine this was built for

```
MacBookPro16,1 · Intel Core i7-9750H (6 cores) · macOS 26.6.1
Swift 6.3.3 (Command Line Tools, no Xcode.app) · macOS SDK 26.5
```

`actool` is absent (needs Xcode 26+), so the adaptive icon step is skipped and
the Dock falls back to the generated `AppIcon.icns`. `build.sh` handles that
gracefully.

Under sustained compile: CPU 80–86 °C, **both fans pegged at maximum**
(fan 0 ~5300 rpm against a 5297 max, fan 1 ~4903 against 4905). Thermal headroom
is fully consumed during builds. Idle sits around 50–58 °C.

---

## 4. Sensor facts, measured not assumed

Full capture: `docs/superpowers/intel-smc-keys.txt` (146 keys).
Regenerate on any Intel Mac:

```bash
swiftc -Onone -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Sources/Vitals/Services/SystemMonitor/SMCClient.swift \
  Sources/Vitals/Services/FanControl/FanControlSupport.swift \
  Sources/Vitals/Services/Metrics/TemperatureSensorSelector.swift \
  Tools/DumpSMCKeys.swift -o build/dump-smc-keys
./build/dump-smc-keys
```

That command needs **four** files. `SMCClient.swift` calls `SMCValueCodec`
(in `FanControlSupport.swift`), which needs `TemperatureSensorSelector.swift`.
An earlier claim that it compiled standalone was wrong.

### Keys in use (`TemperatureSensorSelector.swift`)

```
intelCPUCoreKeys       TC1C TC2C TC3C TC4C TC5C TC6C TC7C TC8C
intelCPUAuxiliaryKeys  TC0P TC0E TC0F TCXC TCSA
intelGPUKeys           TG0P TG1P
```

### Keys deliberately excluded — do not re-add

| Key | Why |
|---|---|
| `TCGC` | PECI **GPU** sensor despite the `TC` prefix. A `hasPrefix("TC")` rule would report GPU heat as CPU. This is why the tables are explicit allowlists. |
| `TC0T` | reads 0.18 — not a temperature |
| `TCMX` | max-of-cores summary, not a sensor |
| `TGDT` | reads 0.13 — not a temperature |
| `TGDD`, `TGDF` | read 82 °C while Apple's `powermetrics` reported GPU die 64 °C, and track the **CPU package** within 1.5 °C |
| `TGVF`, `TGVP` | voltage-regulator temps, not the GPU |
| `TGDE` | value happens to match Apple's, meaning unverified — excluded on principle |

`TC0C`, `TC9C`, `TC0D`, `TC0H`, `TCXc`, `TCSC`, `TG0D`, `TG1D` **do not exist**
on this hardware, though documented convention suggested they would.

### Cross-checking against Apple

```bash
sudo powermetrics --samplers smc -i1 -n1 | grep -A8 "SMC sensors"
```

Compare fan rpm first to confirm both readings describe the same thermal moment.
Apple's "CPU die temperature" == `TC0F`. The app instead shows the hottest
per-core PECI value, ~3 °C lower — a deliberate product choice, not a bug.

`TG0P` lands within ~1 °C of Apple's GPU die figure.

---

## 5. Fan control is off, by three independent mechanisms

Do not "fix" this. It is intended.

1. `FanControlIdentifiers.teamID = ""`. Upstream's value was the maintainer's
   Apple Team ID. This fork is self-signed and has no Apple Developer Program
   membership, so the helper's mutual code requirement can never be satisfied.
2. Verified to **fail closed**, empirically. `certificate leaf[subject.OU] = ""`
   compiles to `matchEqual` with a zero-length value, **not** `matchExists` —
   confirmed by diffing compiled requirement blobs and testing the requirement
   against Chrome, VLC, Safari and Calculator (all rejected). `anchor apple
   generic` independently excludes self-signed code.
3. `FanControlService` refuses to `register()` when `teamID` is empty. Without
   this guard, enabling fan control would register a root LaunchDaemon that the
   app could **never** unregister, because unregistration only runs after a
   successful XPC round-trip that can never happen.

If you ever obtain a real Apple Team ID, setting it re-enables everything with
no other change.

---

## 6. Two bugs caused by treating upstream as "our past self"

Both were caught by the final review, both are fixed, and the pattern is worth
remembering because it is easy to repeat.

- **`Tools/uninstall.sh`** had `LEGACY_APP="/Applications/Vorssaint.app"`.
  Upstream used that slot for its own *pre-rename* name — same product, same
  bundle id. After a fork it names **a different vendor's live app**. As written
  it would `rm -rf` their app, and if Vitals were already gone, execute *their*
  binary with `--uninstall`. Upstream is now removed from that script entirely.
- **`ShellSupport.swift`** listed `/etc/sudoers.d/vorssaint-clamshell` as a
  "legacy" path to `rm -f`. It is upstream's **current** path. Enabling
  closed-lid mode in Vitals would have silently broken it in a co-installed
  Vorssaint. `legacyRulePaths` is now empty — this fork has only ever written
  `vitals-clamshell`.
- **`build.sh --install`** (found 2026-11-22, present since the fork began)
  stopped and `rm -rf`'d `/Applications/Vorss.app` and `Vorssaint Utils.app`,
  upstream's pre-rename names. Same mistake, third instance. The loop is gone and
  `Tests/DeveloperInstallIsolationTests.sh` now asserts all three upstream names
  (incl. `Vorssaint.app`) survive both installs. `BundleMigration.swift` looks
  similar but is safe: it only trashes a bundle carrying *our* bundle id.

The codebase already encoded the right instinct in
`CleanerSupport.isProtectedBundleID` and `DockClickSupport.isOwnBundleIdentifier`,
which keep **both** the old and new identifiers so the fork never touches an
upstream install. Preserve that.

---

## 7. Identity, and what must stay renamed

```
App / executable   Vitals
Bundle id          com.rishabhraaj17.vitals   (dev: …​.vitals.dev)
Signing identity   Vitals Signing
Repo               rishabhraaj17/vitals
Icon               Tools/MakeBrand.swift → Resources/Brand/{AppIcon-Default,logo}.png
```

`TRADEMARKS.md` requires a different name, icon, bundle id, signing identity and
update feed for any redistributed **build**. Publishing source is not
distributing a build; attaching a release is.

Non-obvious places the bundle id is load-bearing, not cosmetic:
`CleanerSupport.isProtectedBundleID`, `DockClickSupport.isOwnBundleIdentifier`,
`FanControlXPC`, `UpdateInstallerSupport`'s codesign requirement, the fan-helper
plist **filename**, and ~12 assertions in `Tests/MetricsTests.swift` including
one that loads that plist by literal path.

Icon regeneration:

```bash
swift Tools/MakeBrand.swift Resources/Brand
swift Tools/MakeIcon.swift /tmp/iconset   # to preview
```

The menu bar glyph is sized from a fixed 12.5 pt height into a 26 pt canvas, so
the trimmed mark must stay under ~2:1 or it overflows. Current mark is ~1.87:1.

---

## 8. Network: nothing reaches upstream

- **Self-update** → `UpdateServiceSupport.updateRepository = "rishabhraaj17/vitals"`,
  pinned by a test asserting it never contains `vorssaint`. Previously it pointed
  at upstream, which ships **arm64 only** — and upstream's notarized DMG would
  have *passed* the installer's verification, replacing this Intel build with an
  executable that cannot run.
- **Feedback** → `FeedbackService.submit()` throws `.unavailable` as its first
  statement.
- **Screenshot / recording sharing** → throw `.unavailable` when the endpoint
  still equals the default sentinel, which it always does in a release build.
- **Showcase media** → `remoteMediaURL` is `nil`; no `URLSession` is constructed.

The fork has **zero releases**, so the update check finds nothing.

---

## 9. Battery notes (this machine)

Battery replaced ~2026-08. At the time of writing: 23 cycles, `Condition: Normal`.

Health reads **97.9%** = full-charge 8616 mAh ÷ design 8790 mAh. That looked low,
but `Qmax` (the gauge's *measured* cell capacity) is ~9265 mAh — **above** design.
The low figure is an uncalibrated gauge on a battery that mostly lives on AC, not
degradation. It drifted 8606 → 8616 mAh within minutes, i.e. relearning upward.
macOS does not display a health percentage on Intel at all; `MaxCapacityProbe`
looks for Apple's own figure, finds none, and falls back to the ratio by design.

**Charge percentage** must come from `BatteryData.UISoc`, not
`CurrentCapacity / MaxCapacity`. On Apple Silicon those are already a percentage
and 100, so the ratio is a no-op. On Intel they are **milliamp-hours**, and the
ratio reads ~1% below what macOS shows (8529/8616 → 99% where macOS said 100%).
Fixed in `BatteryTimeSupport.chargePercent(uiSoc:capacity:maxCapacity:)`.

There is **no 80% charge limit** on Intel — the SMC exposes no `ChargeLimit`,
`AppleChargeLimit` or `OptimizedBatteryCharging` field. Adding one would require
SMC **writes**, reopening the path §5 closes. Use AlDente or Battery Toolkit
instead. Longevity here is thermally limited, not cycle limited.

---

## 10. Deferred — known, none blocking

| Item | Detail |
|---|---|
| Dead feedback UI | `FeedbackView` still presents the form; `submit()` always throws, so the user gets an error after typing |
| Update check UX | a repo with zero releases 404s → state becomes `.failed("-")` rather than "up to date" |
| `release.yml` | still written for upstream; **inert** (gated on `github.repository == 'vorssaint/vorssaint-utils'`). Needs real work before any release |
| M3 comment | a comment claims Apple Silicon behaviour is byte-identical; true except on M3, where the diagnostics now also enumerate `Tf*` keys. The behaviour change is an improvement; the comment is wrong |

---

## 11. If you publish releases later

Attaching a release means distributing a build, which activates the full
`TRADEMARKS.md` obligation set (already satisfied — see §7) **plus**:

- Gatekeeper: builds are self-signed and **not notarized**. Users will need
  right-click → Open. Notarization needs an Apple Developer Program membership
  ($99/yr) — the same membership that would re-enable fan control.
- `release.yml` needs rewriting (§10).
- The README must keep its no-guarantees language. GPL §15–16 disclaim warranty,
  and that protection depends on not contradicting it anywhere.

Recommended alternative, if the goal is just to share the work: publish a
**patch set** rather than binaries. `Tools/make-patch.sh` is specified in the
plan (§12) but was not built — it was superseded when the full rename happened.

---

## 12. Where the rest of the detail lives

| Path | Contents |
|---|---|
| `docs/superpowers/specs/2026-09-06-intel-mac-support.md` | requirements, design decisions, risk staging |
| `docs/superpowers/plans/2026-09-06-intel-mac-support.md` | the 13-task plan, incl. an unbuilt Stage 7 for publishing |
| `docs/superpowers/intel-smc-keys.txt` | the raw sensor capture |
| `.superpowers/sdd/2026-09-06-intel-mac-support/progress.md` | full ledger: every ruling, deferred item and fix round (git-ignored, local only) |

Note the ledger is **not** committed — it is under a git-ignored path. Copy it
somewhere durable if you want the decision history to survive this machine.

---

## 13. Lessons that changed what shipped

- **My planned sensor keys were wrong four times** (`TC0C`, `TG0D`, `TG1D`,
  and half the auxiliary set). Only dumping the real hardware caught it.
- **`TGDD` was 18 °C off.** The dump alone could not catch that — only the
  `powermetrics` cross-check could, because the key existed and returned a
  plausible-looking number.
- **`uname -m` was the wrong source of truth** — it reports the calling
  *process's* architecture and answers `x86_64` under Rosetta. Replaced with
  `sysctl -n hw.optional.arm64`.
- **A subagent reported a grep it had not run**, claiming 4 matches where there
  were 8. Re-running verification independently is not paranoia.
- **The plan under-counted call sites** because a preflight grep was scoped to
  two files. `Sources/Vitals/Support/SelfTest.swift` was never surveyed.
