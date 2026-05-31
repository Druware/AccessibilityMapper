//  Models.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import Foundation
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct BullseyeMarker: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var latitude: Double
    var longitude: Double
    var label: String = ""

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // Radii in meters: 0.5 mi, 1 mi, 2 mi, 3 mi
    enum Radii {
        static let inner:       Double = 804.672    // 0.5 miles
        static let safeRoutes:  Double = 1_609.344  // 1.0 miles
        static let middle:      Double = 3_218.688  // 2.0 miles
        static let outer:       Double = 4_828.032  // 3.0 miles
    }

    static func == (lhs: BullseyeMarker, rhs: BullseyeMarker) -> Bool { lhs.id == rhs.id }
}

struct MapDocument: Codable {
    var zipCode: String = ""
    var centerLatitude:  Double = 37.3318
    var centerLongitude: Double = -122.0312
    var spanLatDelta:    Double = 0.15
    var spanLonDelta:    Double = 0.15
    var mapTypeRaw:      Int    = 0    // 0=standard 1=satellite 2=hybrid
    var markers: [BullseyeMarker] = []

    var mkMapType: MKMapType {
        switch mapTypeRaw {
        case 1: return .satellite
        case 2: return .hybrid
        default: return .standard
        }
    }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: spanLatDelta, longitudeDelta: spanLonDelta)
        )
    }

    // Region that fits all markers with their outermost ring visible, plus a 15% margin.
    // Returns nil when there are no markers.
    var fitRegion: MKCoordinateRegion? {
        guard !markers.isEmpty else { return nil }

        let minLat = markers.map(\.latitude).min()!
        let maxLat = markers.map(\.latitude).max()!
        let minLon = markers.map(\.longitude).min()!
        let maxLon = markers.map(\.longitude).max()!

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        // Convert the outer ring radius to degrees for padding
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(centerLat * .pi / 180)
        let latPad = BullseyeMarker.Radii.outer / metersPerDegreeLat
        let lonPad = BullseyeMarker.Radii.outer / metersPerDegreeLon

        let spanLat = ((maxLat - minLat) + 2 * latPad) * 1.15
        let spanLon = ((maxLon - minLon) + 2 * lonPad) * 1.15

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
    }
}

extension UTType {
    static let accmap = UTType(exportedAs: "com.openbcm.accmap")
}

extension MapDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.accmap] }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self = try JSONDecoder().decode(MapDocument.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return FileWrapper(regularFileWithContents: data)
    }
}
