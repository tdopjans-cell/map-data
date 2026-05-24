import '/backend/supabase/supabase.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart' as custom_widgets;
import 'package:flutter/material.dart';
import 'dart:convert';
import 'map_screen_model.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
export 'map_screen_model.dart';

class MapScreenWidget extends StatefulWidget {
  const MapScreenWidget({super.key});

  static String routeName = 'MapScreen';
  static String routePath = '/mapScreen';

  @override
  State<MapScreenWidget> createState() => _MapScreenWidgetState();
}

class _MapScreenWidgetState extends State<MapScreenWidget> {
  // ── Variablen ──────────────────────────────────────────────
  late MapScreenModel _model;
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final Map<String, bool> _expandedContainers = {};
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  Future<void> Function(String, String, String)? _highlightFeature;
  Future<void> Function(double, double, double)? _flyTo;
  Future<void> Function(Map<String, dynamic>)? _updateAiStops;
  Future<void> Function(Map<String, dynamic>)? _updateRoute;
  Future<void> Function(Map<String, dynamic>)? _updateContainerPins;
  void Function(bool)? _setMapLocked;

  String? _tripId;
  String? _tripName;
  String? _routeVersionId;
  String? _lastCountryCode;
  List<Map<String, dynamic>> _stops = [];
  int _totalDaysUsed = 0;
  bool _mapReady = false;

  // ── Lifecycle ──────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => MapScreenModel());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkOrCreateTrip();
    });
  }

  @override
  void dispose() {
    _sheetController.dispose();
    _model.dispose();
    super.dispose();
  }

  // ── Trip Logic ─────────────────────────────────────────────
  Future<void> _checkOrCreateTrip() async {
    final userId = SupaFlow.client.auth.currentUser?.id;
    if (userId == null) return;

    final existing = await SupaFlow.client
        .from('trips')
        .select('id, name')
        .eq('owner_id', userId)
        .limit(1)
        .maybeSingle();

    if (existing != null) {
      setState(() {
        _tripId = existing['id'];
        _tripName = existing['name'];
      });
      await _loadOrCreateRouteVersion();
      await _loadStops();
    } else {
      await _showCreateTripDialog();
    }
  }

  Future<void> _showCreateTripDialog({bool isEdit = false}) async {
    final controller = TextEditingController(text: isEdit ? _tripName : '');
    _setMapLocked?.call(true);

    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(isEdit ? 'Trip bearbeiten' : 'Neuer Trip'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'z.B. Europatour 2025',
              labelText: 'Trip Name',
            ),
            onSubmitted: (val) {
              if (val.trim().isNotEmpty) Navigator.pop(ctx, val.trim());
            },
          ),
          actions: [
            if (isEdit)
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Abbrechen'),
              ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(ctx, controller.text.trim());
                }
              },
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 300));
    _setMapLocked?.call(false);
    if (name == null) return;

    final userId = SupaFlow.client.auth.currentUser?.id;
    if (userId == null) return;

    if (isEdit && _tripId != null) {
      await SupaFlow.client
          .from('trips')
          .update({'name': name})
          .eq('id', _tripId!);
      setState(() => _tripName = name);
    } else {
      final trip = await SupaFlow.client
          .from('trips')
          .insert({'owner_id': userId, 'name': name})
          .select()
          .single();
      setState(() {
        _tripId = trip['id'];
        _tripName = trip['name'];
      });
      await _loadOrCreateRouteVersion();
    }
  }

  Future<void> _loadOrCreateRouteVersion() async {
    if (_tripId == null) return;

    final existing = await SupaFlow.client
        .from('route_versions')
        .select('id')
        .eq('trip_id', _tripId!)
        .eq('is_active', true)
        .limit(1)
        .maybeSingle();

    if (existing != null) {
      setState(() => _routeVersionId = existing['id']);
    } else {
      final rv = await SupaFlow.client
          .from('route_versions')
          .insert({
            'trip_id': _tripId,
            'owner_id': SupaFlow.client.auth.currentUser?.id,
            'version_no': 1,
            'is_active': true,
            'generated_by': 'user',
            'generation_mode': 'manual',
          })
          .select()
          .single();
      setState(() => _routeVersionId = rv['id']);
    }
  }

  Future<void> _loadStops() async {
    if (_tripId == null) return;
    final data = await SupaFlow.client
        .from('stops')
        .select('id, place_name, place_level, place_id_ne, is_container, sequence_index, lat, lng, stop_type, parent_stop_id, source, planned_days')
        .eq('trip_id', _tripId!)
        .order('sequence_index');
    setState(() => _stops = List<Map<String, dynamic>>.from(data));
    _calculateTimes();
    if (_mapReady) {
      await _highlightExistingStops();
      await _showAiStopsOnMap();
      await _updateRouteLine();
    }
  }

    void _calculateTimes() {
        // Für jeden Container: open_days = planned_days - Summe der Child planned_days
        for (final container in _stops.where((s) => s['is_container'] == true)) {
          final children = _stops.where((s) => s['parent_stop_id'] == container['id']).toList();
          final usedDays = children.fold<int>(0, (sum, c) => sum + ((c['planned_days'] as int?) ?? 0));
          final plannedDays = (container['planned_days'] as int?) ?? 0;
          container['open_days'] = plannedDays - usedDays;
        }

        // Trip total: Summe aller Top-Level Container
        // Alle Stops summieren falls keine Container planned_days haben
        final totalUsed = _stops.fold<int>(0, (sum, s) => sum + ((s['planned_days'] as int?) ?? 0));
        setState(() => _totalDaysUsed = totalUsed);
      }

    Future<void> _highlightExistingStops() async {
        for (final stop in _stops) {
          if (stop['is_container'] == true) {
            final id = stop['place_id_ne'] as String?;
            final level = stop['place_level'] as String?;
            final stopType = stop['stop_type'] as String?;
            if (id == null || level == null) continue;
            final layerId = level == 'country'
                ? 'eu-countries-fill'
                : 'regions-fill';
            final mapState = stopType == 'prefer' ? 'prefer'
                : stopType == 'never' ? 'never'
                : 'selected';
            await _highlightFeature?.call(id, layerId, mapState);
          }
        }
      }

