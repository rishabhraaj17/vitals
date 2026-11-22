# SDD ledger — plan: docs/superpowers/plans/2026-09-06-intel-mac-support.md

Spec: docs/superpowers/specs/2026-09-06-intel-mac-support.md (read)
Branch: intel-port (created from main @ 43ef5e9)
Execution mode: Option B (user runs all verification) + subagent-driven

## Preflight conflict scan

Pairs sharing a file or interface:

| Tasks | Produces / consumes | Finding |
|---|---|---|
| 1 → 3 | intel-smc-keys.txt (TC*/TG* rows) → key tables | OK. Hard dependency; Task 3 cannot start before user supplies dump. |
| 1 → 5 | intel-smc-keys.txt (P* rows) → power candidates | OK. |
| 1 → 7 | intel-smc-keys.txt (F* rows) → fan verify | OK. |
| 1 ↔ 2 | dump tool compile vs build.sh TARGET | OK. Task 1 compiles with its own `$(uname -m)`; independent of build.sh. |
| 3 → 4 | isGPUTemperatureKey(_:platform:) → 4 call sites | OK. Signature matches; no file overlap (3 = selector+tests, 4 = SystemMonitor+FanControlHardware). |
| 3 ↔ 11 | both edit Tests/MetricsTests.swift | OK. Different regions (~1798/1914 vs 12 identifier assertions), sequential. |
| 6 → 11 | TCC grants on com.vorssaint.utils vs bundle-ID rename | CONFLICT. See R4. |
| 11 ↔ 12 | ScreenshotSharingSupport.swift:43 vs :42 | CONFLICT (line drift). See R5. |
| 11 → 12 | AppInfo URLs (T11) vs endpoint grep expecting 8 (T12 Step 1) | OK. T12 Step 1 already says AppInfo is "handled in Task 11". |
| 7 → 8 | fan bounds/telemetry → fan control | CONFLICT. See R3. |

Self-consistency per task: Tasks 1-5, 9-10, 12-13 agree with themselves (tests
specified match code specified; files created match files later touched).
Task 8 does not — see R3. Task 11 under-specifies TCC re-grant — see R4.

## Rulings

Ruling R1 (execution mode): implementers write code and commit, but never run
./build.sh, the app, or any hardware check — the user runs all verification per
Option B. Implementers still commit so review-package works on commit ranges.
Cost if wrong: a commit may briefly hold unverified code on a never-pushed
private branch; failed verification becomes a fix round.

Ruling R2 (workspace): branch `intel-port` in the main working directory rather
than a git worktree. The user must build, install to /Applications, and
hardware-test; plan commands assume repo root. Cost if wrong: working dir is
dirty during the port; `git checkout main` restores it.

Ruling R3 (Task 8 unreachable): fan control CANNOT be enabled on this build, and
this is verified, not predicted. FanControlHelper/main.swift:600 sets
setConnectionCodeSigningRequirement(appCodeRequirement); FanControlService.swift:247,335
set the mirror requirement on the helper. Both requirements are
`anchor apple generic and certificate leaf[subject.OU] = "3D485NHW29" and identifier ...`
(FanControlXPC.swift:18-21). Tools/setup-signing.sh:50 builds an
`openssl req -x509` self-signed cert, which cannot satisfy `anchor apple generic`,
and 3D485NHW29 is the upstream maintainer's team. Task 8 is therefore reframed:
verify the connection is refused, document it, leave fan control off. The
requirement is NOT to be weakened — that would strip authentication from a root
daemon. Cost if wrong: if the XPC somehow connects, we skipped a verification we
could have run; recoverable by executing Task 8 as originally written.
Consequence: Stage 6, the only stage that writes to hardware, is unreachable —
the risk profile improves.

Ruling R4 (TCC orphaning): Task 6 grants Accessibility/Screen Recording to
com.vorssaint.utils; Task 11 changes the bundle ID, silently orphaning them, and
the Rollback table's `tccutil reset ... com.vorssaint.utils` becomes wrong. Task
11's dispatch carries an added step: re-grant under the new ID and update the
Rollback commands. Cost if wrong: user re-grants permissions manually once.

Ruling R5 (line drift): Task 11 edits ScreenshotSharingSupport.swift:43 and Task
12 edits :42 in the same file. Task 12's dispatch must locate edits by symbol
name (productionEndpoint), never by line number. Cost if wrong: an implementer
edits the wrong line and the reviewer catches it.

## Progress

