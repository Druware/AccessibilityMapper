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
    @ObservedObject var viewModel: MapViewModel

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(viewModel.navigationRegion, animated: false)

        let tap = NSClickGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.isEnabled = viewModel.isPlacingBullseye
        map.addGestureRecognizer(tap)
        context.coordinator.tapGesture = tap

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coord = context.coordinator

        // Navigate when triggered
        if coord.lastNavTrigger != viewModel.navigationTrigger {
            coord.lastNavTrigger = viewModel.navigationTrigger
            map.setRegion(viewModel.navigationRegion, animated: true)
        }

        // Map style
        if map.mapType != viewModel.mkMapType { map.mapType = viewModel.mkMapType }

        // Placement cursor
        coord.tapGesture?.isEnabled = viewModel.isPlacingBullseye

        // Overlays & annotations (rebuild when markers or ring toggles change)
        let ids = viewModel.markers.map(\.id)
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

    // Remove all circles and re-add; respects ring visibility toggles.
    private func rebuildOverlays(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        for m in viewModel.markers {
            var overlays: [MKOverlay] = []
            if viewModel.showLSV        { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.outer);       o.title = "outer";       overlays.append(o) }
            if viewModel.showBike       { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.middle);      o.title = "middle";      overlays.append(o) }
            if viewModel.showSafeRoutes { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.safeRoutes); o.title = "safeRoutes"; overlays.append(o) }
            if viewModel.showWalk       { let o = MKCircle(center: m.coordinate, radius: BullseyeMarker.Radii.inner);       o.title = "inner";       overlays.append(o) }
            map.addOverlays(overlays)
        }
    }

    // Diff annotations to avoid removing callouts unnecessarily.
    private func rebuildAnnotations(_ map: MKMapView) {
        let existing = map.annotations.compactMap { $0 as? BullseyeAnnotation }
        let existingIDs = Set(existing.map(\.marker.id))
        let wantedIDs   = Set(viewModel.markers.map(\.id))

        map.removeAnnotations(existing.filter { !wantedIDs.contains($0.marker.id) })
        let toAdd = viewModel.markers.filter { !existingIDs.contains($0.id) }
        map.addAnnotations(toAdd.map { BullseyeAnnotation(marker: $0) })
    }

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        let viewModel: MapViewModel
        var lastNavTrigger: UUID?
        var lastMarkerIDs: [UUID] = []
        var lastRingToggles: (Bool, Bool, Bool, Bool) = (true, true, true, true)
        weak var tapGesture: NSClickGestureRecognizer?

        init(viewModel: MapViewModel) { self.viewModel = viewModel }

        // MARK: Tap placement

        @objc func handleTap(_ gr: NSClickGestureRecognizer) {
            guard let map = gr.view as? MKMapView else { return }
            let pt = gr.location(in: map)

            // Don't create a marker when tapping an existing annotation pin
            for ann in map.annotations {
                if let av = map.view(for: ann), av.frame.contains(pt) { return }
            }

            let coord = map.convert(pt, toCoordinateFrom: map)
            Task { @MainActor in self.viewModel.addMarker(at: coord) }
        }

        // Allow our recognizer to coexist with MapKit's pan/zoom gestures
        func gestureRecognizer(_ gr: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }

        // MARK: Overlay renderer

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }

            let r = MKCircleRenderer(circle: circle)
            r.lineWidth = 2.5

            switch circle.title {
            case "inner":
                r.strokeColor = NSColor.systemRed
                r.fillColor   = NSColor.systemRed.withAlphaComponent(0.25)
            case "safeRoutes":
                r.strokeColor = NSColor.systemGreen
                r.fillColor   = NSColor.systemGreen.withAlphaComponent(0.18)
            case "middle":
                r.strokeColor = NSColor.systemOrange
                r.fillColor   = NSColor.systemOrange.withAlphaComponent(0.18)
            case "outer":
                r.strokeColor = NSColor.systemBlue
                r.fillColor   = NSColor.systemBlue.withAlphaComponent(0.12)
            default:
                r.strokeColor = .gray
            }
            return r
        }

        // MARK: Annotation view

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is BullseyeAnnotation else { return nil }

            let reuseID = "bullseye"
            let view = map.dequeueReusableAnnotationView(withIdentifier: reuseID)
                     ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation   = annotation
            view.canShowCallout = true
            view.image        = Self.bullseyeIcon
            view.centerOffset = CGPoint(x: 0, y: -12)

            let btn = NSButton(title: "Delete", target: nil, action: nil)
            btn.bezelStyle = .rounded
            view.rightCalloutAccessoryView = btn
            return view
        }

        func mapView(_ map: MKMapView, annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: NSControl) {
            guard let ann = view.annotation as? BullseyeAnnotation else { return }
            Task { @MainActor in self.viewModel.removeMarker(id: ann.marker.id) }
        }

        // MARK: Region tracking

        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            viewModel.currentRegion = map.region
        }

        // MARK: Icon

        private static let bullseyeIcon: NSImage = {
            let size = NSSize(width: 24, height: 24)
            return NSImage(size: size, flipped: false) { r in
                let cx = r.midX, cy = r.midY
                NSColor.systemRed.set()

                // Outer ring
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 2
                ring.stroke()

                // Center dot
                NSBezierPath(ovalIn: NSRect(x: cx-3, y: cy-3, width: 6, height: 6)).fill()

                // Crosshair lines (with gap around center dot)
                let gap: CGFloat = 4.5
                let lines = NSBezierPath()
                lines.move(to: NSPoint(x: r.minX + 3, y: cy)); lines.line(to: NSPoint(x: cx - gap, y: cy))
                lines.move(to: NSPoint(x: cx + gap, y: cy));   lines.line(to: NSPoint(x: r.maxX - 3, y: cy))
                lines.move(to: NSPoint(x: cx, y: r.minY + 3)); lines.line(to: NSPoint(x: cx, y: cy - gap))
                lines.move(to: NSPoint(x: cx, y: cy + gap));   lines.line(to: NSPoint(x: cx, y: r.maxY - 3))
                lines.lineWidth = 1.5
                lines.stroke()
                return true
            }
        }()
    }
}
