//  ScriptCommands.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/06/01.
//  Copyright © 2026 Druware Software Development. All rights reserved.

import AppKit

// MARK: - Bridge

/// Singleton that the active ContentView registers live document callbacks with.
/// NSScriptCommand subclasses call through here on the main thread.
final class ScriptingBridge {
    static let shared = ScriptingBridge()
    private init() {}

    /// Navigate to a ZIP code or address string.
    var geocodeAction: ((String) -> Void)?

    /// Add a marker at the given coordinate with an optional label.
    /// Returns the new marker's UUID string, or nil when no document is active.
    var addMarkerAction: ((Double, Double, String) -> String)?

    /// Remove the marker whose UUID string matches. Returns true on success.
    var removeMarkerAction: ((String) -> Bool)?
}

// MARK: - geocode

/// Usage (AppleScript):  geocode "94025"
@objc(GeocodeScriptCommand)
final class GeocodeScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let address = directParameter as? String, !address.isEmpty else {
            scriptErrorNumber = Int(errAECoercionFail)
            scriptErrorString = "Expected a non-empty ZIP code or address string."
            return nil
        }
        // Fire on the next main-run-loop turn so the command returns quickly.
        DispatchQueue.main.async {
            ScriptingBridge.shared.geocodeAction?(address)
        }
        return nil
    }
}

// MARK: - add marker

/// Usage (AppleScript):
///   set uid to add marker at latitude 37.3318 longitude -122.0312 with label "Library"
@objc(AddMarkerScriptCommand)
final class AddMarkerScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard
            let lat = evaluatedArguments?["latitude"] as? Double,
            let lon = evaluatedArguments?["longitude"] as? Double
        else {
            scriptErrorNumber = Int(errAECoercionFail)
            scriptErrorString = "add marker requires 'at latitude' and 'longitude' parameters."
            return nil
        }
        let label = evaluatedArguments?["label"] as? String ?? ""
        guard let uuid = ScriptingBridge.shared.addMarkerAction?(lat, lon, label) else {
            scriptErrorNumber = Int(errAEEventNotPermitted)
            scriptErrorString = "No active Accessibility Mapper document."
            return nil
        }
        return uuid as NSString
    }
}

// MARK: - remove marker

/// Usage (AppleScript):  remove marker "uuid-string"
@objc(RemoveMarkerScriptCommand)
final class RemoveMarkerScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let uuidString = directParameter as? String else {
            scriptErrorNumber = Int(errAECoercionFail)
            scriptErrorString = "Expected a marker UUID string."
            return nil
        }
        let removed = ScriptingBridge.shared.removeMarkerAction?(uuidString) ?? false
        if !removed {
            scriptErrorNumber = Int(errAENoSuchObject)
            scriptErrorString = "No marker found with UUID \"\(uuidString)\"."
        }
        return nil
    }
}