Task 1: dispatched (haiku, implementer) — BASE 43ef5e9. Code-only per R1;
user runs swiftc + dump. Brief carries 3 overrides: no build/run, no
intel-smc-keys.txt fabrication, narrowed commit scope + message.
Task 1: implementer DONE (commit e50b31e). Review package
review-43ef5e9..e50b31e.diff generated; task reviewer dispatched (sonnet),
briefed to treat the two planning docs as non-implementation and to act as
first compile check since nothing has been built yet.
Task 1: complete (commits 43ef5e9..e50b31e, review clean — spec OK, quality
approved, zero findings; reviewer confirmed byte-identical to brief, all
SMCClient signatures verified, no write calls).
Task 2: dispatched (haiku) — BASE e50b31e. One-line build.sh:62 edit only.
Note: plan Step 1 (observe pre-fix arm64 run failure) is user-run diagnostic
evidence only, not load-bearing; landing the fix first does not block anything.
Task 2: implementer DONE (commit 094703c) — build.sh:62 now
TARGET="$(uname -m)-apple-macosx14.0" + 3-line why-comment; five $TARGET call
sites untouched (254,448,454,460,471). Reviewer dispatched (sonnet), asked to
reason about uname -m as source of truth rather than accept the plan's choice.

Ruling R6 (Task 2, Rosetta): ACCEPT reviewer finding. `uname -m` reports the
calling process's arch; under a Rosetta shell on Apple Silicon it returns
x86_64, silently cross-compiling an Intel build on ARM and breaking the
"Apple Silicon byte-identical" constraint (upstream hardcoded arm64 there).
Replaced with a hardware check: sysctl -n hw.optional.arm64. Verified on this
machine the OID is absent and exits non-zero, so the guarded comparison falls
to x86_64 correctly. Cost if wrong: 3 extra lines of shell; behaviour on this
Intel Mac is identical either way. Plan doc D5 and Task 2 Steps 2/3/7 updated
to match, so the published artifact does not contradict the code.

Ruling R7 (Task 2, commit message): ACCEPT reviewer finding. Verified history:
0 commits with a bare `build:` type, 2 with `fix(build):` as a scope. The
plan's literal Step 7 message contradicted the plan's own Global Constraint
(type(scope), reuse an existing scope); the constraint is binding. Amended to
`chore(build): derive the swift target from the host architecture`. Cost if
wrong: a rewritten sha on a never-pushed local branch.

Task 2: fix round 1/5 dispatched (resumed original implementer) — 2 findings,
both plan-conflicting, both ruled ACCEPT. Amend into single commit.
Task 2: fix round 1/5 applied (amended commit 094703c -> 5816b70). build.sh now
uses sysctl -n hw.optional.arm64 guard; message corrected to chore(build):;
plan doc Task 2 Steps 2/3/7 resynced. Scoped re-review dispatched (sonnet).
Task 2: fix round 1/5 (2 addressed, 0 open — rosetta guard, commit message;
plan-doc sync confirmed; no new breakage; commits e50b31e..5816b70).
Task 2: complete (commits e50b31e..5816b70, review clean).

Task 2: minor (deferred): plan doc File Structure table (~line 57) still says
TARGET is "derived from `uname -m`" — stale vs the shipped sysctl form.
Task 2: minor (deferred): plan doc ~lines 159 and 1289 show
`-target "$(uname -m)-apple-macosx14.0"` in the standalone DumpSMCKeys compile
snippets (Task 1 tool, not build.sh). Same Rosetta class of issue but for a
throwaway diagnostic; note that Task 10's generated INSTALL.md carries the same
snippet and should be made consistent when that task runs.
-> Both deferred minors must be handed to the final whole-branch review.

Ruling R8 (hoist Task 9 Steps 2-3): ran `git remote set-url --push origin
DISABLED` now rather than in Stage 7. Rationale: origin's push URL pointed at
the upstream project this fork must never push to, and the remaining tasks
create many more commits; the protection is worth more early than late. It is
plan-sanctioned (Task 9 Step 2), local, reversible, and only removes an
outward capability. Verified: push to origin intel-port now fails closed.
Task 9 Steps 4-6 (publish remote, upstream issue, intel-status.md) stay in
Stage 7. Cost if wrong: one command to restore the URL.

## Hardware run (controller-executed, read-only, at user request)

