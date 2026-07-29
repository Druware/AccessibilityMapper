//  MapView.swift
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
import AppKit

// MARK: - Annotation model

private final class MarkerButton: NSButton {
    var annotation: BullseyeAnnotation?
}

final class BullseyeAnnotation: NSObject, MKAnnotation {
    let marker: BullseyeMarker

    var coordinate: CLLocationCoordinate2D { marker.coordinate }
    var title: String? { marker.label.isEmpty ? "Accessible Location" : marker.label }
    var subtitle: String? { String(format: "%.5f,  %.5f", marker.latitude, marker.longitude) }

    init(marker: BullseyeMarker) {
        self.marker = marker
        super.init()
    }
}

// MARK: - NSViewRepresentable

struct MapView: NSViewRepresentable {
    @Binding var document: MapDocument
    @ObservedObject var viewModel: MapViewModel

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(document.fitRegion ?? document.region, animated: false)
        map.mapType = document.mkMapType

        let tap = NSClickGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.isEnabled = viewModel.isPlacingBullseye
        map.addGestureRecognizer(tap)
        context.coordinator.tapGesture = tap

        // Prime the nav trigger so updateNSView doesn't overwrite the fit region on its first call
        context.coordinator.lastNavTrigger = viewModel.navigationTrigger

        // Boundaries first (rendered below rings at .aboveRoads level)
        if !document.boundaries.isEmpty {
            rebuildBoundaryOverlays(map)
            context.coordinator.lastBoundaryIDs = document.boundaries.map(\.id)
        }

        // Populate markers immediately so they're visible on first render / document load
        if !document.markers.isEmpty {
            map.addAnnotations(document.markers.map { BullseyeAnnotation(marker: $0) })
            rebuildOverlays(map)
            context.coordinator.lastMarkerIDs   = document.markers.map(\.id)
            context.coordinator.lastMarkerKeys  = document.markers.map { "\($0.id):\($0.label)" }
            context.coordinator.lastRingToggles = (
                viewModel.showWalk, viewModel.showSafeRoutes,
                viewModel.showBike, viewModel.showLSV
            )
        }

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coord = context.coordinator

        // Propagate current binding reference to coordinator
        coord.document = $document

        // Navigate when triggered
        if coord.lastNavTrigger != viewModel.navigationTrigger {
            coord.lastNavTrigger = viewModel.navigationTrigger
            map.setRegion(viewModel.navigationRegion, animated: true)
        }

        // Map style
        if map.mapType != document.mkMapType { map.mapType = document.mkMapType }

        // Placement cursor
        coord.tapGesture?.isEnabled = viewModel.isPlacingBullseye

        // Selection — update annotation icons and overlay rings when selectedMarkerID changes
        if coord.lastSelectedID != viewModel.selectedMarkerID {
            let next = viewModel.selectedMarkerID
            coord.lastSelectedID = next
            let markerByID = Dictionary(uniqueKeysWithValues: document.markers.map { ($0.id, $0) })
            for ann in map.annotations.compactMap({ $0 as? BullseyeAnnotation }) {
                guard let av = map.view(for: ann) else { continue }
                let sel = ann.marker.id == next
                let currentLabel = markerByID[ann.marker.id]?.label ?? ann.marker.label
                let (icon, offsetY) = Coordinator.bullseyeIcon(selected: sel, label: currentLabel)
                av.image = icon
                av.centerOffset = CGPoint(x: 0, y: offsetY)
            }
            rebuildOverlays(map)
        }

        // Overlays & annotations (rebuild when markers list or labels or ring toggles change)
        let ids    = document.markers.map(\.id)
        let keys   = document.markers.map { "\($0.id):\($0.label)" }
        let toggles = (viewModel.showWalk, viewModel.showSafeRoutes, viewModel.showBike, viewModel.showLSV)
        let markerListChanged   = ids  != coord.lastMarkerIDs
        let markerLabelsChanged = keys != coord.lastMarkerKeys
        let togglesChanged      = toggles != coord.lastRingToggles
        if markerListChanged || markerLabelsChanged || togglesChanged {
            coord.lastMarkerIDs    = ids
            coord.lastMarkerKeys   = keys
            coord.lastRingToggles  = toggles
            rebuildOverlays(map)
            if markerListChanged {
                rebuildAnnotations(map)
            } else if markerLabelsChanged {
                // Label-only change: refresh images without adding/removing annotations
                let markerByID = Dictionary(uniqueKeysWithValues: document.markers.map { ($0.id, $0) })
                for ann in map.annotations.compactMap({ $0 as? BullseyeAnnotation }) {
                    guard let av = map.view(for: ann) else { continue }
                    let sel = ann.marker.id == viewModel.selectedMarkerID
                    let label = markerByID[ann.marker.id]?.label ?? ""
                    let (icon, offsetY) = Coordinator.bullseyeIcon(selected: sel, label: label)
                    av.image = icon
                    av.centerOffset = CGPoint(x: 0, y: offsetY)
                }
            }
        }

