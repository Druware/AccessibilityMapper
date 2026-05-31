//  MapView.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


import SwiftUI
import MapKit
import AppKit

// MARK: - Annotation model

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

        // Populate markers immediately so they're visible on first render / document load
        if !document.markers.isEmpty {
            map.addAnnotations(document.markers.map { BullseyeAnnotation(marker: $0) })
            rebuildOverlays(map)
            context.coordinator.lastMarkerIDs = document.markers.map(\.id)
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
            for ann in map.annotations.compactMap({ $0 as? BullseyeAnnotation }) {
                guard let av = map.view(for: ann) else { continue }
                let sel = ann.marker.id == next
                av.image = Coordinator.bullseyeIcon(selected: sel)
                av.centerOffset = CGPoint(x: 0, y: sel ? -18 : -7)
            }
            rebuildOverlays(map)
        }

        // Overlays & annotations (rebuild when markers or ring toggles change)
        let ids = document.markers.map(\.id)
        let toggles = (viewModel.showWalk, viewModel.showSafeRoutes, viewModel.showBike, viewModel.showLSV)
        let markersChanged = ids != coord.lastMarkerIDs
        let togglesChanged = toggles != coord.lastRingToggles
        if markersChanged || togglesChanged {
            coord.lastMarkerIDs    = ids
            coord.lastRingToggles  = toggles
            rebuildOverlays(map)
            if markersChanged { rebuildAnnotations(map) }
        }
    }

    private func rebuildOverlays(_ map: MKMapView) {
        let selectedID = viewModel.selectedMarkerID
        map.removeOverlays(map.overlays)
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
        var lastRingToggles: (Bool, Bool, Bool, Bool) = (true, true, true, true)
        var lastSelectedID: UUID? = nil
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
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }

            let r = MKCircleRenderer(circle: circle)
            let title = circle.title ?? ""
            let sel = title.hasSuffix("-sel")
            let base = sel ? String(title.dropLast(4)) : title
            r.lineWidth = sel ? 1.5 : 1.0

            switch base {
            case "inner":
                r.strokeColor = NSColor.systemRed.withAlphaComponent(sel ? 0.85 : 0.5)
                r.fillColor   = NSColor.systemRed.withAlphaComponent(sel ? 0.20 : 0.07)
            case "safeRoutes":
                r.strokeColor = NSColor.systemGreen.withAlphaComponent(sel ? 0.85 : 0.5)
                r.fillColor   = NSColor.systemGreen.withAlphaComponent(sel ? 0.16 : 0.06)
            case "middle":
                r.strokeColor = NSColor.systemOrange.withAlphaComponent(sel ? 0.85 : 0.5)
                r.fillColor   = NSColor.systemOrange.withAlphaComponent(sel ? 0.16 : 0.06)
            case "outer":
                r.strokeColor = NSColor.systemBlue.withAlphaComponent(sel ? 0.85 : 0.5)
                r.fillColor   = NSColor.systemBlue.withAlphaComponent(sel ? 0.12 : 0.04)
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
            view.image = Self.bullseyeIcon(selected: sel)
            view.centerOffset = CGPoint(x: 0, y: sel ? -18 : -7)

            let btn = NSButton(title: "Delete", target: nil, action: nil)
            btn.bezelStyle = .rounded
            view.rightCalloutAccessoryView = btn
            return view
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

        // MARK: Icon

        static func bullseyeIcon(selected: Bool) -> NSImage {
            let dim: CGFloat    = selected ? 36   : 14
            let lineW: CGFloat  = selected ? 3.0  : 1.0
            let dotR: CGFloat   = selected ? 5.0  : 1.5
            let gap: CGFloat    = selected ? 7.5  : 3.0
            let margin: CGFloat = selected ? 4    : 1.5
            let alpha: CGFloat  = selected ? 1.0  : 0.22
            let color: NSColor  = NSColor.systemRed.withAlphaComponent(alpha)

            return NSImage(size: NSSize(width: dim, height: dim), flipped: false) { r in
                let cx = r.midX, cy = r.midY
                color.set()

                let ring = NSBezierPath(ovalIn: r.insetBy(dx: lineW / 2 + 0.5, dy: lineW / 2 + 0.5))
                ring.lineWidth = lineW
                ring.stroke()

                NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR,
                                            width: dotR * 2, height: dotR * 2)).fill()

                let lines = NSBezierPath()
                lines.move(to: NSPoint(x: r.minX + margin, y: cy)); lines.line(to: NSPoint(x: cx - gap, y: cy))
                lines.move(to: NSPoint(x: cx + gap,        y: cy)); lines.line(to: NSPoint(x: r.maxX - margin, y: cy))
                lines.move(to: NSPoint(x: cx, y: r.minY + margin)); lines.line(to: NSPoint(x: cx, y: cy - gap))
                lines.move(to: NSPoint(x: cx, y: cy + gap));        lines.line(to: NSPoint(x: cx, y: r.maxY - margin))
                lines.lineWidth = selected ? 2.5 : 0.75
                lines.stroke()
                return true
            }
        }
    }
}
