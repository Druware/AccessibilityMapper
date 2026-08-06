// Accessibility Mapper - MapLibre GL bridge (see docs/MAP-BRIDGE.md for the wire contract).
//
// The host contract is unchanged from the Leaflet implementation this replaced: the same
// inbound message types, the same outbound events, the same [lon, lat] ring order on
// boundaries. Nothing in Views/MapControl.xaml.cs had to move.

// Namespace import: MapLibre GL 6 is ESM with named exports and no default export.
import * as maplibregl from './maplibre-gl.mjs';

const ZONES = [
  // Draw order: LSV -> Bike -> SafeRoutes -> Walk, so Walk ends up on top (CONVERSION-SPEC.md §2).
  { key: 'lsv', radius: 4828.032, color: '#007AFF', strokeOpacity: 0.5, strokeOpacitySel: 0.85, fillOpacity: 0.14, fillOpacitySel: 0.26, weight: 1.0, weightSel: 1.5 },
  { key: 'bike', radius: 3218.688, color: '#FF9500', strokeOpacity: 0.5, strokeOpacitySel: 0.85, fillOpacity: 0.17, fillOpacitySel: 0.32, weight: 1.0, weightSel: 1.5 },
  { key: 'safeRoutes', radius: 1609.344, color: '#009EB8', strokeOpacity: 0.60, strokeOpacitySel: 0.90, fillOpacity: 0.17, fillOpacitySel: 0.32, weight: 1.0, weightSel: 1.5 },
  { key: 'walk', radius: 804.672, color: '#FF3B30', strokeOpacity: 0.5, strokeOpacitySel: 0.85, fillOpacity: 0.20, fillOpacitySel: 0.38, weight: 1.0, weightSel: 1.5 }
];

const DEFAULT_CENTER = [37.3318, -122.0312]; // [lat, lon], as the host sends it
const DEFAULT_SPAN = [0.15, 0.15];

// OpenFreeMap: OpenStreetMap vector tiles, no API key, no registration, no request limit.
// Replaces OSM's own raster tile servers, whose usage policy forbids distributed app use.
const STREET_STYLE = 'https://tiles.openfreemap.org/styles/liberty';

// USGS The National Map: public domain US Government orthoimagery. The caches stop at z16,
// so `maxzoom` is set there and MapLibre overzooms past it - deep zoom softens rather than
// going blank, which is what maxNativeZoom did under Leaflet.
const USGS_ATTRIBUTION =
  'Imagery courtesy of the <a href="https://www.usgs.gov/programs/national-geospatial-program/national-map">USGS National Map</a>';
const RASTER_STYLES = {
  1: 'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}',
  2: 'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}'
};

const BOUNDARY_SOURCE = 'boundaries';

let map;
let placing = false;
let selectedId = null;
let zoneVisibility = { walk: true, safeRoutes: true, bike: true, lsv: true };
let markersById = new Map();
let boundariesData = [];
let currentMapType = 0;

// Style swaps drop every source and layer, so overlays are rebuilt on each style load and
// nothing may touch them until that has happened.
let overlaysReady = false;

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function postToHost(msg) {
  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.postMessage(msg);
  }
}

function metersToDegreeDeltas(lat, meters) {
  const metersPerDegreeLat = 111320.0;
  const metersPerDegreeLon = 111320.0 * Math.cos(lat * Math.PI / 180);
  return { dLat: meters / metersPerDegreeLat, dLon: meters / metersPerDegreeLon };
}

// MapLibre's circle layer takes a radius in pixels, so the zone rings - which are fixed
// distances on the ground - have to be real polygons instead.
function circleRing(lat, lon, meters, steps = 96) {
  const { dLat, dLon } = metersToDegreeDeltas(lat, meters);
  const ring = [];
  for (let i = 0; i <= steps; i++) {
    const t = (i / steps) * 2 * Math.PI;
    ring.push([lon + dLon * Math.cos(t), lat + dLat * Math.sin(t)]);
  }
  return ring;
}

