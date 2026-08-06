//  AccessibilityMapperApp.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Designs. All rights reserved.
//
//  DUAL LICENSE
//  ============
//  Druware Software Designs (the copyright holder) may publish and distribute
//  compiled binaries of this software under the terms of the Commercial License
//  (see LICENSE-COMMERCIAL in the project root).
//
//  All other parties must use, modify, and distribute this source code
//  exclusively under the GNU General Public License v3 (see LICENSE).


import SwiftUI

@main
struct AccessibilityMapperApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MapDocument()) { file in
            ContentView(document: file.$document)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands { AppCommands() }

        Window("About Accessibility Mapper", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Accessibility Mapper") {
                openWindow(id: "about")
            }
        }
    }
}
