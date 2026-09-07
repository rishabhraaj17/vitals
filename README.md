# Vitals

**Vitals is unofficial software provided with no guarantees of any kind. Use it at your own risk.**

Vitals is a fork of [Vorssaint](https://github.com/vorssaint/vorssaint-utils) (© 2026 Vorssaint, GPL-3.0-or-later) adding support for Intel Macs, which upstream does not support. It is not affiliated with, endorsed by, or supported by the Vorssaint maintainer. Please do not report Vitals issues to them.

## What changed from upstream

- **Intel Mac support.** build.sh now derives its build target from the machine actually doing the build instead of a hardcoded `arm64-apple-macosx14.0`, so an Intel Mac builds and runs its own `x86_64-apple-macosx14.0` binary and test harness. The system-monitor code reads CPU and GPU temperatures through Intel SMC sensor keys in addition to the Apple Silicon sensors upstream already supported.
- **Self-update points at this fork.** The updater's code-signing verification is pinned to this fork's own bundle identifier rather than upstream's.
- **Upstream's sharing and feedback services are disabled.** Screenshot sharing, screen-recording sharing and in-app feedback all called upstream's own hosted infrastructure. This fork runs none of that, so those features report "unavailable" instead of silently calling someone else's server.
- **Rebuilt identity.** New app name, bundle identifiers, signing identity and update feed, per upstream's own [TRADEMARKS.md](TRADEMARKS.md), which requires exactly this before anyone redistributes a build under a different name.

Everything else — the menu bar utilities, the Cleaner, the window switcher, and so on — is upstream's work, unchanged in behavior.

## Requirements

- macOS 14 or later
- An Intel Mac (Apple Silicon also builds and runs, unchanged from upstream)
- Xcode Command Line Tools

## Building

```sh
./build.sh --test      # run the test suite first
./build.sh              # build the app into build/
./build.sh --install    # build and install into /Applications
```

`./build.sh --dev` builds a separate "Vitals (Developer)" variant with its own bundle id, so it can run alongside an installed release build without clobbering its settings or permissions.

## Signing and Gatekeeper

Builds from this repository are self-signed, not notarized by Apple. macOS Gatekeeper will warn that the app is from an unidentified developer the first time you open it. Right-click (or Control-click) the app and choose **Open** to run it anyway. This is expected for a fork with no Apple Developer Program membership, and it does not mean the app is unsafe or safe — see the disclaimer above.

## Fan control is unavailable

Upstream's protected fan-control channel authenticates the app to a root-owned LaunchDaemon by checking the caller's Apple Developer Program Team ID. This fork has no Apple Developer Program membership, so it has no team ID to present, and the fan-control code deliberately leaves that check unsatisfiable rather than weakening it. Fan control stays unavailable in this fork; that is intentional, not a bug, and it will not change until this fork has a real team ID to authenticate with.

## License

Vitals is distributed under the GNU General Public License v3.0 or later, the same license as upstream Vorssaint. See [LICENSE](LICENSE) for the full text.

The Vorssaint name, app icon and other Vorssaint branding are **not** covered by that license and are **not** redistributed here — see [TRADEMARKS.md](TRADEMARKS.md). This fork ships its own name, icon and identity instead.

This program comes with ABSOLUTELY NO WARRANTY, to the extent permitted by applicable law.
