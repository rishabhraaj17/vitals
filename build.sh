#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds Vitals, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "Vitals (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
        --test-suite=*) TEST=1; TEST_ARGS+=("--suite=${arg#*=}") ;;
        --list-tests) TEST=1; TEST_ARGS+=(--list) ;;
    esac
done

if (( DEV )); then
    APP_NAME="Vitals (Developer)"
    EXECUTABLE="VitalsDeveloper"
    APP_BUNDLE_ID="com.rishabhraaj17.vitals.dev"
    BUILD_VARIANT_FLAGS=(-D VORSSAINT_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="Vitals"
    EXECUTABLE="Vitals"
    APP_BUNDLE_ID="com.rishabhraaj17.vitals"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
# Now Playing is read through /usr/bin/perl loading this library; see
# Sources/NowPlayingAdapter. Staged under Contents/Frameworks, signed on its own.
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libVitalsNowPlaying.dylib"
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
ENTITLEMENTS="Resources/Vorssaint.entitlements"
LEGACY_IDENTITY="Vitals Signing"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# A find-identity listing also names certificates codesign then rejects (an
# expired one fails the build with errSecInternalComponent), and -v excludes
# every self-signed one; ask codesign itself with a throwaway copy of /bin/echo.
legacy_identity_installed() {
    local probe signed=1
    # A locked keychain still lists its identities but cannot sign with them,
    # and this one is locked after every reboot; unlock it before asking.
    security unlock-keychain -p vitals-signing \
        "$HOME/Library/Keychains/vitals-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

# Any build that lands in /Applications needs a stable signature, not just the
# Developer one: macOS ties Accessibility and Screen Recording grants to the
# exact binary hash, so an ad-hoc rebuild orphans them while System Settings
# keeps showing them as granted, and no new prompt ever appears. A plain
# --install strands them under the released bundle id, on the app the user
# actually relies on. When no identity is installed, create the stable local one
# up front instead of falling through to ad-hoc — setup-signing.sh is free,
# offline and idempotent. Gating on the install rather than the variant keeps
# this off CI, where neither ci.yml nor release.yml passes --install.
if (( DEV || INSTALL )) && [[ -z "$(developer_id_identity)" ]] \
    && ! legacy_identity_installed; then
    echo "▸ No signing identity installed; creating the stable local one…"
    if ! ./Tools/setup-signing.sh; then
        echo "  ⚠ Tools/setup-signing.sh failed; signing ad-hoc instead." >&2
        echo "    Accessibility and Screen Recording grants will not survive rebuilds:" >&2
        echo "    System Settings will show them as granted while the app is not trusted." >&2
        echo "    After fixing the identity, clear the stale grant once with:" >&2
        echo "      tccutil reset Accessibility $APP_BUNDLE_ID" >&2
    fi
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        [[ -f "$adapter" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$devid" "$adapter"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif legacy_identity_installed; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$LEGACY_IDENTITY" "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && /usr/bin/codesign --verify --strict "$adapter"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${VITALS_INSTALL_CHILD:-0}" != "1" ]]; then
    VITALS_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
HID_EVENT_SYSTEM_FLAGS=(-I Sources/HIDEventSystem)
CORE_AUDIO_TAP_FLAGS=(-I Sources/CoreAudioTapCompat)
GIF_CODEC_FLAGS=(-I Sources/RecorderGIFCodec)
GIF_CODEC_OBJECTS=(build/objects/recorder-gif-codec/RecorderGIFCodec.o
                   build/objects/recorder-gif-codec/cgif_raw.o)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `PreferenceNamespaceTests` scans every compiled Swift test file against
# these namespaces, which keeps this sweep complete without a second list.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" name attempt
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        for name in "vorss.tests." "com.vorssaint.tests."; do
            rm -f "$preferences"/$name*.plist(N)
        done
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "vorss.tests.*.plist" -o -name "com.vorssaint.tests.*.plist" \
               -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# Standalone automated tests: pure contracts plus isolated disk, subprocess,
# keyboard-data and media fixtures. No application windows or device capture.
mkdir -p build/objects/recorder-gif-codec
xcrun clang -O3 -std=c99 -target "$TARGET" -isysroot "$SDK" \
    -c Sources/RecorderGIFCodec/RecorderGIFCodec.c -o "$GIF_CODEC_OBJECTS[1]"
xcrun clang -O3 -std=c99 -target "$TARGET" -isysroot "$SDK" \
    -c Sources/RecorderGIFCodec/vendor/cgif/cgif_raw.c -o "$GIF_CODEC_OBJECTS[2]"

if (( TEST )); then
    python3 Tests/generate_sources.py
    TEST_OBJECT_DIR="build/objects/tests"
    mkdir -p "$TEST_OBJECT_DIR"
    TEST_SOURCES=(
        Sources/Vitals/Services/Media/MediaSupport.swift
        Sources/Vitals/Core/QuitProtectionSupport.swift
        Sources/Vitals/Core/QuitProtectionStrings.swift
        Sources/Vitals/Core/Defaults.swift
        Sources/Vitals/Core/NotchStrings.swift
        Sources/Vitals/Core/NotchTourStrings.swift
        Sources/Vitals/Core/NotchEditorStrings.swift
        Sources/Vitals/UI/Settings/NotchSettingsTabRow.swift
        Sources/Vitals/Core/NotchActivityStrings.swift
        Sources/Vitals/Services/Notch/NotchTimerSupport.swift
        Sources/Vitals/Services/Notch/NotchAppFullscreen.swift
        Sources/Vitals/Services/Notch/NotchTimerAlert.swift
        Sources/Vitals/UI/Notch/NotchIslandAlert.swift
        Sources/Vitals/Services/Notch/NotchAccessorySupport.swift
        Sources/Vitals/Services/Notch/NotchAccessoryConnectionMonitor.swift
        Sources/Vitals/Services/QuickTools/CameraPreviewSupport.swift
        Sources/Vitals/Core/NotchMusicExtrasStrings.swift
        Sources/Vitals/Core/NotchClipboardSizeStrings.swift
        Sources/Vitals/Services/Notch/NotchLyricsSupport.swift
        Sources/Vitals/Services/Notch/NotchQueueSupport.swift
        Sources/Vitals/Services/Notch/NotchPreferredPlayer.swift
        Sources/Vitals/Core/NotchFilesStrings.swift
        Sources/Vitals/Core/NotchWatchStrings.swift
        Sources/Vitals/Services/Notch/NotchWatchSupport.swift
        Sources/Vitals/Core/NotchMascotStrings.swift
        Sources/Vitals/Services/Notch/NotchMascotSupport.swift
        Sources/Vitals/Services/CommandBar/CommandBarDropletMotion.swift
        Sources/Vitals/Services/Notch/NotchFileToolsSupport.swift
        Sources/Vitals/Services/Notch/NotchDownloadSupport.swift
        Sources/Vitals/Services/Notch/NotchDownloadProgressObserver.swift
        Sources/Vitals/Core/NotchCalendarStrings.swift
        Sources/Vitals/Core/NotchNotificationStrings.swift
        Sources/Vitals/Core/NotchGestureStrings.swift
        Sources/Vitals/Core/NotchAgentStrings.swift
        Sources/Vitals/Core/CodexAccountStrings.swift
        Sources/Vitals/Core/ClaudeAccountStrings.swift
        Sources/Vitals/Services/Notch/NotchAgentSupport.swift
        Sources/Vitals/Core/NotchLockScreenStrings.swift
        Sources/Vitals/Services/Notch/NotchLockScreenSupport.swift
        Sources/Vitals/Services/AgentUsage/AgentUsageModels.swift
        Sources/Vitals/Services/AgentUsage/AgentPricing.swift
        Sources/Vitals/Services/AgentUsage/AgentLogObject.swift
        Sources/Vitals/Services/AgentUsage/AgentLogParser.swift
        Sources/Vitals/Services/AgentUsage/Harness/AgentHarnessReader.swift
        Sources/Vitals/Services/AgentUsage/Harness/ClaudeReader.swift
        Sources/Vitals/Services/AgentUsage/Harness/CodexReader.swift
        Sources/Vitals/Services/AgentUsage/Harness/OpenCodeReader.swift
        Sources/Vitals/Services/AgentUsage/Harness/CopilotReader.swift
        Sources/Vitals/Services/AgentUsage/AgentUsageSummary.swift
        Sources/Vitals/Services/AgentUsage/AgentUsageStore.swift
        Sources/Vitals/Services/AgentUsage/AgentUsageArchive.swift
        Sources/Vitals/Services/AgentUsage/AgentClaudeAppUsage.swift
        Sources/Vitals/Services/AgentUsage/AgentCLIConversation.swift
        Sources/Vitals/Services/AgentUsage/AgentClaudeServer.swift
        Sources/Vitals/Services/AgentUsage/ClaudeAccountProfile.swift
        Sources/Vitals/Services/AgentUsage/AgentCodexServer.swift
        Sources/Vitals/Services/AgentUsage/CodexAccountLimits.swift
        Sources/Vitals/Services/AgentUsage/CodexProfileLimitsService.swift
        Sources/Vitals/Services/AgentUsage/AgentOpenCodeReader.swift
        Sources/Vitals/Services/Notch/NotchGestureSupport.swift
        Sources/Vitals/Services/Notch/NotchSectionPaging.swift
        Sources/Vitals/Services/Notch/NotchSliderEditing.swift
        Sources/Vitals/Services/Notch/NotchNotificationSupport.swift
        Sources/Vitals/Services/Notch/NotchNotificationReaderCore.swift
        Sources/Vitals/Services/Notch/NotchCalendarSupport.swift
        Sources/Vitals/Services/Notch/NotchKeepAwakeSupport.swift
        Sources/Vitals/Services/Notch/NotchSupport.swift
        Sources/Vitals/Services/Notch/NotchAudioLevelSupport.swift
        Sources/Vitals/Services/Notch/NotchVolumeKeyGate.swift
        Sources/Vitals/Services/Notch/NotchMusicSupport.swift
        Sources/Vitals/UI/Notch/NotchDecorativeClock.swift
        Sources/Vitals/Services/Notch/NotchBrowserArtworkSupport.swift
        Sources/Vitals/UI/Notch/NotchEqualizerBars.swift
        Sources/Vitals/UI/Notch/NotchScrollEdgeFade.swift
        Sources/Vitals/UI/Notch/NotchAgentAnimationView.swift
        Sources/Vitals/UI/WindowVisibilityReader.swift
        Sources/Vitals/Services/Notch/NotchMusicAutomationSupport.swift
        Sources/Vitals/Services/Notch/NotchMusicAutomation.swift
        Sources/Vitals/Services/Notch/NotchPlaybackSource.swift
        Sources/Vitals/Services/Notch/NotchPlaybackCommand.swift
        Sources/Vitals/Services/Notch/NotchMusicCommandWriter.swift
        Sources/Vitals/Core/FeatureCatalog.swift
        Sources/Vitals/Core/FeaturePresets.swift
        Sources/Vitals/Core/FeatureHubStrings.swift
        Sources/Vitals/Core/MixerScreenSharingStrings.swift
        Sources/Vitals/Core/ShortcutSettingsStrings.swift
        Sources/Vitals/Core/SwitcherShortcutStrings.swift
        Sources/Vitals/Core/SettingsBackupSupport.swift
        Sources/Vitals/Core/BackupStrings.swift
        Sources/Vitals/Core/SnippetStrings.swift
        Sources/Vitals/Core/AlertSoundStrings.swift
        Sources/Vitals/Core/BrightnessStrings.swift
        Sources/Vitals/Core/MediaImageStrings.swift
        Sources/Vitals/Core/QuickToggleStrings.swift
        Sources/Vitals/Core/ScreenshotStrings.swift
        Sources/Vitals/Core/RecentCaptureStrings.swift
        Sources/Vitals/Core/RecorderStrings.swift
        Sources/Vitals/Core/RecorderShareStrings.swift
        Sources/Vitals/Core/CameraPreviewStrings.swift
        Sources/Vitals/Core/WallpaperStrings.swift
        Sources/Vitals/Services/Wallpaper/WallpaperSupport.swift
        Sources/Vitals/UI/MenuPanel/WallpaperThumbnailView.swift
        Sources/Vitals/Core/ScratchpadStrings.swift
        Sources/Vitals/Core/FinderRenameStrings.swift
        Sources/Vitals/Core/CommandBarStrings.swift
        Sources/Vitals/Core/FeedbackStrings.swift
        Sources/Vitals/Core/RadialMenuStrings.swift
        Sources/Vitals/Core/MenuBarAppearanceStrings.swift
        Sources/Vitals/Core/AppAppearance.swift
        Sources/Vitals/Core/AppearanceStrings.swift
        Sources/Vitals/Core/GeneralSettingsStrings.swift
        Sources/Vitals/Core/SettingsPageStrings.swift
        Sources/Vitals/Core/BatteryTimeStrings.swift
        Sources/Vitals/Core/CPUCoreStrings.swift
        Sources/Vitals/Core/MonitorLayoutStrings.swift
        Sources/Vitals/Core/KeepAwakeStrings.swift
        Sources/Vitals/Core/BluetoothSleepStrings.swift
        Sources/Vitals/Core/PermissionGuideStrings.swift
        Sources/Vitals/Core/FanControlStrings.swift
        Sources/Vitals/Core/ConnectedDevicesStrings.swift
        Sources/Vitals/Services/FanControl/FanControlSupport.swift
        Sources/Vitals/Services/FanControl/FanControlResumeSupport.swift
        Sources/Vitals/Services/Snippets/TextSnippetSupport.swift
        Sources/Vitals/Services/RadialMenu/RadialMenuSupport.swift
        Sources/Vitals/Services/QuickTools/ScratchpadSupport.swift
        Sources/Vitals/Services/QuickTools/ScratchpadStore.swift
        Sources/Vitals/Services/KillProcess/KillProcessSupport.swift
        Sources/Vitals/Services/Recorder/RecorderSupport.swift
        Sources/Vitals/Services/Recorder/RecorderSampleTiming.swift
        Sources/Vitals/Services/Recorder/RecorderWriter.swift
        Sources/Vitals/Services/Recorder/RecorderCaptureEngine.swift
        Sources/Vitals/Core/RecorderExportStrings.swift
        Sources/Vitals/Core/RecorderExportFormatStrings.swift
        Sources/Vitals/Services/Recorder/RecorderComposer.swift
        Sources/Vitals/Services/Recorder/RecorderComposerPlan.swift
        Sources/Vitals/Services/Recorder/RecorderCursorSprite.swift
        Sources/Vitals/Services/Recorder/RecorderTextRenderer.swift
        Sources/Vitals/Services/Recorder/RecorderImageRenderer.swift
        Sources/Vitals/Services/Recorder/RecorderExporter.swift
        Sources/Vitals/Services/Recorder/RecorderGIFClipboard.swift
        Sources/Vitals/Services/Recorder/RecorderGIFWriter.swift
        Sources/Vitals/Services/Recorder/RecorderFastGIFWriter.swift
        Sources/Vitals/Services/Recorder/RecorderGIFWorkspace.swift
        Sources/Vitals/Services/Recorder/RecorderComposition.swift
        Sources/Vitals/Services/Recorder/RecordingSharingSupport.swift
        Sources/Vitals/Services/PrivateFileStore.swift
        Sources/Vitals/Services/Recorder/RecorderTakeStore.swift
        Sources/Vitals/Services/Recorder/RecorderPresetImageStore.swift
        Sources/Vitals/Services/Recorder/RecorderMotion.swift
        Sources/Vitals/Services/Recorder/RecorderPointerTrack.swift
        Sources/Vitals/Services/Recorder/RecorderTypingTrack.swift
        Sources/Vitals/Services/Recorder/RecorderTimeline.swift
        Sources/Vitals/Services/Recorder/RecorderTextOverlay.swift
        Sources/Vitals/Services/Recorder/RecorderImageOverlay.swift
        Sources/Vitals/Services/Recorder/RecorderBlurRegion.swift
        Sources/Vitals/Services/Recorder/RecorderEditDocument.swift
        Sources/Vitals/Core/AppInfo.swift
        Sources/Vitals/Core/GlobalShortcut.swift
        Sources/Vitals/Core/SymbolicHotKeys.swift
        Sources/Vitals/Services/SystemShortcutTakeoverSupport.swift
        Sources/Vitals/Core/Localization.swift
        Sources/Vitals/Core/Localizations/Strings+*.swift
        Sources/Vitals/Core/FeatureStrings.swift
        Sources/Vitals/Core/KillProcessStrings.swift
        Sources/Vitals/Core/PortManagerStrings.swift
        Sources/Vitals/Core/WhatsAppDownloadStrings.swift
        Sources/Vitals/Core/WhatsAppOrganizerStrings.swift
        Sources/Vitals/Core/ReleaseNotes.swift
        Sources/Vitals/Core/ReleaseDigest.swift
        Sources/Vitals/Core/ReleaseChangeAliases.swift
        Sources/Vitals/Core/WhatsNewStrings.swift
        Sources/Vitals/Core/URLCleaning.swift
        Sources/Vitals/Services/URLCleanerLinkMetadata.swift
        Sources/Vitals/Services/GeneralPasteboardAccess.swift
        Sources/Vitals/Services/Clipboard/ClipboardHistoryWrite.swift
        Sources/Vitals/Services/Audio/AirPlayRouteManager.swift
        Sources/Vitals/Services/Audio/MixerRoutingSupport.swift
        Sources/Vitals/Services/Audio/MusicLaunchSupport.swift
        Sources/Vitals/Services/Bluetooth/BluetoothSleepSupport.swift
        Sources/Vitals/UI/MenuPanel/MixerPercentNativeTextField.swift
        Sources/Vitals/UI/MenuPanel/MixerAppDragSource.swift
        Sources/Vitals/Services/Audio/BoostLimiter.swift
        Sources/Vitals/Services/Audio/MixerRender.swift
        Sources/Vitals/Services/Audio/PreciseVolumeRollerSupport.swift
        Sources/Vitals/Services/DockPreview/DockPreviewSupport.swift
        Sources/Vitals/Services/DockPreview/DockAutohideHold.swift
        Sources/Vitals/Services/SpacesOrder/SpacesOrderHold.swift
        Sources/Vitals/Services/Homebrew/HomebrewSupport.swift
        Sources/Vitals/Services/Homebrew/HomebrewEnvironment.swift
        Sources/Vitals/Services/Homebrew/HomebrewManager.swift
        Sources/Vitals/UI/HomebrewOperationStatusView.swift
        Sources/Vitals/Services/AppUpdates/AppUpdatesSupport.swift
        Sources/Vitals/Services/AppUpdates/AppUpdateFeedSupport.swift
        Sources/Vitals/Core/AppUpdateStrings.swift
        Sources/Vitals/Core/DiskImageInstallerStrings.swift
        Sources/Vitals/Services/DiskImageInstaller/DiskImageInstallerSupport.swift
        Sources/Vitals/UI/NonModalAlert.swift
        Sources/Vitals/Services/Clipboard/ClipboardHistorySupport.swift
        Sources/Vitals/Core/ColorValue.swift
        Sources/Vitals/Services/Clipboard/ClipboardAutoClearSupport.swift
        Sources/Vitals/Services/AutoQuit/AutoQuitSupport.swift
        Sources/Vitals/Core/AutoQuitDockAppsStrings.swift
        Sources/Vitals/Services/Shelf/ShelfSupport.swift
        Sources/Vitals/Services/Shelf/ShelfFilePromiseTransfer.swift
        Sources/Vitals/Core/ShelfPromiseDeliveryStrings.swift
        Sources/Vitals/Services/Finder/FinderRenameSupport.swift
        Sources/Vitals/Services/Update/UpdateInstallerSupport.swift
        Sources/Vitals/Services/Update/UpdateServiceSupport.swift
        Sources/Vitals/Services/InstalledApps.swift
        Sources/Vitals/Services/LaunchAtLoginSupport.swift
        Sources/Vitals/UI/Settings/SettingsSearchSupport.swift
        Sources/Vitals/UI/Settings/SettingsSidebarSupport.swift
        Sources/Vitals/UI/Settings/FeatureVisibilitySupport.swift
        Sources/Vitals/UI/Onboarding/WhatsNewSupport.swift
        Sources/Vitals/UI/Settings/SettingsWindow.swift
        Sources/Vitals/Core/SettingsNavigationStrings.swift
        Sources/Vitals/App/MenuBarSpacingSupport.swift
        Sources/Vitals/App/MenuBarAllowanceSupport.swift
        Sources/Vitals/App/ReopenRequestSupport.swift
        Sources/Vitals/App/StatusItemAnchorSupport.swift
        Sources/Vitals/Services/DockClick/DockClickSupport.swift
        Sources/Vitals/Services/Finder/CutPasteProgressSupport.swift
        Sources/Vitals/Services/Finder/CutPastePrivilegeSupport.swift
        Sources/Vitals/Services/Finder/FinderPasteImageSupport.swift
        Sources/Vitals/Services/MiddleClick/MiddleClickSupport.swift
        Sources/Vitals/Services/MouseNavigation/MouseNavigationSupport.swift
        Sources/Vitals/Services/MouseNavigation/MouseNavigationKeys.swift
        Sources/Vitals/Services/MouseButtons/MouseButtonShortcutSupport.swift
        Sources/Vitals/Services/MouseButtons/MouseSpacesGestureSupport.swift
        Sources/Vitals/Services/MouseClickDebounce/MouseClickDebounceSupport.swift
        Sources/Vitals/Services/MouseExceptions/MouseAppExceptionSupport.swift
        Sources/Vitals/Services/MouseExceptions/MouseAppExceptions.swift
        Sources/Vitals/Services/WindowServerSupport.swift
        Sources/Vitals/Services/WindowMaximizerSupport.swift
        Sources/Vitals/Core/MouseButtonStrings.swift
        Sources/Vitals/Core/MouseClickDebounceStrings.swift
        Sources/Vitals/Core/MouseExceptionStrings.swift
        Sources/Vitals/Core/ClipboardIgnoredAppsStrings.swift
        Sources/Vitals/Core/ClipboardRetentionStrings.swift
        Sources/Vitals/Core/WindowLayoutIgnoredAppsStrings.swift
        Sources/Vitals/Services/WindowLayout/WindowLayoutIgnoredApps.swift
        Sources/Vitals/Core/WindowPreviewExclusionStrings.swift
        Sources/Vitals/Core/WindowMaximizerExclusionStrings.swift
        Sources/Vitals/Core/DiskExclusionStrings.swift
        Sources/Vitals/Core/SwitcherAppRulesStrings.swift
        Sources/Vitals/Services/QuickTools/QuickToolsSupport.swift
        Sources/Vitals/Services/CommandBar/CommandBarSupport.swift
        Sources/Vitals/Services/CommandBar/CommandBarPreferences.swift
        Sources/Vitals/Services/CommandBar/CommandBarMath.swift
        Sources/Vitals/Services/CommandBar/CommandBarUnits.swift
        Sources/Vitals/Services/CommandBar/CommandBarColors.swift
        Sources/Vitals/Services/CommandBar/CommandBarEmoji.swift
        Sources/Vitals/Services/CommandBar/CommandBarLinks.swift
        Sources/Vitals/Services/CommandBar/CommandBarDates.swift
        Sources/Vitals/Services/CommandBar/CommandBarRowShortcuts.swift
        Sources/Vitals/Services/CommandBar/CommandBarSystemSettingsSupport.swift
        Sources/Vitals/Services/CommandBar/CommandBarFileSearchSupport.swift
        Sources/Vitals/Services/CommandBar/CommandBarQueryMemory.swift
        Sources/Vitals/Services/SpotlightNamesSupport.swift
        Sources/Vitals/Services/QuickTools/MicMuteSupport.swift
        Sources/Vitals/Services/QuickTools/QuickTogglesSupport.swift
        Sources/Vitals/Services/QuickTools/ScreenshotCapturePolicy.swift
        Sources/Vitals/Services/QuickTools/ScreenshotSupport.swift
        Sources/Vitals/Services/QuickTools/ScreenshotCanvasSupport.swift
        Sources/Vitals/Services/QuickTools/ScreenshotImageImport.swift
        Sources/Vitals/Services/Media/MediaImageProcessing.swift
        Sources/Vitals/Services/QuickTools/ScreenshotImageFile.swift
        Sources/Vitals/UI/Settings/ScreenCaptureToolPicker.swift
        Sources/Vitals/UI/Settings/MonitorToken.swift
        Sources/Vitals/Services/QuickTools/ScreenshotRenderer.swift
        Sources/Vitals/Services/QuickTools/ScreenshotImageLayerRendering.swift
        Sources/Vitals/Services/QuickTools/RecentCaptureStore.swift
        Sources/Vitals/Services/QuickTools/ScreenshotSharingSupport.swift
        Sources/Vitals/Services/QuickTools/WindowActivationPolicy.swift
        Sources/Vitals/Services/KeyboardDebounce/KeyboardDebounceSupport.swift
        Sources/Vitals/Services/SuperKey/SuperKeySupport.swift
        Sources/Vitals/Services/SuperKey/SuperKeyMappingGuard.swift
        Sources/Vitals/Core/SuperKeyStrings.swift
        Sources/Vitals/Core/InputSourceSelection.swift
        Sources/Vitals/Services/SessionActivity.swift
        Sources/Vitals/Services/SessionActivitySupport.swift
        Sources/Vitals/Services/EventTimestamp.swift
        Sources/Vitals/Services/OwnKeyEvent.swift
        Sources/Vitals/Services/ScrollWheelSupport.swift
        Sources/Vitals/Services/HorizontalWheelScrolling.swift
        Sources/Vitals/Services/SmoothScrollSupport.swift
        Sources/Vitals/Services/MouseAcceleration/MouseAccelerationSupport.swift
        Sources/Vitals/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift
        Sources/Vitals/Services/AssistiveKeyboard.swift
        Sources/Vitals/Services/Switcher/SwitcherModels.swift
        Sources/Vitals/Services/Switcher/WindowServerCaptureQueue.swift
        Sources/Vitals/Services/Switcher/SwitcherSupport.swift
        Sources/Vitals/Services/Switcher/SpaceHopSupport.swift
        Sources/Vitals/Services/Switcher/WindowUseOrder.swift
        Sources/Vitals/Services/Switcher/WindowEnumeratorAccessibilityPrefetch.swift
        Sources/Vitals/Services/Metrics/MetricFormat.swift
        Sources/Vitals/Services/Metrics/VMStatisticsDecoder.swift
        Sources/Vitals/Services/KeepAwakeAutomationSupport.swift
        Sources/Vitals/Services/SudoersSupport.swift
        Sources/Vitals/Services/Metrics/BatteryTimeSupport.swift
        Sources/Vitals/Services/Metrics/BatteryPowerSupport.swift
        Sources/Vitals/Services/BoundedProcessRunner.swift
        Sources/Vitals/Services/DetachedProcess.swift
        Sources/Vitals/Services/ShellSupport.swift
        Sources/Vitals/Services/PortManager/PortManagerSupport.swift
        Sources/Vitals/Services/Metrics/NetworkProcessSupport.swift
        Sources/Vitals/Services/Metrics/NetworkSampler.swift
        Sources/Vitals/Services/Metrics/NetworkAddressService.swift
        Sources/Vitals/Services/Metrics/SpeedTest.swift
        Sources/Vitals/Services/Metrics/PeripheralBatterySampler.swift
        Sources/Vitals/Services/Metrics/PeripheralBatterySupport.swift
        Sources/Vitals/Services/Metrics/DiskSupport.swift
        Sources/Vitals/Services/Metrics/MonitorSamplingPolicy.swift
        Sources/Vitals/Services/Metrics/USBDeviceSampler.swift
        Sources/Vitals/Services/Metrics/CPUCoreSampler.swift
        Sources/Vitals/Services/Metrics/MaxCapacityProbe.swift
        Sources/Vitals/Services/Metrics/TemperatureSensorSelector.swift
        Sources/Vitals/Services/Metrics/SustainedAlertGate.swift
        Sources/Vitals/Services/Metrics/ChargingHeatAlertSupport.swift
        Sources/Vitals/Services/WindowLayout/WindowLayoutSupport.swift
        Sources/Vitals/Services/WindowLayout/WindowStageManagerSupport.swift
        Sources/Vitals/Core/WindowStageManagerStrings.swift
        Sources/Vitals/Core/WindowEdgeSnapRestoreStrings.swift
        Sources/Vitals/Services/WindowLayout/WindowGestureSupport.swift
        Sources/Vitals/Core/WindowDirectionalStrings.swift
        Sources/Vitals/Core/PointerDisplayStrings.swift
        Sources/Vitals/Core/GraphScaleStrings.swift
        Sources/Vitals/Core/NotchLowBatteryStrings.swift
        Sources/Vitals/Services/CleaningMode/CleaningUnlockCounter.swift
        Sources/Vitals/Services/CleaningMode/CleaningMouseReleaseGate.swift
        Sources/Vitals/Services/Display/ExtraBrightnessSupport.swift
        Sources/Vitals/Services/Display/BrightnessSupport.swift
        Sources/Vitals/Services/Display/MonitorVolumeKeySettings.swift
        Sources/Vitals/Services/Display/LidDimmingSupport.swift
        Sources/Vitals/Services/Cleaner/CleanerSupport.swift
        Sources/Vitals/Services/Cleaner/CleanerPolicy.swift
        Sources/Vitals/Services/Cleaner/CleanerSchedule.swift
        Sources/Vitals/Services/Uninstall/UninstallerSupport.swift
        Sources/Vitals/Services/ManagedDownloads/WhatsAppDownloadSupport.swift
        Sources/Vitals/Core/SecureInputSupport.swift
        Tests/*.swift
        build/generated-tests/*.swift
    )
    TEST_OUTPUT_FILE_MAP="$TEST_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$TEST_OUTPUT_FILE_MAP" "$TEST_OBJECT_DIR" "${TEST_SOURCES[@]}"
    echo "▸ Building & running tests against $(basename "$SDK")…"
    swiftc -Onone -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
        -module-name VorssaintTests -output-file-map "$TEST_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${CORE_AUDIO_TAP_FLAGS[@]}" "${GIF_CODEC_FLAGS[@]}" \
        "${TEST_SOURCES[@]}" "${GIF_CODEC_OBJECTS[@]}" -o build/metrics-tests
    test_status=0
    ./build/metrics-tests "${TEST_ARGS[@]}" || test_status=$?
    if (( ${#TEST_ARGS} == 0 )); then
        ./Tests/PreferenceCleanupTests.sh || test_status=1
        ./Tests/UninstallSpacesTests.sh || test_status=1
        ./Tests/DeveloperInstallIsolationTests.sh || test_status=1
    fi
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/Vitals/**/*.swift)
if (( ! DEV )); then
    # A release starts from an empty build directory, so nothing an earlier
    # build left behind (an old icon catalog, a staged bundle) can reach it.
    # Only the compiler's incremental records stay: they rebuild whatever
    # changed since, and a fresh checkout has none.
    find build -mindepth 1 -maxdepth 1 ! -name objects -exec rm -rf {} + 2>/dev/null || true
fi
APP_OBJECT_DIR="build/objects/$EXECUTABLE"
mkdir -p build "$APP_OBJECT_DIR"
APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
# Without -j the driver compiles one file at a time, and without batch mode
# each file's compiler parses the whole module again: a clean release took a
# quarter of an hour. Batches share that work and run on every core, and the
# optimization stays per file, as before.
swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
    -output-file-map "$APP_OUTPUT_FILE_MAP" \
    -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" \
    "${CORE_AUDIO_TAP_FLAGS[@]}" "${GIF_CODEC_FLAGS[@]}" \
    "${BUILD_VARIANT_FLAGS[@]}" \
    "${APP_SOURCES[@]}" "${GIF_CODEC_OBJECTS[@]}" -o "build/$EXECUTABLE"
xcrun dyld_info -imports "build/$EXECUTABLE" | awk -f Tests/AudioTapImports.awk

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/Vitals/Services/FanControl/FanControlSupport.swift \
    Sources/Vitals/Services/FanControl/FanControlXPC.swift \
    Sources/Vitals/Services/SystemMonitor/SMCClient.swift \
    Sources/Vitals/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/Vitals/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Compiling Now Playing adapter…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
    -module-name VitalsNowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    Sources/NowPlayingAdapter/NowPlayingQueue.swift \
    Sources/NowPlayingAdapter/NowPlayingSelection.swift \
    Sources/Vitals/Services/Notch/NotchPlaybackSource.swift \
    Sources/Vitals/Services/Notch/NotchPlaybackCommand.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
ICON_TMP="$(mktemp -d)"
ADAPTIVE_SKIP=""
if [[ -z "$ACTOOL_BIN" ]]; then
    ADAPTIVE_SKIP="actool not found (adaptive icons need Xcode 26+)"
elif [[ ! -d "Resources/Brand/AppIcon.icon" ]]; then
    # This fork ships its own icon artwork, generated by Tools/MakeBrand.swift
    # into Resources/Brand/AppIcon-Default.png. Upstream's Icon Composer
    # bundle (their AppIcon.icon) was removed since TRADEMARKS.md forbids
    # reusing their icon in a redistributed build.
    ADAPTIVE_SKIP="no adaptive icon source in this fork"
else
    echo "▸ Compiling adaptive icon catalog…"
    # actool crashes on File Provider-synced paths, so compile a local copy.
    ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
    # Xcode 27 beta actool requires the --compile target directory to already exist.
    mkdir -p "$ICON_TMP/catalog"
    if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
            --compile "$ICON_TMP/catalog" \
            --app-icon AppIcon \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --enable-on-demand-resources NO \
            --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
            >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
        mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
    else
        ADAPTIVE_SKIP="actool could not compile the catalog"
    fi
fi
if [[ -n "$ADAPTIVE_SKIP" ]]; then
    cp "$ICON_TMP/actool.log" build/actool-failure.log 2>/dev/null || true
    echo "  adaptive icon skipped: $ADAPTIVE_SKIP (Dock falls back to AppIcon.icns)"
fi
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
mkdir -p "$STAGE/Contents/Frameworks"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/agent-prices.json "$STAGE/Contents/Resources/agent-prices.json"
cp Resources/com.rishabhraaj17.vitals.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.rishabhraaj17.vitals.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :VorssaintBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :VorssaintFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp Sources/RecorderGIFCodec/vendor/cgif/LICENSE "$STAGE/Contents/Resources/cgif-LICENSE.txt"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if ! cmp -s Resources/Gifs/highlights-notch.gif "$STAGE/Contents/Resources/Gifs/highlights-notch.gif"; then
    echo "Dynamic Island tour GIF is missing or differs from the bundled copy" >&2
    exit 1
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "Vitals Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

codesign_now_playing_adapter() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif legacy_identity_installed; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && codesign --verify --strict "$adapter"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

# Installed development builds only need the copy in /Applications. Retaining
# another app in each checkout pollutes application search with stale builds.
if (( DEV )); then
    for old_bundle in "build/stage/$APP_NAME.app" "build/stage.noindex/$APP_NAME.app"; do
        if [[ -d "$old_bundle" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$PWD/$old_bundle" >/dev/null 2>&1 || true
            rm -rf "$old_bundle"
        fi
    done
fi

if (( !DEV || !INSTALL )); then
    STAGE_DIRECTORY="build/stage"
    (( DEV )) && STAGE_DIRECTORY="build/stage.noindex"
    mkdir -p "$STAGE_DIRECTORY"
    BUILD_STAGE="$STAGE_DIRECTORY/$APP_NAME.app"
    rm -rf "$BUILD_STAGE"
    ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
    xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
    if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
        if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
            echo "  staging copy has local filesystem metadata; temp bundle was verified"
        else
            codesign --verify --deep --strict "$BUILD_STAGE"
        fi
    fi
    echo "✓ Bundle ready: $BUILD_STAGE"
fi

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    # No legacy cleanup. Upstream used this slot to replace its own pre-rename
    # apps (Vorss.app, Vorssaint Utils.app). For this fork those are a different
    # vendor's live installs, not our past self, so we never stop or remove them.
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
