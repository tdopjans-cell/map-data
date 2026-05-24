// Automatic FlutterFlow imports
import '/backend/supabase/supabase.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart' hide LatLng;
import 'index.dart' hide LatLng;
import 'package:flutter/material.dart';
// Begin custom widget code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math' show Point;

class MapWebView extends StatefulWidget {
  const MapWebView({
    Key? key,
    this.width,
    this.height,
    required this.mapUrl,
    this.onMessageReceived,
    this.onControllerReady,
  }) : super(key: key);

  final double? width;
  final double? height;
  final String mapUrl;
  final Future Function(String message)? onMessageReceived;
  final void Function(
    Future<void> Function(String, String, String) highlight,
    void Function(bool) setLocked,
    Future<void> Function(double, double, double) flyTo,
    Future<void> Function(Map<String, dynamic>) updateAiStops,
    Future<void> Function(Map<String, dynamic>) updateRoute,
    Future<void> Function(Map<String, dynamic>) updateContainerPins,
  )? onControllerReady;

  @override
  State<MapWebView> createState() => MapWebViewState();
}

class MapWebViewState extends State<MapWebView> {
  maplibre.MapLibreMapController? _controller;
  String _currentLevel = 'europe';
  String _activeCountryId = '';
  String _lastLoadedCitiesCountry = '';
  bool _tapping = false;
  bool _locked = false;
  bool _absorbPointer = false;
  bool _styleLoaded = false;
  bool _mapFullyReady = false;
  final Map<String, String> _containerStates = {};
  final Set<String> _loadedRegions = {}; // Cache
  String _lastLoadedCountry = '';

  void _onMapCreated(maplibre.MapLibreMapController controller) {
    _controller = controller;
    _controller!.onFeatureTapped.add(_onFeatureTapped);
    widget.onControllerReady?.call(highlightFeature, setLocked, flyToPosition, updateAiStops, updateRoute, updateContainerPins);
  }

  void setLocked(bool locked) {
    _locked = locked;
    setState(() => _absorbPointer = locked);
  }

  Future<void> flyToPosition(double lat, double lng, double zoom) async {
    if (_controller == null) return;
    await _controller!.animateCamera(
      maplibre.CameraUpdate.newLatLngZoom(
        maplibre.LatLng(lat, lng),
        zoom,
      ),
    );
  }

  Future<void> updateAiStops(Map<String, dynamic> geojson) async {
    if (_controller == null) return;
    try {
      await _controller!.setGeoJsonSource('ai_stops', geojson);
    } catch (e) { debugPrint('❌ updateAiStops error: $e'); }
  }

  Future<void> updateRoute(Map<String, dynamic> geojson) async {
      if (_controller == null) return;
      try {
        await _controller!.setGeoJsonSource('route_line', geojson);
      } catch (e) { debugPrint('❌ updateRoute error: $e'); }
    }

  Future<void> updateContainerPins(Map<String, dynamic> geojson) async {
      if (_controller == null) return;
      try {
        await _controller!.setGeoJsonSource('container_pins', geojson);
      } catch (e) { debugPrint('❌ updateContainerPins error: $e'); }
    }

  Future<void> highlightFeature(String featureId, String layerId, String state) async {
    if (_controller == null) return;

    // Layer ID für Regionen anpassen
    final actualLayerId = layerId == 'de-states-fill' ? 'regions-fill' : layerId;
    final lineLayerId = actualLayerId == 'eu-countries-fill' ? 'eu-countries-line' : 'regions-line';

    _containerStates[featureId] = state;

    final selectedIds = _containerStates.entries.where((e) => e.value == 'selected').map((e) => e.key).toList();
    final preferIds = _containerStates.entries.where((e) => e.value == 'prefer').map((e) => e.key).toList();
    final neverIds = _containerStates.entries.where((e) => e.value == 'never').map((e) => e.key).toList();

    try {
      await _controller!.setLayerProperties(
        actualLayerId,
        maplibre.FillLayerProperties(
          fillColor: _buildMatchExpression(selectedIds, preferIds, neverIds),
          fillOpacity: _buildOpacityExpression(selectedIds, preferIds, neverIds),
        ),
      );
      await _controller!.setLayerProperties(
        lineLayerId,
        maplibre.LineLayerProperties(
          lineColor: selectedIds.isEmpty ? 'rgba(44,36,22,0.4)' : [
            'match', ['id'],
            ...selectedIds.expand((id) => [id, '#E8A838']),
            'rgba(44,36,22,0.4)',
          ],
          lineWidth: selectedIds.isEmpty ? 1.0 : [
            'match', ['id'],
            ...selectedIds.expand((id) => [id, 3.0]),
            1.0,
          ],
        ),
      );
    } catch (e) {
      debugPrint('❌ highlightFeature error: $e');
    }
  }

