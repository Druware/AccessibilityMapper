//  ContentView.swift
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
import MapKit

struct ContentView: View {
    @Binding var document: MapDocument
    @StateObject private var viewModel = MapViewModel()
    @FocusState private var zipFocused: Bool
    @State private var isImportingMap = false
    @State private var importSummary: String? = nil

    var body: some View {
        HSplitView {
            ToolboxView(document: $document, viewModel: viewModel)
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            VStack(spacing: 0) {
                toolbar
                MapView(document: $document, viewModel: viewModel)
            }
        }
        .navigationTitle(document.zipCode.isEmpty ? "Accessibility Mapper" : "Accessibility Mapper — \(document.zipCode)")
        .onAppear {
            zipFocused = true
            registerScripting()
        }
        .onDisappear {
            ScriptingBridge.shared.geocodeAction      = nil
            ScriptingBridge.shared.addMarkerAction    = nil
            ScriptingBridge.shared.removeMarkerAction = nil
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .focusedSceneValue(\.importMapAction, { isImportingMap = true })
        .fileImporter(isPresented: $isImportingMap, allowedContentTypes: [.accmap]) { result in
            importMap(result)
        }
        .alert("Import Map", isPresented: Binding(
            get: { importSummary != nil },
            set: { if !$0 { importSummary = nil } }
        )) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(importSummary ?? "")
        }
    }

    // MARK: - Import

    private func importMap(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let data     = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode(MapDocument.self, from: data)

            // Merge into a copy and assign once, so the document is marked edited in a single change
            var merged = document
            let counts = merged.merge(imported)
            if counts.markersAdded + counts.boundariesAdded > 0 { document = merged }

            importSummary = Self.importSummary(counts)
        } catch {
            viewModel.errorMessage = "Could not import map: \(error.localizedDescription)"
        }
    }

    private static func importSummary(_ counts: (markersAdded: Int, boundariesAdded: Int, skipped: Int)) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var text = "Imported \(count(counts.markersAdded, "marker", "markers")) and \(count(counts.boundariesAdded, "boundary", "boundaries"))"
        if counts.skipped > 0 { text += "; \(count(counts.skipped, "duplicate", "duplicates")) skipped" }
        return text + "."
    }

    // MARK: - AppleScript bridge

    private func registerScripting() {
        let docBinding = $document
        ScriptingBridge.shared.geocodeAction = { address in
            viewModel.geocodeZipCode(address)
        }
        ScriptingBridge.shared.addMarkerAction = { lat, lon, label in
            let marker = BullseyeMarker(latitude: lat, longitude: lon, label: label)
            docBinding.wrappedValue.markers.append(marker)
            return marker.id.uuidString
        }
        ScriptingBridge.shared.removeMarkerAction = { uuidString in
            guard let id = UUID(uuidString: uuidString) else { return false }
            let before = docBinding.wrappedValue.markers.count
            docBinding.wrappedValue.markers.removeAll { $0.id == id }
            return docBinding.wrappedValue.markers.count < before
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {

            Image(systemName: "map.fill")
                .foregroundColor(.accentColor)

            TextField("ZIP code", text: $document.zipCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .focused($zipFocused)
                .onSubmit { viewModel.geocodeZipCode(document.zipCode) }

            Button("Go") { viewModel.geocodeZipCode(document.zipCode) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Divider().frame(height: 22)

            Picker("", selection: $document.mapTypeRaw) {
                Text("Standard").tag(0)
                Text("Satellite").tag(1)
                Text("Hybrid").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .help("Map display style")

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}
