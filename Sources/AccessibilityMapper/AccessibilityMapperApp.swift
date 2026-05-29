//  AccessibilityMapperApp.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import SwiftUI

@main
struct AccessibilityMapperApp: App {
    var body: some Scene {
        WindowGroup("Accessibility Mapper") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Open Map…") { NotificationCenter.default.post(name: .openMap, object: nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save Map…") { NotificationCenter.default.post(name: .saveMap, object: nil) }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let saveMap = Notification.Name("saveMap")
    static let openMap = Notification.Name("openMap")
}