  List<dynamic> _buildMatchExpression(List<String> selectedIds, List<String> preferIds, List<String> neverIds) {
    final expr = <dynamic>['match', ['id']];
    for (final id in selectedIds) { expr.addAll([id, '#E8A838']); }
    for (final id in preferIds) { expr.addAll([id, '#5BA68A']); }
    for (final id in neverIds) { expr.addAll([id, '#BDBDBD']); }
    expr.add('#E8A838');
    return expr;
  }

  List<dynamic> _buildOpacityExpression(List<String> selectedIds, List<String> preferIds, List<String> neverIds) {
    final expr = <dynamic>['match', ['id']];
    for (final id in selectedIds) { expr.addAll([id, 0.15]); }
    for (final id in preferIds) { expr.addAll([id, 0.4]); }
    for (final id in neverIds) { expr.addAll([id, 0.4]); }
    expr.add(0.06);
    return expr;
  }

  void _onFeatureTapped(
    Point<double> point,
    maplibre.LatLng coordinates,
    String id,
    String layerId,
    maplibre.Annotation? annotation,
  ) {
    if (_tapping || _locked) return;
    _tapping = true;

    String placeLevel = '';
      if (layerId == 'eu-countries-fill') {
      placeLevel = 'country';
      _activeCountryId = id;
      _currentLevel = 'country';
    } else if (layerId == 'regions-fill') {
      placeLevel = 'region';
      _currentLevel = 'region';
    } else if (layerId == 'cities-circles') {
      placeLevel = 'city';
      _currentLevel = 'city';
    }

    if (placeLevel.isEmpty) {
      _tapping = false;
      return;
    }

    if (widget.onMessageReceived != null) {
      final msg = '{"type":"select","payload":{"id":"$id","place_level":"$placeLevel","lat":${coordinates.latitude},"lng":${coordinates.longitude}}}';
      widget.onMessageReceived!(msg).whenComplete(() {
        _tapping = false;
        _locked = false;
        setState(() => _absorbPointer = false);
      });
    } else {
      _tapping = false;
    }
  }

  Future<void> _onMapClick(Point<double> point, maplibre.LatLng coordinates) async {}