const emptyCollection = () => ({ type: 'FeatureCollection', features: [] });

const zoneSourceId = key => `zone-${key}`;
const zoneFillId = key => `zone-${key}-fill`;
const zoneLineId = key => `zone-${key}-line`;

// ---- Styles -------------------------------------------------

function styleFor(mapType) {
  const tiles = RASTER_STYLES[mapType];
  if (!tiles) return STREET_STYLE;

  return {
    version: 8,
    sources: {
      usgs: {
        type: 'raster',
        tiles: [tiles],
        tileSize: 256,
        maxzoom: 16,
        attribution: USGS_ATTRIBUTION
      }
    },
    layers: [{ id: 'usgs-raster', type: 'raster', source: 'usgs' }]
  };
}

function addOverlays() {
  // Boundaries first so they sit under the zone rings, which is what the dedicated
  // low-z-index pane did under Leaflet (CONVERSION-SPEC.md §7 rendering notes).
  map.addSource(BOUNDARY_SOURCE, { type: 'geojson', data: emptyCollection() });
  map.addLayer({
    id: 'boundaries-fill',
    type: 'fill',
    source: BOUNDARY_SOURCE,
    paint: { 'fill-color': '#AF52DE', 'fill-opacity': 0.30 }
  });
  map.addLayer({
    id: 'boundaries-line',
    type: 'line',
    source: BOUNDARY_SOURCE,
    paint: {
      'line-color': '#AF52DE',
      'line-width': 1.5,
      'line-opacity': 0.75,
      'line-dasharray': [6, 4]
    }
  });

  // ZONES is already in draw order, so adding in sequence puts Walk on top.
  ZONES.forEach(zone => {
    const visibility = zoneVisibility[zone.key] ? 'visible' : 'none';
    map.addSource(zoneSourceId(zone.key), { type: 'geojson', data: emptyCollection() });

    // Selection is a feature property rather than a separate layer, so selecting a marker
    // is a setData call and never a layer rebuild.
    map.addLayer({
      id: zoneFillId(zone.key),
      type: 'fill',
      source: zoneSourceId(zone.key),
      layout: { visibility },
      paint: {
        'fill-color': zone.color,
        'fill-opacity': ['case', ['get', 'selected'], zone.fillOpacitySel, zone.fillOpacity]
      }
    });
    map.addLayer({
      id: zoneLineId(zone.key),
      type: 'line',
      source: zoneSourceId(zone.key),
      layout: { visibility },
      paint: {
        'line-color': zone.color,
        'line-width': ['case', ['get', 'selected'], zone.weightSel, zone.weight],
        'line-opacity': ['case', ['get', 'selected'], zone.strokeOpacitySel, zone.strokeOpacity]
      }
    });
  });

  overlaysReady = true;
  pushZoneData();
  pushBoundaryData();
}

function setMapType(mapType) {
  const next = mapType ?? 0;
  if (next === currentMapType && overlaysReady) return;
  currentMapType = next;
  overlaysReady = false;
  map.setStyle(styleFor(next));
}

// ---- Markers / bullseyes -------------------------------------------------

function buildMarkerElement(label, selected) {
  const dim = selected ? 36 : 14;
  const opacity = selected ? 1.0 : 0.22;
  const borderW = selected ? 3 : 1;

  const glyph = `<div class="bullseye-glyph" style="width:${dim}px;height:${dim}px;opacity:${opacity};border-width:${borderW}px;"></div>`;
  const pill = label ? `<div class="label-pill${selected ? ' selected' : ''}">${escapeHtml(label)}</div>` : '';

  const wrap = document.createElement('div');
  wrap.className = 'icon-wrap';
  wrap.innerHTML = `${glyph}${pill}`;
  return { element: wrap, dim };
}

function popupHtml(id, lat, lon, label) {
  const title = label && label.length > 0 ? escapeHtml(label) : 'Accessible Location';
  const subtitle = `${lat.toFixed(5)},  ${lon.toFixed(5)}`;
  return `<div class="marker-popup"><div class="popup-title">${title}</div><div class="popup-subtitle">${subtitle}</div><button class="popup-delete" data-id="${id}">Delete</button></div>`;
}

