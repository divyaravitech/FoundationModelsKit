#!/usr/bin/env swift
//
// Prints the CGWindowID of the PrivacyChat window, for use with:
//
//     screencapture -x -o -l"$(swift scripts/window-id.swift)" shot.png
//
// `-l` captures a single window rather than the whole screen, and `-o`
// omits the drop shadow so the PNG has no transparent margin.

import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    guard
        let owner = window[kCGWindowOwnerName as String] as? String,
        owner.contains("PrivacyChat"),
        let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let height = bounds["Height"] as? Double,
        // Skip the menu-bar and other chrome windows; the real one is tall.
        height > 300
    else { continue }

    print(number)
    exit(0)
}

FileHandle.standardError.write(Data("No PrivacyChat window found. Is the app running?\n".utf8))
exit(1)
