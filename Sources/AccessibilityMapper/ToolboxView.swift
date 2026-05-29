//  ToolboxView.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import SwiftUI

struct ToolboxView: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────
            Text("Toolbox")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // ── Tools ─────────────────────────────────────────────────
            sectionHeader("TOOLS")

            ToolRow(icon: "cursorarrow",
                    title: "Select",
                    subtitle: "Move map, inspect markers",
                    isActive: !viewModel.isPlacingBullseye) {
                viewModel.isPlacingBullseye = false
            }

            ToolRow(icon: "scope",
                    title: "Accessible Location",
                    subtitle: "Click map to place rings",
                    isActive: viewModel.isPlacingBullseye) {
                viewModel.isPlacingBullseye = true
            }

            Divider().padding(.top, 6)

            // ── Legend ────────────────────────────────────────────────
            sectionHeader("RADIUS LEGEND")

            VStack(alignment: .leading, spacing: 5) {
                LegendRow(color: .red,    label: "Walk         —  0.5 mi", isEnabled: $viewModel.showWalk)
                LegendRow(color: .green,  label: "Safe Routes  —  1.0 mi", isEnabled: $viewModel.showSafeRoutes)
                LegendRow(color: .orange, label: "Bike         —  2.0 mi", isEnabled: $viewModel.showBike)
                LegendRow(color: .blue,   label: "LSV          —  3.0 mi", isEnabled: $viewModel.showLSV)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            // ── Marker List ───────────────────────────────────────────
            HStack {
                sectionHeader("MARKERS")
                Spacer()
                Text("\(viewModel.markers.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
                    .padding(.trailing, 12)
            }

            if viewModel.markers.isEmpty {
                Text("No markers yet.\nSelect Accessible Location, then\nclick anywhere on the map.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(viewModel.markers) { marker in
                            MarkerRow(marker: marker) {
                                viewModel.removeMarker(id: marker.id)
                            } onRename: { newLabel in
                                viewModel.renameMarker(id: marker.id, label: newLabel)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer()

            // ── Status bar ────────────────────────────────────────────
            Divider()
            Group {
                if viewModel.isPlacingBullseye {
                    Label("Click map to place accessible location", systemImage: "scope")
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08))
                } else {
                    Label("Select mode", systemImage: "cursorarrow")
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

// MARK: - Sub-views

struct ToolRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundColor(isActive ? .accentColor : .primary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LegendRow: View {
    let color: Color
    let label: String
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
            ZStack {
                Circle().fill(color.opacity(isEnabled ? 0.18 : 0.06)).frame(width: 14, height: 14)
                Circle().stroke(color.opacity(isEnabled ? 1.0 : 0.3), lineWidth: 2).frame(width: 14, height: 14)
            }
            Text(label)
                .font(.caption)
                .foregroundColor(isEnabled ? .primary : .secondary)
        }
    }
}

struct MarkerRow: View {
    let marker: BullseyeMarker
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @State private var label: String

    init(marker: BullseyeMarker, onDelete: @escaping () -> Void, onRename: @escaping (String) -> Void) {
        self.marker = marker
        self.onDelete = onDelete
        self.onRename = onRename
        self._label = State(initialValue: marker.label)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .foregroundColor(.red)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name...", text: $label)
                    .font(.system(size: 11, weight: .medium))
                    .textFieldStyle(.plain)
                    .onChange(of: label) { newValue in onRename(newValue) }

                HStack(spacing: 6) {
                    Text(String(format: "%.5f°", marker.latitude))
                    Text(String(format: "%.5f°", marker.longitude))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(5)
    }
}
