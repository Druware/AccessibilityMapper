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