  Future<void> _onCameraIdle() async {
      if (!_styleLoaded || !_mapFullyReady) return;

      final zoom = _controller!.cameraPosition?.zoom ?? 0;

      if (zoom < 5.0) {
        if (_lastLoadedCountry.isNotEmpty) {
          _lastLoadedCountry = '';
          try {
            await _controller!.removeLayer('regions-fill');
            await _controller!.removeLayer('regions-line');
            await _controller!.removeLayer('regions-labels');
            await _controller!.removeSource('regions');
            await _controller!.addSource(
              'regions',
              maplibre.GeojsonSourceProperties(
                data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
                promoteId: 'iso_3166_2',
              ),
            );
            await _controller!.addFillLayer(
              'regions', 'regions-fill',
              maplibre.FillLayerProperties(fillColor: '#E8A838', fillOpacity: 0.06),
              minzoom: 5.0, enableInteraction: true,
            );
            await _controller!.addLineLayer(
              'regions', 'regions-line',
              maplibre.LineLayerProperties(lineColor: 'rgba(44,36,22,0.5)', lineWidth: 1.0),
              minzoom: 5.0,
            );
          } catch (e) { debugPrint('$e'); }
         // Städte auch entfernen
          try {
            await _controller!.removeLayer('cities-circles');
            await _controller!.removeLayer('cities-labels');
            await _controller!.removeSource('cities');
            await _controller!.addSource(
              'cities',
              maplibre.GeojsonSourceProperties(
                data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
                promoteId: 'NAME',
              ),
            );
            await _controller!.addCircleLayer(
              'cities',
              'cities-circles',
              maplibre.CircleLayerProperties(
                circleRadius: 4.0,
                circleColor: '#E85D3A',
                circleStrokeWidth: 1.5,
                circleStrokeColor: '#F5F0E8',
              ),
              minzoom: 7.0,
              enableInteraction: true,
            );
            await _controller!.addSymbolLayer(
              'cities',
              'cities-labels',
              maplibre.SymbolLayerProperties(
                textField: ['get', 'NAME'],
                textSize: 10.0,
                textColor: '#E85D3A',
                textHaloColor: '#F5F0E8',
                textHaloWidth: 1.5,
                textAnchor: 'top',
                textOffset: [0.0, 0.6],
                textFont: ['Open Sans Regular'],
                textAllowOverlap: false,
              ),
              minzoom: 7.0,
            );
          } catch (e) { debugPrint('$e'); } 
        }
        return;
      }

      final center = _controller!.cameraPosition?.target;
      if (center == null) return;

      final lat = center.latitude;
      final lng = center.longitude;

      // MapTiler Reverse Geocoding für ISO3 Code
      try {
        final uri = Uri.parse(
          'https://api.maptiler.com/geocoding/$lng,$lat.json?key=bq7edtBllgSIwDJY9mGU&types=country',
        );
        final response = await http.get(uri);
        if (response.statusCode != 200) return;

        final json = jsonDecode(response.body);
        final features = json['features'] as List?;
        if (features == null || features.isEmpty) return;

        // ISO3 aus Properties holen
        final props = features.first['properties'] as Map?;
        final iso2 = (props?['country_code'] ?? '').toString().toUpperCase();

        if (iso2.isEmpty) return;

        // ISO2 → ISO3 mapping
        const iso2to3 = {
          'DE': 'DEU', 'FR': 'FRA', 'AT': 'AUT', 'CH': 'CHE',
          'IT': 'ITA', 'ES': 'ESP', 'NL': 'NLD', 'BE': 'BEL',
          'PL': 'POL', 'CZ': 'CZE', 'HU': 'HUN', 'SK': 'SVK',
          'HR': 'HRV', 'DK': 'DNK', 'SE': 'SWE', 'NO': 'NOR',
          'GB': 'GBR', 'IE': 'IRL', 'PT': 'PRT', 'GR': 'GRC',
          'RO': 'ROU', 'BG': 'BGR', 'SI': 'SVN', 'RS': 'SRB',
          'BA': 'BIH', 'ME': 'MNE', 'AL': 'ALB', 'MK': 'MKD',
          'CY': 'CYP', 'MT': 'MLT', 'EE': 'EST', 'LV': 'LVA',
          'LT': 'LTU', 'BY': 'BLR', 'UA': 'UKR', 'MD': 'MDA',
          'FI': 'FIN', 'IS': 'ISL', 'LU': 'LUX', 'LI': 'LIE',
          'MC': 'MCO', 'SM': 'SMR', 'VA': 'VAT', 'AD': 'AND',
        };

        final iso3 = iso2to3[iso2];
        if (iso3 == null || iso3 == _lastLoadedCountry) return;

        debugPrint('Loading regions for: $iso3');
        _lastLoadedCountry = iso3;

        final regionUrl = 'https://leafy-selkie-49eae2.netlify.app/geodata/regions_$iso3.json';

        await _controller!.removeLayer('regions-fill');
        await _controller!.removeLayer('regions-line');
        await _controller!.removeLayer('regions-labels');
        await _controller!.removeSource('regions');
        await _controller!.addSource(
          'regions',
          maplibre.GeojsonSourceProperties(
            data: regionUrl,
            promoteId: 'iso_3166_2',
          ),
        );
        await _controller!.addFillLayer(
          'regions', 'regions-fill',
          maplibre.FillLayerProperties(fillColor: '#E8A838', fillOpacity: 0.06),
          minzoom: 5.0, enableInteraction: true,
        );
        await _controller!.addLineLayer(
          'regions', 'regions-line',
          maplibre.LineLayerProperties(lineColor: 'rgba(44,36,22,0.5)', lineWidth: 1.0),
          minzoom: 5.0,
        );
        await _controller!.addSymbolLayer(
          'regions',
          'regions-labels',
          maplibre.SymbolLayerProperties(
            textField: ['get', 'name'],
            textSize: 11.0,
            textColor: '#2C2416',
            textHaloColor: '#F5F0E8',
            textHaloWidth: 1.5,
            textMaxWidth: 8.0,
            textFont: ['Open Sans Regular'],
          ),
          minzoom: 5.0,
        );
        _loadedRegions.add(iso3);
        if (widget.onMessageReceived != null) {
        widget.onMessageReceived!('{"type":"regionsLoaded","payload":{"iso3":"$iso3"}}');
      }
        debugPrint('✅ Regionen geladen: $iso3');
      // Städte laden ab Zoom 7
              if (zoom >= 7.0 && iso3 != _lastLoadedCitiesCountry) {
                _lastLoadedCitiesCountry = iso3;
                final cityUrl = 'https://leafy-selkie-49eae2.netlify.app/geodata/cities_$iso3.json';
                try {
                  await _controller!.removeLayer('cities-circles');
                  await _controller!.removeLayer('cities-labels');
                  await _controller!.removeSource('cities');
                  await _controller!.addSource(
                    'cities',
                    maplibre.GeojsonSourceProperties(
                      data: cityUrl,
                      promoteId: 'NAME',
                    ),
                  );
                  await _controller!.addCircleLayer(
                    'cities',
                    'cities-circles',
                    maplibre.CircleLayerProperties(
                      circleRadius: 4.0,
                      circleColor: '#E85D3A',
                      circleStrokeWidth: 1.5,
                      circleStrokeColor: '#F5F0E8',
                    ),
                    minzoom: 7.0,
                    enableInteraction: true,
                  );
                  await _controller!.addSymbolLayer(
                    'cities',
                    'cities-labels',
                    maplibre.SymbolLayerProperties(
                      textField: ['get', 'NAME'],
                      textSize: 10.0,
                      textColor: '#E85D3A',
                      textHaloColor: '#F5F0E8',
                      textHaloWidth: 1.5,
                      textAnchor: 'top',
                      textOffset: [0.0, 0.6],
                      textFont: ['Open Sans Regular'],
                      textAllowOverlap: false,
                    ),
                    minzoom: 7.0,
                  );
                  debugPrint('✅ Städte geladen: $iso3');
                } catch (e) { debugPrint('❌ cities error: $e'); }
              }
            } catch (e) {
              debugPrint('❌ _onCameraIdle error: $e');
            }
          }