COMPILE FAILURE then FIX. Plan/brief/tool-comment all claimed DumpSMCKeys
"compiles against SMCClient.swift alone". FALSE: SMCClient.swift itself calls
SMCValueCodec (readValue :75, writeValue :91), which lives in
FanControlSupport.swift, which in turn needs TemperatureSensorSelector.swift.
Working command needs THREE sources:
  SMCClient.swift + FanControl/FanControlSupport.swift +
  Metrics/TemperatureSensorSelector.swift + Tools/DumpSMCKeys.swift
Consequence: the tool's duplicated local decoder is now pointless AND its
comment ("Duplicated on purpose to keep this tool dependency-free") is false,
since the real SMCValueCodec is compiled in regardless. See Ruling R9.
Task 1 review did not catch this: my review prompt asked it to verify the APIs
the TOOL uses, not that the given compile command succeeds. Prompt gap, not
reviewer error.

Test baseline: TESTS OK (10648 checks) + PREFERENCE CLEANUP TESTS OK, exit 0.
Task 3 must land exactly 10661.

DUMP RESULTS (docs/superpowers/intel-smc-keys.txt, 146 lines, i7-9750H):

CPU (16 TC keys). Planned core set TC0C..TC9C is WRONG for this machine:
  present + valid: TC1C 86, TC2C 80, TC3C 79, TC4C 78, TC5C 78, TC6C 76
  present but -127 (invalid, auto-filtered by isPlausibleTemperature): TC7C, TC8C
  ABSENT: TC0C, TC9C  <- must be removed from the planned set
  aux present: TC0P 67.00, TC0E 78.53, TC0F 80.42, TCXC 75.48, TCSA 74.00
  aux ABSENT: TC0D, TC0H, TCXc, TCSC  <- must be removed
  MUST EXCLUDE: TC0T 0.18 (not a temperature), TCMX 86.00 (max-summary, not a
  sensor), TCGC 71.00 (PECI GPU — confirms the exact misclassification the
  allowlist design exists to prevent)

GPU (8 TG keys). Planned set TG0P/TG0D/TG1D/TGDD partially wrong:
  present: TG0P 67.00, TG1P 64.12, TGDD 76.00, TGDE 60.00, TGDF 76.88,
           TGVF 59.19, TGVP 59.19
  ABSENT: TG0D, TG1D  <- must be removed
  MUST EXCLUDE: TGDT 0.13 (not a temperature)

FANS: FNum=2, complete key set for both fans (F0/F1 Ac,Md,Mn,Mx,Tg).
  F0 3523 rpm (min 1836 / max 5297), F1 3251 rpm (min 1700 / max 4905),
  F0Md=F1Md=0 (automatic). => Task 7 should pass; no code change needed.

POWER: PSTR 39.49 W and PDTR 50.34 W BOTH PRESENT with plausible watts.
  => Task 5 hits its own Step 1 skip condition. PowerSampler already works
  unmodified on this machine. Task 5 becomes a no-op. See Ruling R10.

BATTERY: TB0T 36.50, TB1T 35.90, TB2T 36.50 => existing ^TB[0-9]T$ regex works.

Ruling R9 (reopen Task 1): the tool's local decoder and its comment
("Duplicated on purpose to keep this tool dependency-free") are both invalid now
that FanControlSupport.swift must be compiled in anyway. Replace the local
decoder with client.readValue(key) — which routes through the real
SMCValueCodec, removes a drift risk, and gains the `ioft` case the copy lacked.
Correct the compile command everywhere it appears, including Task 10's
generated INSTALL.md heredoc, which would otherwise ship a broken command to
anyone following the published patch. Cost if wrong: the tool loses nothing;
worst case is a slightly larger compile line.

Ruling R10 (Task 5 no-op): PSTR 39.49 W and PDTR 50.34 W are both present with
plausible watts, meeting Task 5 Step 1's own documented skip condition.
PowerSampler works unmodified here. Task 5 ships as a recorded skip, not a code
change. Cost if wrong: if a later reading proves implausible, the candidate-list
refactor is still available and is additive.

Ruling R11 (verification): user asked the controller to run verification steps
directly (compile, dump, ./build.sh --test) rather than running them by hand.
Option B still holds for CODE — subagents write it, the user reviews diffs.
Only the running of read-only/local verification moves to me. Stage 4 (install
to /Applications, TCC grants) and Stage 6 (root helper, SMC writes) remain
stop-and-ask regardless. Cost if wrong: user reviews a diff after it landed
rather than before; every commit is local and revertible.