Future<void> _showAiStopsOnMap() async {
    if (!_mapReady || _updateAiStops == null) return;
    
    final aiStops = _stops.where((s) => 
      s['source'] == 'ai' && 
      s['place_level'] == 'city' &&
      s['lat'] != null && 
      s['lng'] != null
    ).toList();

    final features = aiStops.map((s) => {
      'type': 'Feature',
      'properties': {
        'name': s['place_name'],
        'planned_days': s['planned_days'] ?? 0,
      },
      'geometry': {
        'type': 'Point',
        'coordinates': [s['lng'], s['lat']],
      }
    }).toList();

    final geojson = {
      'type': 'FeatureCollection',
      'features': features,
    };

    debugPrint('AI Stops zu zeigen: ${aiStops.length}');
    debugPrint('GeoJSON: $geojson');

    await _updateAiStops!(geojson);
  }
  
  Future<void> _updateRouteLine() async {
    debugPrint('_updateRouteLine aufgerufen, mapReady: $_mapReady, updateRoute: ${_updateRoute != null}');
    if (!_mapReady || _updateRoute == null) return;

    final activeStops = _stops.where((s) =>
      s['stop_type'] != 'prefer' &&
      s['stop_type'] != 'never' &&
      s['lat'] != null &&
      s['lng'] != null
    ).toList();

    final containers = activeStops
        .where((s) => s['parent_stop_id'] == null)
        .toList()
      ..sort((a, b) => (a['sequence_index'] as int).compareTo(b['sequence_index'] as int));

    final List<List<double>> coordinates = [];

    for (final container in containers) {
      final children = activeStops
          .where((s) => s['parent_stop_id'] == container['id'])
          .toList()
        ..sort((a, b) => (a['sequence_index'] as int).compareTo(b['sequence_index'] as int));

      if (children.isEmpty) {
        coordinates.add([container['lng'] as double, container['lat'] as double]);
      } else {
        for (final child in children) {
          coordinates.add([child['lng'] as double, child['lat'] as double]);
        }
      }
    }

    if (coordinates.length < 2) return;

    final routeGeojson = {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {},
          'geometry': {
            'type': 'LineString',
            'coordinates': coordinates,
          }
        }
      ]
    };

    final emptyContainerFeatures = containers
        .where((s) => !activeStops.any((c) => c['parent_stop_id'] == s['id']))
        .map((s) => {
          'type': 'Feature',
          'properties': {'name': s['place_name']},
          'geometry': {
            'type': 'Point',
            'coordinates': [s['lng'] as double, s['lat'] as double],
          }
        })
        .toList();

    await _updateRoute!(routeGeojson);
    await _updateContainerPins!({'type': 'FeatureCollection', 'features': emptyContainerFeatures});
  }
  
  Future<void> _importAiRoute(String jsonString) async {
    // Kommentare entfernen vor dem Parsen
    final cleanJson = jsonString
        .replaceAll(RegExp(r'//[^\n]*'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();

    debugPrint('JSON Länge: ${cleanJson.length}');
    final cleanJson2 = cleanJson.replaceAll('\u{FEFF}', '').trim();
    debugPrint('Letztes Zeichen: ${cleanJson2.codeUnitAt(cleanJson2.length - 1)}');
    debugPrint('JSON Anfang: ${cleanJson2.substring(0, 100)}');
    debugPrint('JSON Mitte: ${cleanJson2.substring(4700, cleanJson2.length)}');
    debugPrint('JSON Ende: ${cleanJson2.substring(cleanJson2.length - 50)}');
    final data = jsonDecode(cleanJson2);

    try {
      final data = jsonDecode(jsonString);
      final newStops = data['step1a']['new_stops'] as List;

      // Alte RouteVersion deaktivieren
      await SupaFlow.client
          .from('route_versions')
          .update({'is_active': false})
          .eq('trip_id', _tripId!)
          .neq('id', _routeVersionId!);

      // Neue RouteVersion anlegen
      final rv = await SupaFlow.client
          .from('route_versions')
          .insert({
            'trip_id': _tripId,
            'owner_id': SupaFlow.client.auth.currentUser?.id,
            'version_no': 2,
            'is_active': true,
            'generated_by': 'ai',
            'generation_mode': 'ai_rerun',
          })
          .select()
          .single();

      final newRouteVersionId = rv['id'] as String;

      // Bestehende Container in neue RouteVersion kopieren
      final containers = _stops
          .where((s) => s['parent_stop_id'] == null && s['stop_type'] != 'prefer' && s['stop_type'] != 'never')
          .toList();

      final Map<String, String> oldToNewId = {};

      for (final container in containers) {
        final inserted = await SupaFlow.client
            .from('stops')
            .insert({
              'trip_id': _tripId,
              'route_version_id': newRouteVersionId,
              'owner_id': SupaFlow.client.auth.currentUser?.id,
              'place_name': container['place_name'],
              'place_level': container['place_level'],
              'place_id_ne': container['place_id_ne'],
              'lat': container['lat'],
              'lng': container['lng'],
              'sequence_index': container['sequence_index'],
              'stop_type': container['stop_type'],
              'is_container': true,
              'source': container['source'],
              'is_ai_generated': false,
            })
            .select()
            .single();
        oldToNewId[container['id'] as String] = inserted['id'] as String;
      }

      // KI-Stops einfügen
      for (final stop in newStops) {
        final oldParentId = stop['parent_stop_id'] as String?;
        final newParentId = oldParentId != null ? oldToNewId[oldParentId] : null;

        await SupaFlow.client.from('stops').insert({
          'trip_id': _tripId,
          'route_version_id': newRouteVersionId,
          'owner_id': SupaFlow.client.auth.currentUser?.id,
          'place_name': stop['place_name'],
          'place_level': stop['place_level'],
          'lat': stop['lat'],
          'lng': stop['lng'],
          'planned_days': stop['planned_days'],
          'parent_stop_id': newParentId,
          'sequence_index': stop['sequence_index'],
          'stop_type': stop['stop_type'],
          'is_container': stop['stop_type'] == 'container',
          'is_ai_generated': true,
          'source': 'ai',
        });
      }

      // RouteVersion aktualisieren
      setState(() => _routeVersionId = newRouteVersionId);
      await _loadStops();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ KI-Route erfolgreich importiert')),
        );
      }
    } catch (e) {
      debugPrint('❌ Import Fehler: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Import fehlgeschlagen: $e')),
        );
      }
    }
  }

  // ── Map Message Handler ────────────────────────────────────
