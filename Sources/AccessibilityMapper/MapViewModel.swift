//  MapViewModel.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class MapViewModel: ObservableObject {

    // MARK: Ephemeral UI state

    @Published var isPlacingBullseye: Bool = false
    @Published var selectedMarkerID: UUID? = nil
    @Published var errorMessage: String? = nil

    @Published var showWalk:        Bool = true
    @Published var showSafeRoutes:  Bool = true
    @Published var showBike:        Bool = true
    @Published var showLSV:         Bool = true

    // Changing navigationTrigger tells MapView to animate to navigationRegion
    @Published var navigationTrigger: UUID = UUID()
    @Published var navigationRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )

    private let geocoder = CLGeocoder()

    // MARK: Actions

    func centerOn(marker: BullseyeMarker) {
        selectedMarkerID = marker.id
        navigationRegion = MKCoordinateRegion(
            center: marker.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        navigationTrigger = UUID()
    }

    func geocodeZipCode(_ zipCode: String) {
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
}
