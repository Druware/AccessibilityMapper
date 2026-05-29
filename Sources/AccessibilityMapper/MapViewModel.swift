//  MapViewModel.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import SwiftUI
import MapKit
import CoreLocation
import AppKit

@MainActor
final class MapViewModel: ObservableObject {

    // MARK: Published state
    @Published var markers: [BullseyeMarker] = []
    @Published var zipCode: String = ""
    @Published var isPlacingBullseye: Bool = false
    @Published var mapTypeRaw: Int = 0
    @Published var errorMessage: String? = nil

    @Published var showWalk:        Bool = true
    @Published var showSafeRoutes:  Bool = true
    @Published var showBike:        Bool = true
    @Published var showLSV:         Bool = true

    // Changing navigationTrigger tells the map view to animate to navigationRegion
    @Published var navigationTrigger: UUID = UUID()
    @Published var navigationRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )

    // Set after first save or after open; enables subsequent saves to skip the panel
    private(set) var currentFileURL: URL? = nil

    // Updated continuously by the map delegate (no published needed — only read at save time)
    var currentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )

    // MARK: Helpers
    private let geocoder = CLGeocoder()

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )

    var mkMapType: MKMapType {
        switch mapTypeRaw {
        case 1: return .satellite
        case 2: return .hybrid
        default: return .standard
        }
    }

    // MARK: Actions

    func geocodeZipCode() {
        let query = zipCode.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        geocoder.geocodeAddressString(query) { [weak self] placemarks, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.errorMessage = "Could not find \"\(query)\": \(error.localizedDescription)"
                    return
                }
                guard let coord = placemarks?.first?.location?.coordinate else {
                    self.errorMessage = "No location found for \"\(query)\""
                    return
                }
                self.navigationRegion = MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 9_000,
                    longitudinalMeters: 9_000
                )
                self.navigationTrigger = UUID()
            }
        }
    }

    func addMarker(at coordinate: CLLocationCoordinate2D) {
        markers.append(BullseyeMarker(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    func removeMarker(id: UUID) {
        markers.removeAll { $0.id == id }
    }

    func renameMarker(id: UUID, label: String) {
        if let index = markers.firstIndex(where: { $0.id == id }) {
            markers[index].label = label
        }
    }

    // MARK: Persistence

    func saveDocument() {
        if let url = currentFileURL {
            write(to: url)
        } else {
            saveDocumentAs()
        }
    }

    func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = zipCode.isEmpty ? "AccessibilityMap" : "Map_\(zipCode)"
        panel.title = "Save Accessibility Map"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        currentFileURL = url
        write(to: url)
    }

    private func write(to url: URL) {
        let doc = MapDocument(
            zipCode: zipCode,
            centerLatitude:  currentRegion.center.latitude,
            centerLongitude: currentRegion.center.longitude,
            spanLatDelta:    currentRegion.span.latitudeDelta,
            spanLonDelta:    currentRegion.span.longitudeDelta,
            mapTypeRaw:      mapTypeRaw,
            markers:         markers
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(doc).write(to: url)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func loadDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "Open Accessibility Map"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let doc = try JSONDecoder().decode(MapDocument.self, from: Data(contentsOf: url))
            currentFileURL = url
            zipCode    = doc.zipCode
            mapTypeRaw = doc.mapTypeRaw
            markers    = doc.markers
            navigationRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: doc.centerLatitude, longitude: doc.centerLongitude),
                span: MKCoordinateSpan(latitudeDelta: doc.spanLatDelta, longitudeDelta: doc.spanLonDelta)
            )
            navigationTrigger = UUID()
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
        }
    }
}
