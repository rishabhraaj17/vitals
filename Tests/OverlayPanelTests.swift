// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// AppKit describes a non-activating panel as a system dialog, which tiling
/// window managers track and list on whichever space is current. The shared
/// panel class is compiled here and created deferred, so no window is shown;
/// each floating surface's own file is read for the class it builds.
enum OverlayPanelTests {
    static func run(_ suite: TestSuite) {
        // The Clipboard History window keeps a title bar strip to drag it by.
        for style: NSWindow.StyleMask in [[.borderless, .nonactivatingPanel],
                                          [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]] {
            let overlay = OverlayPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
                                       styleMask: style, backing: .buffered, defer: true)
            suite.expect(overlay.accessibilitySubrole() == .unknown,
                         "a floating overlay describes itself as an undescribed window, so window managers skip it")
            suite.expect(overlay.accessibilityRole() == .window && overlay.isAccessibilityElement(),
                         "a floating overlay stays an accessible window for assistive technology")
        }

        // HUDs, previews, pickers and the menu's positioning helper: none is a
        // document window, and each floats over other apps' windows.
        let surfaces = [
            "Sources/Vitals/App/AppDelegate.swift",
            "Sources/Vitals/UI/PermissionGuideOverlay.swift",
            "Sources/Vitals/UI/QuitProtection/QuitProtectionHUD.swift",
            "Sources/Vitals/Services/QuickTools/QuickToolHUD.swift",
            "Sources/Vitals/Services/QuickTools/CaptureRegionGuide.swift",
            "Sources/Vitals/Services/QuickTools/QuickLauncherService.swift",
            "Sources/Vitals/Services/QuickTools/CameraPreviewService.swift",
            "Sources/Vitals/Services/QuickTools/RecentCaptureService.swift",
            "Sources/Vitals/Services/QuickTools/ScreenshotSelectionController.swift",
            "Sources/Vitals/Services/QuickTools/ScreenshotQuickPreviewController.swift",
            "Sources/Vitals/Services/QuickTools/ScreenshotPinController.swift",
            "Sources/Vitals/Services/QuickTools/QRResultController.swift",
            "Sources/Vitals/Services/QuickTools/ScratchpadService.swift",
            "Sources/Vitals/Services/Snippets/SnippetLibraryService.swift",
            "Sources/Vitals/Services/Clipboard/ClipboardHistoryService.swift",
            "Sources/Vitals/Services/CommandBar/CommandBarService.swift",
            "Sources/Vitals/Services/Switcher/AppSwitcher.swift",
            "Sources/Vitals/Services/RadialMenu/RadialMenuService.swift",
            "Sources/Vitals/Services/RadialMenu/RadialNowPlayingService.swift",
            "Sources/Vitals/Services/DockPreview/DockPreviewService.swift",
            "Sources/Vitals/Services/WindowLayout/WindowLayoutService.swift",
            "Sources/Vitals/Services/DiskImageInstaller/DiskImageInstallerService.swift",
            "Sources/Vitals/Services/Finder/FinderCutPaste.swift",
            "Sources/Vitals/Services/Display/BrightnessOSD.swift",
            "Sources/Vitals/Services/CleaningMode/CleaningModeManager.swift",
            "Sources/Vitals/Services/Recorder/RecorderIndicator.swift",
        ]
        for path in surfaces {
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            suite.expect(source.range(of: #"\bOverlayPanel\(contentRect|:\s*OverlayPanel\b"#,
                                      options: .regularExpression) != nil
                         && !source.contains("NSPanel(contentRect")
                         && source.range(of: #"class \w+:\s*NSPanel\b"#, options: .regularExpression) == nil,
                         "\(path) builds its floating panels as overlays, which window managers do not list")
        }
    }
}