        // Boundary overlays (rebuild when boundaries change)
        let boundaryIDs = document.boundaries.map(\.id)
        if boundaryIDs != coord.lastBoundaryIDs {
            coord.lastBoundaryIDs = boundaryIDs
            rebuildBoundaryOverlays(map)
        }
    }

    private func rebuildBoundaryOverlays(_ map: MKMapView) {
        map.removeOverlays(map.overlays.filter { $0 is MKPolygon })
        for boundary in document.boundaries {
            for ring in boundary.polygonRings {
                var coords = ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                let polygon = MKPolygon(coordinates: &coords, count: coords.count)
                polygon.title = "boundary"
                map.addOverlay(polygon, level: .aboveRoads)
            }
        }
    }

    private func rebuildOverlays(_ map: MKMapView) {
        let selectedID = viewModel.selectedMarkerID
        map.removeOverlays(map.overlays.filter { $0 is MKCircle })
        for m in document.markers {
            let s = m.id == selectedID ? "-sel" : ""
            var overlays: [MKOverlay] = []
            if viewModel.showLSV        { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.outer);       o.title = "outer\(s)";       overlays.append(o) }
            if viewModel.showBike       { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.middle);      o.title = "middle\(s)";      overlays.append(o) }
            if viewModel.showSafeRoutes { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.safeRoutes); o.title = "safeRoutes\(s)"; overlays.append(o) }
            if viewModel.showWalk       { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.inner);       o.title = "inner\(s)";       overlays.append(o) }
            map.addOverlays(overlays)
        }
    }

    private func rebuildAnnotations(_ map: MKMapView) {
        let existing = map.annotations.compactMap { $0 as? BullseyeAnnotation }
        let existingIDs = Set(existing.map(\.marker.id))
        let wantedIDs   = Set(document.markers.map(\.id))

        map.removeAnnotations(existing.filter { !wantedIDs.contains($0.marker.id) })
        let toAdd = document.markers.filter { !existingIDs.contains($0.id) }
        map.addAnnotations(toAdd.map { BullseyeAnnotation(marker: $0) })
    }

    func makeCoordinator() -> Coordinator { Coordinator(document: $document, viewModel: viewModel) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var document: Binding<MapDocument>
        let viewModel: MapViewModel
        var lastNavTrigger: UUID?
        var lastMarkerIDs: [UUID] = []
        var lastMarkerKeys: [String] = []   // "\(id):\(label)" — detects label edits
        var lastRingToggles: (Bool, Bool, Bool, Bool) = (true, true, true, true)
        var lastSelectedID: UUID? = nil
        var lastBoundaryIDs: [UUID] = []
        weak var tapGesture: NSClickGestureRecognizer?

        init(document: Binding<MapDocument>, viewModel: MapViewModel) {
            self.document = document
            self.viewModel = viewModel
        }

        // MARK: Tap placement

        @objc func handleTap(_ gr: NSClickGestureRecognizer) {
            guard let map = gr.view as? MKMapView else { return }
            let pt = gr.location(in: map)

            for ann in map.annotations {
                if let av = map.view(for: ann), av.frame.contains(pt) { return }
            }

            let coord = map.convert(pt, toCoordinateFrom: map)
            Task { @MainActor in
                self.document.wrappedValue.markers.append(
                    BullseyeMarker(latitude: coord.latitude, longitude: coord.longitude)
                )
            }
        }

        func gestureRecognizer(_ gr: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }

        // MARK: Overlay renderer

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: polygon)
                r.strokeColor = NSColor.systemPurple.withAlphaComponent(0.75)
                r.fillColor   = Self.hatchFill(color: NSColor.systemPurple.withAlphaComponent(0.30), spacing: 8)
                r.lineWidth   = 1.5
                r.lineDashPattern = [6, 4]
                return r
            }

            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }

            let r = MKCircleRenderer(circle: circle)
            let title = circle.title ?? ""
            let sel = title.hasSuffix("-sel")
            let base = sel ? String(title.dropLast(4)) : title
            r.lineWidth = sel ? 1.5 : 1.0

            switch base {
            case "inner":
                r.strokeColor = NSColor.systemRed.withAlphaComponent(sel ? 0.85 : 0.5)
                r.fillColor   = NSColor.systemRed.withAlphaComponent(sel ? 0.38 : 0.20)
            case "safeRoutes":
                let teal = NSColor(red: 0.0, green: 0.62, blue: 0.72, alpha: 1.0)
                r.strokeColor = teal.withAlphaComponent(sel ? 0.90 : 0.60)
                r.fillColor   = teal.withAlphaComponent(sel ? 0.32 : 0.17)
            case "middle":
                r.strokeColor = NSColor.systemOrange.withAlphaComponent(sel ? 0.85 : 0.5)
                r.fillColor   = NSColor.systemOrange.withAlphaComponent(sel ? 0.32 : 0.17)
            case "outer":
                r.strokeColor = NSColor.systemBlue.withAlphaComponent(sel ? 0.85 : 0.5)
                r.fillColor   = NSColor.systemBlue.withAlphaComponent(sel ? 0.26 : 0.14)
            default:
                r.strokeColor = .gray
            }
            return r
        }

        // MARK: Annotation view

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? BullseyeAnnotation else { return nil }

            let reuseID = "bullseye"
            let view = map.dequeueReusableAnnotationView(withIdentifier: reuseID)
                     ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation = annotation
            view.canShowCallout = true

            let sel = ann.marker.id == viewModel.selectedMarkerID
            let (icon, offsetY) = Self.bullseyeIcon(selected: sel, label: ann.marker.label)
            view.image = icon
            view.centerOffset = CGPoint(x: 0, y: offsetY)

            let btn = MarkerButton(title: "Delete", target: self, action: #selector(deleteMarker(_:)))
            btn.bezelStyle = .rounded
            btn.annotation = ann
            view.rightCalloutAccessoryView = btn
            return view
        }

        @objc fileprivate func deleteMarker(_ sender: MarkerButton) {
            guard let ann = sender.annotation else { return }
            Task { @MainActor in
                self.document.wrappedValue.markers.removeAll { $0.id == ann.marker.id }
            }
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? BullseyeAnnotation else { return }
            Task { @MainActor in self.viewModel.selectedMarkerID = ann.marker.id }
        }

        func mapView(_ map: MKMapView, didDeselect view: MKAnnotationView) {
            guard view.annotation is BullseyeAnnotation else { return }
            Task { @MainActor in self.viewModel.selectedMarkerID = nil }
        }

        func mapView(_ map: MKMapView, annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: NSControl) {
            guard let ann = view.annotation as? BullseyeAnnotation else { return }
            Task { @MainActor in
                self.document.wrappedValue.markers.removeAll { $0.id == ann.marker.id }
            }
        }

        // MARK: Region tracking — persist viewport to document when pan/zoom ends

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = map.region
            Task { @MainActor in
                document.wrappedValue.centerLatitude  = region.center.latitude
                document.wrappedValue.centerLongitude = region.center.longitude
                document.wrappedValue.spanLatDelta    = region.span.latitudeDelta
                document.wrappedValue.spanLonDelta    = region.span.longitudeDelta
            }
        }

        // MARK: Hatch fill

        // Returns a pattern NSColor that draws evenly-spaced 45° diagonal lines.
        // A square tile of `spacing` points contains one corner-to-corner diagonal;
        // tiling produces parallel stripes with perpendicular spacing of spacing/√2.
        private static func hatchFill(color: NSColor, spacing: CGFloat) -> NSColor {
            let image = NSImage(size: NSSize(width: spacing, height: spacing), flipped: false) { _ in
                NSColor.clear.set()
                NSBezierPath.fill(NSRect(x: 0, y: 0, width: spacing, height: spacing))
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1.0
                path.move(to: NSPoint(x: 0, y: 0))
                path.line(to: NSPoint(x: spacing, y: spacing))
                path.stroke()
                return true
            }
            return NSColor(patternImage: image)
        }

        // MARK: Icon

        // Returns the composite icon image (bullseye + optional label pill below)
        // and the centerOffset.y that pins the icon's bottom to the map coordinate.
        static func bullseyeIcon(selected: Bool, label: String = "") -> (image: NSImage, offsetY: CGFloat) {
            let dim: CGFloat    = selected ? 36   : 14
            let lineW: CGFloat  = selected ? 3.0  : 1.0
            let dotR: CGFloat   = selected ? 5.0  : 1.5
            let gap: CGFloat    = selected ? 7.5  : 3.0
            let margin: CGFloat = selected ? 4    : 1.5
            let alpha: CGFloat  = selected ? 1.0  : 0.22
            let color: NSColor  = NSColor.systemRed.withAlphaComponent(alpha)

            // Measure label
            let labelGap: CGFloat = 2
            let font = NSFont.systemFont(ofSize: selected ? 10 : 9,
                                         weight: selected ? .medium : .regular)
            var labelSize = CGSize.zero
            if !label.isEmpty {
                let m = (label as NSString).size(withAttributes: [.font: font])
                labelSize = CGSize(width: ceil(m.width) + 8, height: ceil(m.height) + 4)
            }

            let labelExtra = labelSize.height > 0 ? labelGap + labelSize.height : 0
            let totalW = max(dim, labelSize.width)
            let totalH = dim + labelExtra

            // centerOffset.y that keeps the icon's bottom edge at the coordinate:
            //   center is at totalH/2 above image bottom; icon bottom is at labelExtra above image bottom.
            //   distance from center to icon bottom = totalH/2 - labelExtra = (dim - labelExtra)/2
            //   we want icon bottom at coordinate → center must be (dim - labelExtra)/2 above coordinate
            let offsetY = -(dim - labelExtra) / 2

            let image = NSImage(size: NSSize(width: totalW, height: totalH), flipped: false) { _ in
                // ── Bullseye icon (upper region of canvas) ──────────────
                NSGraphicsContext.current?.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: (totalW - dim) / 2, yBy: labelExtra)
                t.concat()

                let cx = dim / 2, cy = dim / 2
                color.set()

                let ring = NSBezierPath(ovalIn: NSRect(x: lineW/2 + 0.5, y: lineW/2 + 0.5,
                                                        width: dim - lineW - 1, height: dim - lineW - 1))
                ring.lineWidth = lineW
                ring.stroke()

                NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR,
                                            width: dotR * 2, height: dotR * 2)).fill()

                let lines = NSBezierPath()
                lines.move(to: NSPoint(x: margin,     y: cy)); lines.line(to: NSPoint(x: cx - gap,       y: cy))
                lines.move(to: NSPoint(x: cx + gap,   y: cy)); lines.line(to: NSPoint(x: dim - margin,   y: cy))
                lines.move(to: NSPoint(x: cx, y: margin));     lines.line(to: NSPoint(x: cx,             y: cy - gap))
                lines.move(to: NSPoint(x: cx, y: cy + gap));   lines.line(to: NSPoint(x: cx,             y: dim - margin))
                lines.lineWidth = selected ? 2.5 : 0.75
                lines.stroke()

                NSGraphicsContext.current?.restoreGraphicsState()

                // ── Label pill (lower region of canvas) ─────────────────
                if labelSize.height > 0 {
                    let lx = (totalW - labelSize.width) / 2
                    let pill = NSBezierPath(roundedRect: NSRect(x: lx, y: 0,
                                                                width: labelSize.width, height: labelSize.height),
                                            xRadius: 3, yRadius: 3)
                    NSColor.black.withAlphaComponent(selected ? 0.65 : 0.50).set()
                    pill.fill()

                    (label as NSString).draw(
                        in: NSRect(x: lx + 4, y: 2, width: labelSize.width - 8, height: labelSize.height - 4),
                        withAttributes: [.font: font, .foregroundColor: NSColor.white]
                    )
                }
                return true
            }
            return (image: image, offsetY: offsetY)
        }
    }
}