Ruling R12 (Task 2 deferred minors): resolve the File Structure table to
describe the shipped sysctl form. Keep `$(uname -m)` in the standalone
DumpSMCKeys compile snippets — it is a one-off diagnostic the user invokes
interactively, not the build system, and an Apple Silicon user is not the
audience for an Intel port. Closes both Task 2 deferred minors.
Task 1: fix round 1/5 applied (commit 23ef1ec) — local decoder removed, routed
through client.readValue; compile command corrected in Task 1 Step 2 AND in
Task 10's INSTALL.md heredoc; File Structure TARGET row corrected; capture
committed. Controller-verified: 4-file compile succeeds, tool runs, 0 write
calls in source. Closes R9 and both Task 2 deferred minors (R12).
Task 1: complete (commits 43ef5e9..23ef1ec, verified on hardware).
Task 3: dispatched (sonnet) — BASE 23ef1ec. Key tables rewritten from the real
capture; 16 new checks expected (baseline 10648 -> 10664).
Task 3: implementer DONE (commit 6c60041). Controller-verified: ./build.sh
--test => TESTS OK (10664 checks), exactly baseline 10648 + 16 new, all
pre-existing assertions pass (no Apple Silicon regression). Reviewer dispatched.
Task 3: complete (commits 23ef1ec..6c60041, review clean — spec OK, approved,
0 Critical/Important). Reviewer traced every edited method and confirmed Apple
Silicon paths byte-identical; confirmed all 19 table keys appear in the dump and
none of the 8 excluded keys does; confirmed TC7C/TC8C -127 readings are dropped
by isPlausibleTemperature before reaching the max.
Task 3: minor (deferred): no .intel test mixes an implausible core reading with
a valid one (the M4 path has such a test at MetricsTests.swift:1923-1927);
reviewer traced it manually as correct, so coverage gap not defect.
Task 3: minor (deferred): the tables' shared doc comment cites TGVP (a GPU
example) while sitting above all three tables including the CPU ones.
Task 4: dispatched (haiku) — BASE 6c60041. Four call sites, two files.
Task 4: implementer DONE (commit a9a54e3). Controller-verified: tests still
10664, correct 4 sites edited, each file used its own property name.

