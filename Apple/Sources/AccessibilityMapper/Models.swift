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

// Bullseye markers draw distance rings; incident markers (e.g. imported crash points) do not.
enum MarkerKind: String, Codable, CaseIterable {
    case bullseye, incident
}

struct BullseyeMarker: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var latitude: Double
    var longitude: Double
    var label: String = ""
    var kind: MarkerKind = .bullseye

    private enum CodingKeys: String, CodingKey {
        case id, latitude, longitude, label, kind
    }

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

// Declared in an extension so the memberwise initializer is kept.
// A missing label decodes as ""; a missing, unrecognized or non-string kind decodes as .bullseye.
extension BullseyeMarker {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        latitude  = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        label     = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        kind      = MarkerKind(rawValue: ((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil) ?? "") ?? .bullseye
    }
}

struct MapDocument: Codable {
    // Always written as the current version; files without it are version 1 and open the same way.
    static let currentFormatVersion = 2

    private(set) var formatVersion: Int = MapDocument.currentFormatVersion
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
    // formatVersion is encoded but never decoded.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, zipCode, centerLatitude, centerLongitude, spanLatDelta, spanLonDelta,
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

    // Region that fits all markers with a 15% margin. Bullseye markers are padded so their
    // outermost ring is visible; incidents have no rings and contribute only their coordinate.
    // Returns nil when there are no markers.
    var fitRegion: MKCoordinateRegion? {
        guard !markers.isEmpty else { return nil }

        // Convert the outer ring radius to degrees for padding, at the markers' middle latitude
        let midLat = (markers.map(\.latitude).min()! + markers.map(\.latitude).max()!) / 2
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(midLat * .pi / 180)

        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for m in markers {
            let radius = m.kind == .bullseye ? BullseyeMarker.Radii.outer : 0
            let latPad = radius / metersPerDegreeLat
            let lonPad = radius / metersPerDegreeLon
            minLat = min(minLat, m.latitude  - latPad); maxLat = max(maxLat, m.latitude  + latPad)
            minLon = min(minLon, m.longitude - lonPad); maxLon = max(maxLon, m.longitude + lonPad)
        }

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        // Keep a minimum span so unpadded incidents at one point don't zoom to the maximum
        let minSpan = 0.02
        let spanLat = max((maxLat - minLat) * 1.15, minSpan)
        let spanLon = max((maxLon - minLon) * 1.15, minSpan)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
    }

    // Appends markers and boundaries from another map, keeping existing items first and
    // imported items in file order. A marker is skipped when its id is already present; a
    // boundary is skipped when its id or its (name, type) pair is already present.
    // The viewport, ZIP code and map type are left unchanged.
    mutating func merge(_ other: MapDocument) -> (markersAdded: Int, boundariesAdded: Int, skipped: Int) {
        var markersAdded = 0, boundariesAdded = 0, skipped = 0

        var markerIDs = Set(markers.map(\.id))
        for marker in other.markers {
            if markerIDs.insert(marker.id).inserted {
                markers.append(marker)
                markersAdded += 1
            } else {
                skipped += 1
            }
        }

        var boundaryIDs  = Set(boundaries.map(\.id))
        var boundaryKeys = Set(boundaries.map { "\($0.type.rawValue):\($0.name)" })
        for boundary in other.boundaries {
            let key = "\(boundary.type.rawValue):\(boundary.name)"
            if !boundaryIDs.contains(boundary.id) && !boundaryKeys.contains(key) {
                boundaryIDs.insert(boundary.id)
                boundaryKeys.insert(key)
                boundaries.append(boundary)
                boundariesAdded += 1
            } else {
                skipped += 1
            }
        }

        return (markersAdded, boundariesAdded, skipped)
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