Future<void> _handleMapMessage(String message) async {
    final data = jsonDecode(message);

    if (data['type'] == 'mapReady') {
      setState(() => _mapReady = true);
      if (_stops.isNotEmpty) {
        await _highlightExistingStops();
        await _showAiStopsOnMap();
        await _updateRouteLine();
      }
      return;
    }

    if (data['type'] == 'regionsLoaded') {
      _lastCountryCode = data['payload']['iso3'];
      await _highlightExistingStops();
      return;
    }

    if (data['type'] != 'select') return;
    if (_tripId == null || _routeVersionId == null) {
      await _showCreateTripDialog();
      return;
    }

    final payload = data['payload'];
    final id = payload['id'] as String;
    final placeLevel = payload['place_level'] as String;
    final lat = payload['lat'] as double;
    final lng = payload['lng'] as double;

    _setMapLocked?.call(true);

    final content = await SupaFlow.client
        .from('place_content')
        .select()
        .eq('place_id', id)
        .maybeSingle();

    final action = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      pageBuilder: (ctx, _, __) => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 16, top: 16, bottom: 16),
          child: SizedBox(
            width: MediaQuery.sizeOf(context).width * 0.28,
            child: _buildPlaceDialog(
              id: id,
              placeLevel: placeLevel,
              content: content,
            ),
          ),
        ),
      ),
    );

    await Future.delayed(const Duration(milliseconds: 300));
    _setMapLocked?.call(false);

    if (action == null) return;

    if (action == 'delete') {
      await SupaFlow.client
          .from('stops')
          .delete()
          .eq('trip_id', _tripId!)
          .eq('place_id_ne', id);
      final layerId = placeLevel == 'country'
          ? 'eu-countries-fill'
          : 'regions-fill';
      await _highlightFeature?.call(id, layerId, 'none');
      await _loadStops();
      return;
    }

    try {
      final count = await SupaFlow.client
          .from('stops')
          .select('id')
          .eq('trip_id', _tripId!);
      final sequenceIndex = (count as List).length;

      final existing = await SupaFlow.client
          .from('stops')
          .select('id')
          .eq('trip_id', _tripId!)
          .eq('place_id_ne', id)
          .maybeSingle();

      if (existing != null) {
        await SupaFlow.client
            .from('stops')
            .update({'stop_type': action})
            .eq('id', existing['id']);
      } else {
// Parent Stop Logik
        String? parentStopId;
        if (placeLevel == 'region' || placeLevel == 'state') {
          String? countryCode;
          if (id.contains('-')) {
            const iso2to3 = {
              'DE': 'DEU', 'FR': 'FRA', 'AT': 'AUT', 'CH': 'CHE',
              'IT': 'ITA', 'ES': 'ESP', 'NL': 'NLD', 'BE': 'BEL',
              'PL': 'POL', 'CZ': 'CZE', 'HU': 'HUN', 'SK': 'SVK',
              'HR': 'HRV', 'DK': 'DNK', 'SE': 'SWE', 'NO': 'NOR',
              'GB': 'GBR', 'IE': 'IRL', 'PT': 'PRT', 'GR': 'GRC',
              'RO': 'ROU', 'BG': 'BGR',
            };
            countryCode = iso2to3[id.split('-')[0]];
          }

          if (countryCode != null) {
            final existingCountry = _stops.firstWhere(
              (s) => s['place_id_ne'] == countryCode && s['place_level'] == 'country',
              orElse: () => {},
            );

            if (existingCountry.isNotEmpty) {
              parentStopId = existingCountry['id'] as String?;
            } else {
              final countryContent = await SupaFlow.client
                  .from('place_content')
                  .select()
                  .eq('place_id', countryCode)
                  .maybeSingle();

              final countryInsert = await SupaFlow.client
                  .from('stops')
                  .insert({
                    'owner_id': SupaFlow.client.auth.currentUser?.id,
                    'trip_id': _tripId,
                    'route_version_id': _routeVersionId,
                    'sequence_index': sequenceIndex,
                    'stop_type': 'container',
                    'place_level': 'country',
                    'place_name': countryContent?['name_de'] ?? countryCode,
                    'place_id_ne': countryCode,
                    'place_source': 'natural_earth',
                    'lat': lat,
                    'lng': lng,
                    'is_container': true,
                    'source': 'auto',
                    'is_ai_generated': false,
                  })
                  .select()
                  .single();

              parentStopId = countryInsert['id'] as String?;
              await _highlightFeature?.call(countryCode, 'eu-countries-fill', 'selected');
            }
          }
        } else if (placeLevel == 'city') {
          final regionStop = _stops.firstWhere(
            (s) => s['place_level'] == 'region' && s['is_container'] == true,
            orElse: () => {},
          );
          if (regionStop.isNotEmpty) {
            parentStopId = regionStop['id'] as String?;
          } else {
            final countryStop = _stops.firstWhere(
              (s) => s['place_level'] == 'country' && s['is_container'] == true,
              orElse: () => {},
            );
            if (countryStop.isNotEmpty) parentStopId = countryStop['id'] as String?;
          }
        }

        // Stop inserieren
        await SupaFlow.client.from('stops').insert({
          'owner_id': SupaFlow.client.auth.currentUser?.id,
          'trip_id': _tripId,
          'route_version_id': _routeVersionId,
          'sequence_index': sequenceIndex + 1,
          'stop_type': action,
          'place_level': placeLevel,
          'place_name': content?['name_de'] ?? id,
          'place_id_ne': id,
          'place_source': 'natural_earth',
          'lat': lat,
          'lng': lng,
          'is_container': placeLevel != 'city',
          'source': 'user',
          'is_ai_generated': false,
          'parent_stop_id': parentStopId,
        });

        final layerId = placeLevel == 'country'
            ? 'eu-countries-fill'
            : 'de-states-fill';
        final mapState = action == 'prefer' ? 'prefer'
            : action == 'never' ? 'never'
            : 'selected';
        await _highlightFeature?.call(id, layerId, mapState);
      }

      await _loadStops();
    } catch (e) {
      debugPrint('❌ Fehler: $e');
    }
  }

  Widget _buildPlaceDialog({
    required String id,
    required String placeLevel,
    Map<String, dynamic>? content,
  }) {
    return Material(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Bild — höher
          if (content?['image_url'] != null)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: Image.network(
                content!['image_url'],
                height: 220,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 220,
                  color: const Color(0xFFE8D8B8),
                  child: const Icon(Icons.landscape, size: 48, color: Color(0xFFE8A838)),
                ),
              ),
            )
          else
            Container(
              height: 220,
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFFE8D8B8),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: const Icon(Icons.landscape, size: 48, color: Color(0xFFE8A838)),
            ),
          // Content
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        content?['name_de'] ?? id,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        placeLevel,
                        style: const TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
                if (content?['description_de'] != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    content!['description_de'],
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white70,
                      height: 1.4,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 16),
                // Aktions-Buttons
                Row(
                  children: [
                    _actionButton('Nie', Icons.block, const Color(0xFFBDBDBD), 'never'),
                    const SizedBox(width: 8),
                    _actionButton('Prefer', Icons.favorite, const Color(0xFF5BA68A), 'prefer'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.pop(context, 'container'),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Stop'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE8A838),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context, 'delete'),
                        child: const Text('Entfernen', style: TextStyle(color: Colors.red, fontSize: 12)),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, null),
                      child: const Text('Abbrechen', style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(String label, IconData icon, Color color, String action) {
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: () => Navigator.pop(context, action),
        icon: Icon(icon, size: 14, color: color),
        label: Text(label, style: TextStyle(color: color, fontSize: 12)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: color),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }


  // ── Layouts ────────────────────────────────────────────────
Widget _buildSidebarHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo + App Name
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8A838),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.explore, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 8),
              Text(
                'Way2GoX',
                style: GoogleFonts.nunito(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF2C2416),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _showCreateTripDialog(isEdit: true),
                icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF888888)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () async {
                  final controller = TextEditingController(
                    text: 'https://tdopjans-cell.github.io/map-data/newKI.json',
                  );
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('Route neu berechnen',
                        style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
                      content: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: 'URL zur JSON-Datei...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Abbrechen'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text('Importieren',
                            style: TextStyle(color: const Color(0xFFE8A838))),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true && controller.text.isNotEmpty) {
                    final response = await http.get(Uri.parse(controller.text));
                    if (response.statusCode == 200) {
                      await _importAiRoute(utf8.decode(response.bodyBytes));
                    }
                  }
                },
                icon: const Icon(Icons.auto_awesome, size: 18, color: Color(0xFF4A90D9)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Trip Name
          Text(
            _tripName ?? 'Mein Trip',
            style: GoogleFonts.nunito(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF2C2416),
            ),
          ),
          if (_totalDaysUsed > 0)
            Text(
              '$_totalDaysUsed Tage geplant',
              style: GoogleFonts.nunito(
                fontSize: 13,
                color: const Color(0xFF888888),
              ),
            ),
          const SizedBox(height: 12),
          // Recalculate Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                final controller = TextEditingController(
                  text: 'https://tdopjans-cell.github.io/map-data/newKI.json',
                );
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Route neu berechnen',
                      style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
                    content: TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        hintText: 'URL zur JSON-Datei...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Abbrechen'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text('Importieren',
                          style: TextStyle(color: const Color(0xFFE8A838))),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && controller.text.isNotEmpty) {
                  final response = await http.get(Uri.parse(controller.text));
                  if (response.statusCode == 200) {
                    await _importAiRoute(utf8.decode(response.bodyBytes));
                  }
                }
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: Text('Route neu berechnen',
                style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3A9E8F),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStopList({ScrollController? scrollController}) {
    final topLevel = _stops
        .where((s) => s['parent_stop_id'] == null)
        .toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0)
          .compareTo((b['sequence_index'] as int?) ?? 0));

    if (topLevel.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.explore_outlined, size: 48, color: Color(0xFFCCC5B5)),
              const SizedBox(height: 12),
              Text(
                'Noch keine Stops',
                style: GoogleFonts.nunito(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF888888),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Klick auf ein Land um anzufangen',
                style: GoogleFonts.nunito(
                  fontSize: 13,
                  color: const Color(0xFFAAAAAA),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
      itemCount: topLevel.length,
      itemBuilder: (ctx, i) {
        final stop = topLevel[i];
        final children = _stops
            .where((s) => s['parent_stop_id'] == stop['id'])
            .toList()
          ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0)
              .compareTo((b['sequence_index'] as int?) ?? 0));
        return _buildStopCard(stop, children, 0, index: i + 1);
      },
    );
  }

  Widget _buildStopCard(
    Map<String, dynamic> stop,
    List<Map<String, dynamic>> children,
    int depth, {
    int index = 0,
  }) {
    final stopType = stop['stop_type'] as String? ?? 'container';
    final placeLevel = stop['place_level'] as String? ?? '';
    final lat = stop['lat'] as double?;
    final lng = stop['lng'] as double?;
    final plannedDays = stop['planned_days'] as int?;
    final isExpanded = _expandedContainers[stop['id']] ?? true;

    Color accentColor;
    IconData iconData;
    String statusLabel = '';

    if (stopType == 'prefer') {
      accentColor = const Color(0xFF3A9E8F);
      iconData = Icons.star_outline;
      statusLabel = 'Preferred';
    } else if (stopType == 'never') {
      accentColor = const Color(0xFFE85D3A);
      iconData = Icons.remove_circle_outline;
      statusLabel = 'Excluded';
    } else {
      accentColor = const Color(0xFF2C2416);
      iconData = Icons.location_on_outlined;
    }

    // Child Stop (eingerückt)
    if (depth > 0) {
      return Padding(
        padding: const EdgeInsets.only(left: 16, bottom: 4),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFEEEEEE)),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            leading: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: stopType == 'prefer'
                    ? const Color(0xFF3A9E8F).withOpacity(0.1)
                    : stopType == 'never'
                        ? const Color(0xFFE85D3A).withOpacity(0.1)
                        : const Color(0xFF4A90D9).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(iconData, size: 14, color: accentColor),
            ),
            title: Text(
              stop['place_name'] ?? '',
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF2C2416),
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (statusLabel.isNotEmpty)
                  Text(statusLabel,
                    style: GoogleFonts.nunito(
                      fontSize: 11,
                      color: accentColor,
                      fontWeight: FontWeight.w600,
                    ))
                else if (plannedDays != null)
                  Text('$plannedDays days',
                    style: GoogleFonts.nunito(
                      fontSize: 12,
                      color: const Color(0xFF888888),
                    )),
                const SizedBox(width: 8),
                GestureDetector(
                  onLongPress: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Stop löschen'),
                        content: Text('${stop['place_name']} wirklich löschen?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Abbrechen'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Löschen'),
                            style: TextButton.styleFrom(foregroundColor: Colors.red),
                          ),
                        ],
                      ),
                    );
                    if (confirm != true) return;
                    await SupaFlow.client.from('stops').delete().eq('id', stop['id']);
                    await _loadStops();
                  },
                  child: const Icon(Icons.delete_outline, size: 16, color: Color(0xFFCCCCCC)),
                ),
              ],
            ),
            onTap: () {
              if (lat != null && lng != null) {
                _flyTo?.call(lat, lng, 9.0);
              }
            },
          ),
        ),
      );
    }

    // Container Stop (Top-Level)
    final usedDays = children
        .where((c) => c['stop_type'] != 'prefer' && c['stop_type'] != 'never')
        .fold<int>(0, (sum, c) => sum + ((c['planned_days'] as int?) ?? 0));
    final openDays = (plannedDays ?? 0) - usedDays;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Container Header
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () {
              setState(() {
                _expandedContainers[stop['id']] = !isExpanded;
              });
              if (lat != null && lng != null) {
                _flyTo?.call(lat, lng, 5.0);
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Row(
                children: [
                  // Nummer
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F0E8),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Center(
                      child: Text('$index',
                        style: GoogleFonts.nunito(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF888888),
                        )),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Name
                  Expanded(
                    child: Text(
                      stop['place_name'] ?? '',
                      style: GoogleFonts.nunito(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF2C2416),
                      ),
                    ),
                  ),
                  // Tage + Fortschrittsbalken
                  if (plannedDays != null) ...[
                    Text('$plannedDays days',
                      style: GoogleFonts.nunito(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF2C2416),
                      )),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 48,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: plannedDays > 0 ? usedDays / plannedDays : 0,
                          backgroundColor: const Color(0xFFEEEEEE),
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF3A9E8F)),
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Icon(
                    isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 20,
                    color: const Color(0xFF888888),
                  ),
                ],
              ),
            ),
          ),
          // Children
          if (isExpanded) ...[
            if (children.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  children: children.map<Widget>((child) {
                    final grandChildren = _stops
                        .where((s) => s['parent_stop_id'] == child['id'])
                        .toList();
                    return _buildStopCard(child, grandChildren, depth + 1);
                  }).toList(),
                ),
              ),
            // Open Days
            if (plannedDays != null && openDays > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome, size: 12, color: Color(0xFF3A9E8F)),
                    const SizedBox(width: 6),
                    Text(
                      '$openDays days still open for AI planning',
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        color: const Color(0xFF3A9E8F),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width > 600;
    return Scaffold(
      key: scaffoldKey,
      body: isWide ? _buildWebLayout() : _buildMobileLayout(),
    );
  }

  Widget _buildWebLayout() {
    return Row(
      children: [
        Container(
          width: 300,
          color: const Color(0xFFF5F0E8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              _buildSidebarHeader(),
              const Divider(color: Color(0xFFE0D8C8), height: 1),
              Expanded(child: _buildStopList()),
            ],
          ),
        ),
        Expanded(
          child: custom_widgets.MapWebView(
            width: double.infinity,
            height: double.infinity,
            mapUrl: 'https://api.maptiler.com/maps/aquarelle-v4/style.json?key=bq7edtBllgSIwDJY9mGU',
            onMessageReceived: _handleMapMessage,
            onControllerReady: (highlight, setLocked, flyTo, updateAiStops, updateRoute, updateContainerPins) {
              _highlightFeature = highlight;
              _setMapLocked = setLocked;
              _flyTo = flyTo;
              _updateAiStops = updateAiStops;
              _updateRoute = updateRoute;
              _updateContainerPins = updateContainerPins;
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMobileLayout() {
    return Stack(
      children: [
        custom_widgets.MapWebView(
          width: double.infinity,
          height: double.infinity,
          mapUrl: 'https://api.maptiler.com/maps/aquarelle-v4/style.json?key=bq7edtBllgSIwDJY9mGU',
          onMessageReceived: _handleMapMessage,
          onControllerReady: (highlight, setLocked, flyTo, updateAiStops, updateRoute, updateContainerPins) {
            _highlightFeature = highlight;
            _setMapLocked = setLocked;
            _flyTo = flyTo;
            _updateAiStops = updateAiStops;
            _updateRoute = updateRoute;
            _updateContainerPins = updateContainerPins;
          },
        ),
        DraggableScrollableSheet(
          controller: _sheetController,
          initialChildSize: 0.35,
          minChildSize: 0.08,
          maxChildSize: 0.85,
          builder: (ctx, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF5F0E8),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 10,
                    offset: Offset(0, -2),
                  )
                ],
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 4),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCCC5B5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  _buildSidebarHeader(),
                  const Divider(color: Color(0xFFE0D8C8), height: 1),
                  Expanded(
                    child: _buildStopList(scrollController: scrollController),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}