function addMarkerVisual(data) {
  const selected = data.id === selectedId;
  const { element, dim } = buildMarkerElement(data.label, selected);

  element.addEventListener('click', event => {
    // Markers are DOM siblings above the canvas, so this never reaches the map's own
    // click handler; stopping propagation keeps it that way if that ever changes.
    event.stopPropagation();
    if (!placing) postToHost({ type: 'selectMarker', id: data.id });
  });

  const popup = new maplibregl.Popup({ offset: 14, closeButton: true })
    .setHTML(popupHtml(data.id, data.lat, data.lon, data.label));

  popup.on('open', () => {
    const button = popup.getElement()?.querySelector('.popup-delete');
    if (button) {
      button.addEventListener('click', () => {
        postToHost({ type: 'removeMarker', id: data.id });
        popup.remove();
      }, { once: true });
    }
  });

  // anchor/offset reproduce Leaflet's iconAnchor of [width/2, dim]: the coordinate sits at
  // the bottom edge of the bullseye, with the label pill hanging below it.
  const marker = new maplibregl.Marker({ element, anchor: 'top', offset: [0, -dim] })
    .setLngLat([data.lon, data.lat])
    .setPopup(popup)
    .addTo(map);

  markersById.set(data.id, { data, marker, popup });
}

function removeMarkerVisual(id) {
  const entry = markersById.get(id);
  if (!entry) return;
  entry.marker.remove();
  markersById.delete(id);
}

function rebuildMarkers(markersData) {
  Array.from(markersById.keys()).forEach(removeMarkerVisual);
  (markersData || []).forEach(addMarkerVisual);
  pushZoneData();
}

function pushZoneData() {
  if (!overlaysReady) return;

  ZONES.forEach(zone => {
    const features = [];
    markersById.forEach(entry => {
      features.push({
        type: 'Feature',
        properties: { selected: entry.data.id === selectedId },
        geometry: {
          type: 'Polygon',
          coordinates: [circleRing(entry.data.lat, entry.data.lon, zone.radius)]
        }
      });
    });
    map.getSource(zoneSourceId(zone.key))?.setData({ type: 'FeatureCollection', features });
  });
}

function applyZoneVisibility() {
  if (!overlaysReady) return;
  ZONES.forEach(zone => {
    const visibility = zoneVisibility[zone.key] ? 'visible' : 'none';
    map.setLayoutProperty(zoneFillId(zone.key), 'visibility', visibility);
    map.setLayoutProperty(zoneLineId(zone.key), 'visibility', visibility);
  });
}

function applySelection() {
  // The glyph changes size with selection, so the element and its offset are rebuilt.
  markersById.forEach(entry => {
    const selected = entry.data.id === selectedId;
    const { element, dim } = buildMarkerElement(entry.data.label, selected);

    element.addEventListener('click', event => {
      event.stopPropagation();
      if (!placing) postToHost({ type: 'selectMarker', id: entry.data.id });
    });

    entry.marker.remove();
    entry.marker = new maplibregl.Marker({ element, anchor: 'top', offset: [0, -dim] })
      .setLngLat([entry.data.lon, entry.data.lat])
      .setPopup(entry.popup)
      .addTo(map);
  });

  pushZoneData();
}

// ---- Boundaries -------------------------------------------------

function rebuildBoundaries(boundaries) {
  boundariesData = boundaries || [];
  pushBoundaryData();
}

function pushBoundaryData() {
  if (!overlaysReady) return;

  const features = [];
  boundariesData.forEach(boundary => {
    // Rings arrive as GeoJSON [lon, lat] already, so unlike Leaflet nothing is flipped.
    (boundary.rings || []).forEach(ring => {
      features.push({
        type: 'Feature',
        properties: {},
        geometry: { type: 'Polygon', coordinates: [ring] }
      });
    });
  });

  map.getSource(BOUNDARY_SOURCE)?.setData({ type: 'FeatureCollection', features });
}

