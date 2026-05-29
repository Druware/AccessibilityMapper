//  Models.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import Foundation
import CoreLocation

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
}
