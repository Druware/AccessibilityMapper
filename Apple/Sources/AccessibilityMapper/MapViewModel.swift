//  MapViewModel.swift
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
import CoreLocation

@MainActor
final class MapViewModel: ObservableObject {

    // MARK: Ephemeral UI state

    @Published var isPlacingBullseye: Bool = false
    @Published var selectedMarkerID: UUID? = nil
    @Published var errorMessage: String? = nil
    @Published var isFetchingBoundary: Bool = false

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

    func fetchBoundary(query: String, type: BoundaryType) async -> BoundaryRecord? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        isFetchingBoundary = true
        defer { isFetchingBoundary = false }

        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q",               value: q),
            URLQueryItem(name: "format",          value: "geojson"),
            URLQueryItem(name: "polygon_geojson", value: "1"),
            URLQueryItem(name: "limit",           value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("AccessibilityMapper/1.0 (dru@openbcm.com)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json      = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features  = json["features"] as? [[String: Any]],
                  let first     = features.first,
                  let props     = first["properties"] as? [String: Any],
                  let name      = props["display_name"] as? String,
                  let geometry  = first["geometry"] as? [String: Any],
                  let geoType   = geometry["type"] as? String else {
                errorMessage = "No boundary found for \"\(q)\""
                return nil
            }

            var rings: [[[Double]]] = []
            if geoType == "Polygon",
               let coords = geometry["coordinates"] as? [[[Any]]] {
                rings = Self.parseRings(coords)
            } else if geoType == "MultiPolygon",
                      let polys = geometry["coordinates"] as? [[[[Any]]]] {
                for poly in polys { rings += Self.parseRings(poly) }
            }

            guard !rings.isEmpty else {
                errorMessage = "No polygon boundary returned for \"\(q)\""
                return nil
            }
            return BoundaryRecord(name: name, type: type, polygonRings: rings)
        } catch {
            errorMessage = "Boundary search failed: \(error.localizedDescription)"
            return nil
        }
    }

    private static func parseRings(_ rawRings: [[[Any]]]) -> [[[Double]]] {
        rawRings.map { ring in
            ring.compactMap { pt -> [Double]? in
                guard let arr = pt as? [Double], arr.count >= 2 else { return nil }
                return arr
            }
        }
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