// ---- Viewport -------------------------------------------------

function fitCenterSpan(centerLat, centerLon, spanLat, spanLon, animate) {
  map.fitBounds(
    [
      [centerLon - spanLon / 2, centerLat - spanLat / 2],
      [centerLon + spanLon / 2, centerLat + spanLat / 2]
    ],
    { animate, duration: animate ? 800 : 0 }
  );
}

function applyViewMessage(view) {
  const center = (view && view.center) || DEFAULT_CENTER;
  const span = (view && view.span) || DEFAULT_SPAN;
  fitCenterSpan(center[0], center[1], span[0] || 0.01, span[1] || 0.01, false);
}

function applyFlyTo(msg) {
  if (msg.tight) {
    fitCenterSpan(msg.lat, msg.lon, 0.05, 0.05, true);
    return;
  }
  const d = metersToDegreeDeltas(msg.lat, 4500);
  fitCenterSpan(msg.lat, msg.lon, d.dLat * 2, d.dLon * 2, true);
}

// ---- Inbound bridge handlers -------------------------------------------------

function onHostMessage(msg) {
  if (!msg || !msg.type) return;

  switch (msg.type) {
    case 'init':
      zoneVisibility = msg.zones || zoneVisibility;
      selectedId = msg.selectedId || null;
      setMapType(msg.mapType ?? 0);
      rebuildBoundaries(msg.boundaries);
      rebuildMarkers(msg.markers);
      applyZoneVisibility();
      applyViewMessage(msg.view);
      break;

    case 'setMarkers':
      selectedId = msg.selectedId || null;
      rebuildMarkers(msg.markers);
      break;

    case 'setSelected':
      selectedId = msg.id || null;
      applySelection();
      break;

    case 'setZones':
      zoneVisibility = { walk: msg.walk, safeRoutes: msg.safeRoutes, bike: msg.bike, lsv: msg.lsv };
      applyZoneVisibility();
      break;

    case 'setMode':
      placing = !!msg.placing;
      break;

    case 'setBoundaries':
      rebuildBoundaries(msg.boundaries);
      break;

    case 'setMapType':
      setMapType(msg.mapType ?? 0);
      break;

    case 'flyTo':
      applyFlyTo(msg);
      break;
  }
}

// ---- Boot -------------------------------------------------

function initMap() {
  map = new maplibregl.Map({
    container: 'map',
    style: styleFor(0),
    center: [DEFAULT_CENTER[1], DEFAULT_CENTER[0]],
    zoom: 11,
    attributionControl: { compact: false }
  });

  map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-left');

  // Fires on the first style and again after every setStyle, which is exactly when the
  // overlay sources and layers need putting back.
  map.on('style.load', addOverlays);

  map.on('click', e => {
    if (placing) {
      postToHost({ type: 'addMarker', lat: e.lngLat.lat, lon: e.lngLat.lng });
    } else {
      postToHost({ type: 'deselect' });
    }
  });

  map.on('moveend', () => {
    const center = map.getCenter();
    const bounds = map.getBounds();
    postToHost({
      type: 'viewportChanged',
      centerLat: center.lat,
      centerLon: center.lng,
      spanLatDelta: bounds.getNorth() - bounds.getSouth(),
      spanLonDelta: bounds.getEast() - bounds.getWest()
    });
  });

  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.addEventListener('message', event => onHostMessage(event.data));
  }

  map.on('load', () => postToHost({ type: 'ready' }));
}

try {
  initMap();
} catch (err) {
  // Most likely no WebGL in the WebView. Leave something readable on screen rather than a
  // blank surface, and still report ready so the host is not left waiting forever.
  const banner = document.getElementById('map-error');
  banner.style.display = 'block';
  banner.textContent = `The map could not be initialised: ${err && err.message ? err.message : err}`;
  postToHost({ type: 'ready' });
}