BUT the implementer's report was FALSE. It claimed "before: 4 occurrences,
after: 0". Actual pre-Task-4 count (git grep at 6c60041) was EIGHT:
SystemMonitor x2, FanControlHardware x2, TemperatureSensorSelector x1 (the
classifier's own body, correctly untouched), and Sources/Vitals/Support/
SelfTest.swift x3 (lines 47, 176, 187) which remain unconverted. Do not trust
this implementer's self-reported verification; the controller re-ran it.

ROOT CAUSE IS MINE: my preflight grep was scoped to
SystemMonitor.swift + FanControl/*.swift only, so the plan asserted "exactly
four" sites and SelfTest.swift was never surveyed at all.

Ruling R13 (Task 4 incomplete — fix, do not park): SelfTest.swift is a real
functional gap on Intel, not cosmetic.
  - SelfTest.swift:47 is the app's own health check; on Intel no Tp/Te/Tg key
    matches, so every Intel run emits a false "no SMC temperature keys" warning
    exactly where a user looks to diagnose sensors.
  - SelfTest.swift:176/187 is SensorDump, reachable as the shipped CLI flag
    `--sensors` (main.swift:15) and the tool CONTRIBUTING.md points at for
    mapping sensors to a new chip. On Intel it prints only battery rows.
  Fix uses the classifier Task 3 already added.
  HAZARD to avoid: converting these to isCPUTemperatureKey alone would REGRESS
  unmappedAppleSilicon, where that function returns false for Tp/Te. The
  replacement must keep the bare Tp/Te prefixes unconditionally and only ADD
  the classifier calls, making it a strict superset on every platform.
  Cost if wrong: a diagnostic path stays Intel-blind; no effect on the menu
  bar display, which Task 4 already fixed.

Ruling R14 (escalate model): fix round 1 goes to sonnet rather than resuming
the haiku implementer. The failure was a false verification report, and the
remaining three sites have three different shapes (two prefix filters and one
classification branch) needing judgment. Cost if wrong: a slightly pricier
dispatch.

Task 4: fix round 1/5 dispatched (sonnet, fresh implementer).
Task 4: fix round 1/5 applied (commit 7cb94bf). Controller-verified (not
trusting the report this time): grep now yields ONLY
TemperatureSensorSelector.swift:173, the classifier's own body. Diff confirms
both SelfTest predicates KEEP bare Tp/Te and ADD classifier calls (strict
superset — no unmappedAppleSilicon regression), site 3 uses cpuPlatform, the
^TB[0-9]T$ battery clause is intact, and currentPlatform() is called once per
function (the assignment was moved up, not duplicated). Tests: 10664, unchanged
as expected (this task adds no assertions). Plan Task 4 counts corrected.
Full app build started in background (>10 min under -O).

## powermetrics cross-check (user-run sudo, controller-analysed)

Conditions matched: powermetrics Fan 5282 rpm vs our F0Ac 5275 rpm at compare time.
powermetrics steady state: CPU die 80.23 (range 79.7-83.0), GPU die 64.00
(range 64-73), Fan ~5280-5320.
Our simultaneous SMC read: TC1C..TC6C max 77.00, TCXC 77.97, TCMX 77.97,
TC0E 78.73, TC0F 80.53, TC0P 70.81, TCSA 73.00, TCGC 73.00;
TG0P 71.25, TG1P 70.00, TGDD 82.00, TGDE 63.00, TGDF 82.22.

FINDING A (CPU, minor): Apple's "CPU die temperature" == TC0F (80.53 vs 80.23,
within 0.3 C). Our display returns the hottest per-core PECI value (77.00),
about 3 C lower. Both are legitimate CPU temperatures; ours is a hottest-core
metric by design. No defect, but the app will read ~3 C below Activity Monitor.

FINDING B (GPU, REAL): TGDD reads 82.00 while Apple reports GPU die 64.00 — an
18 C gap — and TGDD tracks the CPU package (80.53) almost exactly. TGDF 82.22
behaves the same. Whatever TGDD/TGDF are, they are NOT "GPU temperature" as
Apple defines it, and shipping them would make the GPU number wrong by ~18 C.
This is precisely the misclassification class the allowlist exists to prevent —
the dump alone could not catch it, only the cross-check could.
TGDE (63.00) is the closest match to Apple's 64.00, but its meaning is
unverified; adopting it purely because the number matches would repeat the
guesswork the spec forbids.
=> See Ruling R15.

Ruling R15 (GPU key set): USER DECIDED — drop TGDD, do not add TGDE.
intelGPUKeys becomes ["TG0P", "TG1P"], the two proximity sensors whose meaning
is unambiguous. Rationale: TGDD tracks the CPU package (observed three times
independently: 82.00 vs CPU 80.53; 73.00 vs CPU 74.56; and 18 C above Apple's
reported GPU die of 64.00). TGDE matches Apple's number closely but its meaning
is unverified, and adopting a key because its value looks right is the same
guesswork that produced the TC0C and TG0D errors. Accepted consequence: GPU
reads ~7 C above Apple's die figure, a normal proximity-vs-die offset.
Cost if wrong: GPU temperature reads conservative; adding a key later is
additive and cheap.
GPU key correction applied (commit 87dcf3c) per R15. Controller-verified:
./build.sh --test => TESTS OK (10665 checks), exactly the predicted 10664 + 1.
Diff confirms intelGPUKeys is now ["TG0P","TG1P"], the non-Intel branch of
isGPUTemperatureKey is untouched, and the why-comment records the measurement
so nobody re-adds TGDD later. App rebuild started to re-verify --sensors output.
GPU fix verified on hardware: --sensors now lists only TG0P 65.12 and TG1P 63.25
as gpu; TGDD gone. NOTE my predicted ~7 C proximity-vs-die offset was pessimistic
— TG0P 65.12 sits within ~1 C of the 64.00 Apple reported at comparable CPU temp.
The proximity sensors track Apple's GPU die closely. SELFTEST OK.
Task 3/4 chain complete and hardware-verified.

Stage 4 ENTERED at user request ("install it with the battery preset").
Pre-install state: tree clean, /Applications/Vorssaint.app absent, ZERO signing
identities (so build.sh --install will auto-create the local self-signed one in
~/Library/Keychains/vorssaint-signing.keychain-db).
Correction logged: running the app binary for --sensors/--selftest created
~/Library/Preferences/com.vorssaint.utils.plist (239 bytes of the app's own
defaults). No Apple-managed setting touched; MouseAccelerationRecovery
.restorePending() confirmed a no-op (no journal file, returns before creating a
HID client). My earlier "read-only" wording was imprecise about that plist.
Preset: battery = [monitorCPU, monitorMemory, monitorPower] must be chosen by
the user in onboarding; not setting availabilityKeys by hand.