  Future<void> _onStyleLoaded() async {
    if (_controller == null) return;

    try {
      await _controller!.addSource(
        'container_pins',
        maplibre.GeojsonSourceProperties(
          data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
  await _controller!.addSource(
        'ai_stops',
        maplibre.GeojsonSourceProperties(
          data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
        ),
      );
    } catch (e) { debugPrint('$e'); }
  
    try {
      await _controller!.addSource(
        'eu_countries',
        maplibre.GeojsonSourceProperties(
          data: 'https://leafy-selkie-49eae2.netlify.app/geodata/world_countries.json',
          promoteId: 'ADM0_A3',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addSource(
        'country_labels',
        maplibre.GeojsonSourceProperties(
          data: 'https://leafy-selkie-49eae2.netlify.app/geodata/country_labels.json',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addSource(
        'regions',
        maplibre.GeojsonSourceProperties(
          data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
          promoteId: 'iso_3166_2',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
  await _controller!.addSource(
    'cities',
    maplibre.GeojsonSourceProperties(
      data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
      promoteId: 'NAME',
    ),
  );
} catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addCircleLayer(
        'container_pins',
        'container-pins-circles',
        maplibre.CircleLayerProperties(
          circleRadius: 6.0,
          circleColor: '#E8A838',
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#2C2416',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addSymbolLayer(
        'container_pins',
        'container-pins-labels',
        maplibre.SymbolLayerProperties(
          textField: ['get', 'name'],
          textSize: 11.0,
          textColor: '#2C2416',
          textHaloColor: '#F5F0E8',
          textHaloWidth: 1.5,
          textAnchor: 'top',
          textOffset: [0.0, 0.6],
          textFont: ['Open Sans Regular'],
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addCircleLayer(
        'cities',
        'cities-circles',
        maplibre.CircleLayerProperties(
          circleRadius: 4.0,
          circleColor: '#E85D3A',
          circleStrokeWidth: 1.5,
          circleStrokeColor: '#F5F0E8',
        ),
        minzoom: 7.0,
        enableInteraction: true,
      );
      await _controller!.addSymbolLayer(
        'cities',
        'cities-labels',
        maplibre.SymbolLayerProperties(
          textField: ['get', 'NAME'],
          textSize: 10.0,
          textColor: '#E85D3A',
          textHaloColor: '#F5F0E8',
          textHaloWidth: 1.5,
          textAnchor: 'top',
          textOffset: [0.0, 0.6],
          textFont: ['Open Sans Regular'],
          textAllowOverlap: false,
        ),
        minzoom: 7.0,
      );
    } catch (e) { debugPrint('$e'); }

     try {
      await _controller!.addCircleLayer(
        'ai_stops',
        'ai-stops-circles',
        maplibre.CircleLayerProperties(
          circleRadius: 5.0,
          circleColor: '#4A90D9',
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#F5F0E8',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addSymbolLayer(
        'ai_stops',
        'ai-stops-labels',
        maplibre.SymbolLayerProperties(
          textField: ['get', 'name'],
          textSize: 10.0,
          textColor: '#4A90D9',
          textHaloColor: '#F5F0E8',
          textHaloWidth: 1.5,
          textAnchor: 'top',
          textOffset: [0.0, 0.6],
          textFont: ['Open Sans Regular'],
          textAllowOverlap: false,
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addSource(
        'route_line',
        maplibre.GeojsonSourceProperties(
          data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addSource(
        'flags',
        maplibre.GeojsonSourceProperties(
          data: 'https://leafy-selkie-49eae2.netlify.app/empty.json',
        ),
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addFillLayer(
        'eu_countries',
        'eu-countries-fill',
        maplibre.FillLayerProperties(
          fillColor: '#E8A838',
          fillOpacity: 0.06,
        ),
        enableInteraction: true,
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addLineLayer(
        'eu_countries',
        'eu-countries-line',
        maplibre.LineLayerProperties(
          lineColor: 'rgba(44,36,22,0.4)',
          lineWidth: 1.0,
        ),
      );
    } catch (e) { debugPrint('$e'); }
    
    try {
      await _controller!.addSymbolLayer(
        'country_labels',
        'eu-countries-labels',
        maplibre.SymbolLayerProperties(
          textField: ['get', 'NAME'],
          textSize: 12.0,
          textColor: '#2C2416',
          textHaloColor: '#F5F0E8',
          textHaloWidth: 1.5,
          textMaxWidth: 8.0,
          textFont: ['Open Sans Regular'],
          textAllowOverlap: false,
          textIgnorePlacement: false,
        ),
        maxzoom: 5.0,
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addFillLayer(
        'regions',
        'regions-fill',
        maplibre.FillLayerProperties(
          fillColor: '#E8A838',
          fillOpacity: 0.06,
        ),
        minzoom: 5.0,
        enableInteraction: true,
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addLineLayer(
        'regions',
        'regions-line',
        maplibre.LineLayerProperties(
          lineColor: 'rgba(44,36,22,0.5)',
          lineWidth: 1.0,
        ),
        minzoom: 5.0,
      );
    } catch (e) { debugPrint('$e'); }

    try {
      await _controller!.addLineLayer(
        'route_line',
        'route-line',
        maplibre.LineLayerProperties(
          lineColor: '#E85D3A',
          lineWidth: 3.0,
          lineOpacity: 0.85,
          lineDasharray: [2.0, 1.5],
          lineCap: 'round',
          lineJoin: 'round',
        ),
      );
    } catch (e) { debugPrint('$e'); }

        _styleLoaded = true; // ← hier
        // Kurz warten damit MapLibre intern fertig wird
        Future.delayed(const Duration(milliseconds: 1000), () {
          _mapFullyReady = true;
        });
        if (widget.onMessageReceived != null) {
          widget.onMessageReceived!('{"type":"mapReady"}');
        }
      }

  @override
  void dispose() {
    _controller?.onFeatureTapped.remove(_onFeatureTapped);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width ?? double.infinity,
      height: widget.height ?? double.infinity,
      child: AbsorbPointer(
        absorbing: _absorbPointer,
        child: maplibre.MapLibreMap(
          styleString: widget.mapUrl,
          initialCameraPosition: maplibre.CameraPosition(
            target: maplibre.LatLng(52.0, 12.0),
            zoom: 3.5,
          ),
          onMapCreated: _onMapCreated,
          onStyleLoadedCallback: _onStyleLoaded,
          onMapClick: _onMapClick,
          onCameraIdle: _onCameraIdle,
          trackCameraPosition: true,
        ),
      ),
    );
  }
}