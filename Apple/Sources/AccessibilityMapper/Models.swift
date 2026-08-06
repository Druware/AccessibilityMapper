//  Models.swift
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


import Foundation
import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Boundary

enum BoundaryType: String, Codable, CaseIterable {
    case city, county, state
    var displayName: String {
        switch self {
        case .city:   return "City"
        case .county: return "County/Parish"
        case .state:  return "State"
        }
    }
}

struct BoundaryRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var type: BoundaryType
    // Each element is one polygon ring: array of [longitude, latitude] pairs
    var polygonRings: [[[Double]]]
}

// MARK: - Marker

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
    var boundaries: [BoundaryRecord] = []

    // Explicit CodingKeys so the custom init(from:) can decode older files
    // that are missing newer fields, falling back to each property's default value.
    private enum CodingKeys: String, CodingKey {
        case zipCode, centerLatitude, centerLongitude, spanLatDelta, spanLonDelta,
             mapTypeRaw, markers, boundaries
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zipCode         = try c.decodeIfPresent(String.self,           forKey: .zipCode)         ?? ""
        centerLatitude  = try c.decodeIfPresent(Double.self,           forKey: .centerLatitude)  ?? 37.3318
        centerLongitude = try c.decodeIfPresent(Double.self,           forKey: .centerLongitude) ?? -122.0312
        spanLatDelta    = try c.decodeIfPresent(Double.self,           forKey: .spanLatDelta)    ?? 0.15
        spanLonDelta    = try c.decodeIfPresent(Double.self,           forKey: .spanLonDelta)    ?? 0.15
        mapTypeRaw      = try c.decodeIfPresent(Int.self,              forKey: .mapTypeRaw)      ?? 0
        markers         = try c.decodeIfPresent([BullseyeMarker].self, forKey: .markers)         ?? []
        boundaries      = try c.decodeIfPresent([BoundaryRecord].self, forKey: .boundaries)      ?? []
    }

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
