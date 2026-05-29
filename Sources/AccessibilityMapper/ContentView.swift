//  ContentView.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var viewModel = MapViewModel()

    var body: some View {
        HSplitView {
            ToolboxView(viewModel: viewModel)
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            VStack(spacing: 0) {
                toolbar
                MapView(viewModel: viewModel)
            }
        }
        .navigationTitle(viewModel.zipCode.isEmpty ? "Accessibility Mapper" : "Accessibility Mapper — \(viewModel.zipCode)")
        // Wire menu-bar commands from App struct to viewModel
        .onReceive(NotificationCenter.default.publisher(for: .saveMap)) { _ in viewModel.saveDocument() }
        .onReceive(NotificationCenter.default.publisher(for: .openMap)) { _ in viewModel.loadDocument() }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {

            // ZIP entry
            Image(systemName: "map.fill")
                .foregroundColor(.accentColor)

            TextField("ZIP code", text: $viewModel.zipCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onSubmit { viewModel.geocodeZipCode() }

            Button("Go") { viewModel.geocodeZipCode() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Divider().frame(height: 22)

            // Map style
            Picker("", selection: $viewModel.mapTypeRaw) {
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
