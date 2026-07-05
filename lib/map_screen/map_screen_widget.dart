import '/backend/supabase/supabase.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/custom_code/widgets/index.dart' as custom_widgets;
import 'package:flutter/material.dart';
import 'dart:convert';
import 'map_screen_model.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'trip_calendar.dart';
export 'map_screen_model.dart';

class MapScreenWidget extends StatefulWidget {
  const MapScreenWidget({super.key});
  static String routeName = 'MapScreen';
  static String routePath = '/mapScreen';
  @override
  State<MapScreenWidget> createState() => _MapScreenWidgetState();
}

class _MapScreenWidgetState extends State<MapScreenWidget> {
  late MapScreenModel _model;
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final Map<String, bool> _expandedContainers = {};
  final DraggableScrollableController _sheetController = DraggableScrollableController();

  Future<void> Function(String, String, String)? _highlightFeature;
  Future<void> Function(double, double, double)? _flyTo;
  Future<void> Function(Map<String, dynamic>)? _updateAiStops;
  Future<void> Function(Map<String, dynamic>)? _updateRoute;
  Future<void> Function(Map<String, dynamic>)? _updateContainerPins;
  Future<void> Function(Map<String, dynamic>)? _updateWarningMarkers;
  void Function(bool)? _setMapLocked;
  void Function()? _resetTapping;

  String? _tripId;
  String? _tripName;
  String? _routeVersionId;
  String? _lastCountryCode;
  List<Map<String, dynamic>> _stops = [];
  List<Map<String, dynamic>> _allTrips = [];
  List<Map<String, dynamic>> _warnings = [];
  List<Map<String, dynamic>> _allRouteVersions = [];
  int _totalDaysUsed = 0;
  bool _mapReady = false;
  bool _rerunLoading = false;
  Map<String, dynamic> _tripParams = {};

  bool _glaettungPending = false;
  // snapshot stores: {planned_days, start_date, end_date, sequence_index}
  Map<String, Map<String, dynamic>> _glaettungSnapshot = {};
  Map<String, dynamic>? _pendingReplacePayload;

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => MapScreenModel());
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOrCreateTrip());
  }

  @override
  void dispose() {
    _sheetController.dispose();
    _model.dispose();
    super.dispose();
  }

  // ── Date helpers ────────────────────────────────────────────
  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  void _autoBudgetPerDay(TextEditingController minC, TextEditingController maxC,
      TextEditingController dayC, TextEditingController daysC) {
    final mn = int.tryParse(minC.text);
    final mx = int.tryParse(maxC.text);
    final days = int.tryParse(daysC.text);
    if (mn != null && mx != null && days != null && days > 0) {
      dayC.text = '${(((mn + mx) / 2) / days).round()}';
    } else {
      dayC.clear();
    }
  }

  String _isoToDe(String iso) {
    final d = DateTime.tryParse(iso.trim());
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  }

  static const List<Color> _occPalette = [
    Color(0xFF3A9E8F), Color(0xFF4A90D9), Color(0xFF8B6FC9),
    Color(0xFFE07856), Color(0xFF7BA05B), Color(0xFFD4537E),
  ];

  /// Belegungs-Eintraege fuer den Kalender (v2):
  /// Blatt-Stops einzeln mit eigener Farbe + Namen; Container nur,
  /// wenn sie keine datierten Kinder haben. [exceptId] wird ausgelassen.
  List<TripCalendarOccupancy> _buildOccupancy({String? exceptId}) {
    bool hasDates(Map<String, dynamic> s) =>
        DateTime.tryParse(s['start_date'] ?? '') != null &&
        DateTime.tryParse(s['end_date'] ?? '') != null;

    final datedChildParents = _stops
        .where((s) =>
            s['parent_stop_id'] != null &&
            s['stop_type'] != 'prefer' && s['stop_type'] != 'never' &&
            s['id'] != exceptId && hasDates(s))
        .map((s) => s['parent_stop_id'] as String)
        .toSet();

    final entries = <TripCalendarOccupancy>[];
    int colorIdx = 0;
    for (final s in _stops) {
      if (s['id'] == exceptId) continue;
      if (s['stop_type'] == 'prefer' || s['stop_type'] == 'never') continue;
      final isTop = s['parent_stop_id'] == null;
      // Container mit datierten Kindern ueberspringen — Kinder zeigen die Belegung.
      if (isTop && datedChildParents.contains(s['id'])) continue;
      final st = DateTime.tryParse(s['start_date'] ?? '');
      final en = DateTime.tryParse(s['end_date'] ?? '');
      if (st == null || en == null) continue;
      entries.add(TripCalendarOccupancy(
        start: st, end: en,
        color: _occPalette[colorIdx++ % _occPalette.length],
        fixed: s['is_time_fixed'] == true,
        label: s['place_name'] ?? '',
      ));
    }
    return entries;
  }

  /// Bidirectional recalc: pass which field just changed ('start'/'end'/'days').
  void _recalcDates(StateSetter setS, String changed,
      TextEditingController startCtrl,
      TextEditingController endCtrl,
      TextEditingController daysCtrl) {
    final s = DateTime.tryParse(startCtrl.text.trim());
    final e = DateTime.tryParse(endCtrl.text.trim());
    final d = int.tryParse(daysCtrl.text.trim());
    if (changed == 'days' || changed == 'start') {
      if (s != null && d != null && d > 0) {
        setS(() => endCtrl.text = _fmt(s.add(Duration(days: d - 1))));
        return;
      }
    }
    if (changed == 'end' || changed == 'start') {
      if (s != null && e != null && !e.isBefore(s)) {
        setS(() => daysCtrl.text = '${e.difference(s).inDays + 1}');
        return;
      }
    }
    if (changed == 'end' || changed == 'days') {
      if (e != null && d != null && d > 0) {
        setS(() => startCtrl.text = _fmt(e.subtract(Duration(days: d - 1))));
        return;
      }
    }
  }

  /// Returns effective start/end for a container, derived from children if not explicit.
  Map<String, DateTime?> _getEffectiveDates(Map<String, dynamic> stop) {
    DateTime? start = DateTime.tryParse(stop['start_date'] ?? '');
    DateTime? end   = DateTime.tryParse(stop['end_date']   ?? '');
    final children  = _stops.where((s) =>
        s['parent_stop_id'] == stop['id'] &&
        s['stop_type'] != 'prefer' && s['stop_type'] != 'never' &&
        s['stop_role'] != 'transit').toList();
    for (final child in children) {
      final cStart = DateTime.tryParse(child['start_date'] ?? '');
      final cEnd   = DateTime.tryParse(child['end_date']   ?? '');
      final cDays  = child['planned_days'] as int?;
      final derivedEnd = (cStart != null && cEnd == null && cDays != null && cDays > 0)
          ? cStart.add(Duration(days: cDays - 1)) : null;
      final effectiveEnd = cEnd ?? derivedEnd;
      if (cStart != null && (start == null || cStart.isBefore(start))) start = cStart;
      if (effectiveEnd != null && (end == null || effectiveEnd.isAfter(end))) end = effectiveEnd;
    }
    return {'start': start, 'end': end};
  }

  // ── Trip Logic ──────────────────────────────────────────────
  Future<void> _checkOrCreateTrip() async {
    final userId = SupaFlow.client.auth.currentUser?.id;
    if (userId == null) return;
    await _loadAllTrips();
    if (_allTrips.isEmpty) {
      await _showTripDialog(isEdit: false);
    } else {
      final active = _allTrips.firstWhere((t) => t['is_active'] == true, orElse: () => _allTrips.first);
      if (!mounted) return;
      setState(() { _tripId = active['id']; _tripName = active['name']; _tripParams = _extractTripParams(active); });
      if (active['is_active'] != true)
        await SupaFlow.client.from('trips').update({'is_active': true}).eq('id', active['id']);
      await _loadOrCreateRouteVersion();
      await _loadStops();
    }
  }

Future<void> _recalcAllDatesFromStart() async {
  if (_tripId == null || _routeVersionId == null) return;

  final tripData = await SupaFlow.client.from('trips')
      .select('start_date').eq('id', _tripId!).single();
  final startStr = tripData['start_date'] as String?;
  if (startStr == null) return;

  DateTime cursor = DateTime.parse(startStr);

  final containers = _stops
      .where((s) => s['parent_stop_id'] == null &&
                    s['stop_type'] != 'prefer' &&
                    s['stop_type'] != 'never')
      .toList()
    ..sort((a, b) => (a['sequence_index'] as int? ?? 0)
        .compareTo(b['sequence_index'] as int? ?? 0));

  for (final container in containers) {
    final cId = container['id'] as String;
    final cStart = cursor;

    final children = _stops
        .where((s) => s['parent_stop_id'] == cId &&
                      s['stop_type'] != 'prefer' &&
                      s['stop_type'] != 'never')
        .toList()
      ..sort((a, b) => (a['sequence_index'] as int? ?? 0)
          .compareTo(b['sequence_index'] as int? ?? 0));

int cDays = 0;
    for (final child in children) {
      final days = (child['planned_days'] as num?)?.toInt() ?? 0;
      if (days <= 0) continue;
      final isFixed = child['is_time_fixed'] == true;
      final fixedStart = DateTime.tryParse(child['start_date'] ?? '');
      if (isFixed && fixedStart != null) {
        cursor = fixedStart;
        final childEnd = cursor.add(Duration(days: days - 1));
        cursor = childEnd.add(const Duration(days: 1));
        cDays += days;
      } else {
        final childEnd = cursor.add(Duration(days: days - 1));
        await SupaFlow.client.from('stops').update({
          'start_date': cursor.toIso8601String().split('T')[0],
          'end_date': childEnd.toIso8601String().split('T')[0],
        }).eq('id', child['id'] as String);
        cursor = cursor.add(Duration(days: days));
        cDays += days;
      }
    }

    if (cDays > 0) {
      await SupaFlow.client.from('stops').update({
        'start_date': cStart.toIso8601String().split('T')[0],
        'end_date': cursor.subtract(const Duration(days: 1))
            .toIso8601String().split('T')[0],
        'planned_days': cDays,
      }).eq('id', cId);
    }
  }
}

Future<void> _loadRouteVersions() async {
  if (_tripId == null) return;
  final data = await SupaFlow.client
      .from('route_versions')
      .select('id, version_no, generated_by, is_active')
      .eq('trip_id', _tripId!)
      .order('version_no');
  if (!mounted) return;
  setState(() => _allRouteVersions = List<Map<String, dynamic>>.from(data));
}

Future<void> _showFreebieSheet() async {
    if (_tripId == null) return;
    final data = await SupaFlow.client
        .from('ai_generations')
        .select('output_json, created_at')
        .eq('trip_id', _tripId!)
        .eq('status', 'completed')
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (data == null || !mounted) return;
    final outputJson = data['output_json'] as Map<String, dynamic>?;
    if (outputJson == null) return;
    final step1b = outputJson['step1b']?['popup'] as Map<String, dynamic>?;
    final step1a = outputJson['step1a'] as Map<String, dynamic>?;
    if (step1b == null) return;
    final pitch       = step1b['reiseuebersicht']?['pitch_gesamt'] as String?;
    final reisestil   = step1b['reiseuebersicht']?['reisestil'] as String?;
    final phasen      = (step1b['reisephasen'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final entspannung = (step1b['reiseuebersicht']?['entspannungsanteil'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final newStops    = (step1a?['new_stops'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            Expanded(child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
              children: [
                Text('Deine Route', style: GoogleFonts.nunito(
                    fontSize: 20, fontWeight: FontWeight.w700,
                    color: const Color(0xFF2C2416))),
                const SizedBox(height: 20),
                if (pitch != null) ...[
                  _freebieSection('Route im Überblick'),
                  Text(pitch, style: GoogleFonts.nunito(
                      fontSize: 13, height: 1.6, color: const Color(0xFF444444))),
                  const SizedBox(height: 24),
                ],
                if (phasen.isNotEmpty) ...[
                  _freebieSection('Reisephasen'),
                  ...phasen.where((p) =>
                      (p['included_places'] as List?)?.isNotEmpty == true)
                    .map((p) => Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F3EE),
                        borderRadius: BorderRadius.circular(12)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(child: Text(p['title'] ?? '',
                              style: GoogleFonts.nunito(
                                  fontWeight: FontWeight.w700, fontSize: 13, color: const Color(0xFF2C2416)))),
                            Text('${p['duration_days']} T',
                              style: GoogleFonts.nunito(fontSize: 12,
                                  color: const Color(0xFF3A9E8F),
                                  fontWeight: FontWeight.w700)),
                          ]),
                          if (p['charakter'] != null) ...[
                            const SizedBox(height: 4),
                            Text(p['charakter'], style: GoogleFonts.nunito(
                                fontSize: 12, color: const Color(0xFF666666),
                                height: 1.4)),
                          ],
                          const SizedBox(height: 6),
                          Wrap(spacing: 4, runSpacing: 4,
                            children: (p['included_places'] as List).map((place) =>
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.grey.shade300)),
                                child: Text(place.toString(),
                                  style: GoogleFonts.nunito(fontSize: 11, color: const Color(0xFF2C2416))),
                              )).toList()),
                        ]),
                    )),
                  const SizedBox(height: 14),
                ],
                if (newStops.any((s) => s['ai_reasoning'] != null)) ...[
                  _freebieSection('Warum diese Stops?'),
                  ...newStops.where((s) => s['ai_reasoning'] != null)
                    .map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.place_outlined, size: 18,
                              color: Color(0xFF3A9E8F)),
                          const SizedBox(width: 8),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s['place_name'] ?? '',
                                style: GoogleFonts.nunito(
                                    fontWeight: FontWeight.w700, fontSize: 13)),
                              const SizedBox(height: 2),
                              Text(s['ai_reasoning'],
                                style: GoogleFonts.nunito(fontSize: 12,
                                    color: const Color(0xFF666666), height: 1.4)),
                            ])),
                        ]),
                    )),
                  const SizedBox(height: 14),
                ],
                if (reisestil != null) ...[
                  _freebieSection('Reisestil'),
                  Text(reisestil, style: GoogleFonts.nunito(
                      fontSize: 13, height: 1.6, color: const Color(0xFF444444))),
                  const SizedBox(height: 24),
                ],
                if (entspannung.isNotEmpty) ...[
                  _freebieSection('Entspannung pro Ort'),
                  ...entspannung.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_relaxEmoji(e['relaxation_level'] as String? ?? ''),
                            style: const TextStyle(fontSize: 18)),
                        const SizedBox(width: 10),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e['place_name'] ?? '',
                              style: GoogleFonts.nunito(
                                  fontWeight: FontWeight.w700, fontSize: 13)),
                            if (e['erklaerung'] != null)
                              Text(e['erklaerung'], style: GoogleFonts.nunito(
                                  fontSize: 12, color: const Color(0xFF666666),
                                  height: 1.4)),
                          ])),
                      ]),
                  )),
                ],
              ],
            )),
          ]),
        ),
      ),
    );
  }

  Widget _freebieSection(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(title, style: GoogleFonts.nunito(
        fontSize: 14, fontWeight: FontWeight.w700,
        color: const Color(0xFF3A9E8F))),
  );

  String _relaxEmoji(String level) {
    switch (level) {
      case 'hoch':   return '😌';
      case 'mittel': return '🙂';
      case 'gering': return '⚡';
      default:       return '•';
    }
  }

  Future<void> _loadAllTrips() async {
    final userId = SupaFlow.client.auth.currentUser?.id;
    if (userId == null) return;
    final data = await SupaFlow.client.from('trips').select().eq('owner_id', userId).order('created_at');
    final seen = <String>{};
    final deduped = <Map<String, dynamic>>[];
    for (final t in List<Map<String, dynamic>>.from(data)) {
      if (seen.add(t['id'] as String)) deduped.add(t);
    }
    if (!mounted) return;
    setState(() => _allTrips = deduped);
  }

  Map<String, dynamic> _extractTripParams(Map<String, dynamic> trip) {
  final px = trip['param_extra'];
  final extra = px is Map ? Map<String, dynamic>.from(px) : <String, dynamic>{};
  return {
    'group_type':     trip['param_group_type'],
    'diet':           trip['param_diet'],
    'budget':         trip['param_budget'],
    'trip_style':     trip['param_trip_style'],
    'activity_level': trip['param_activity_level'],
    'start_date':     trip['start_date'],
    'end_date':       trip['end_date'],
    'total_days':     trip['total_days'],
    // Neue Params aus param_extra
    'group_size':                  extra['group_size'],
    'age_groups':                  extra['age_groups'],
    'trip_occasion':               extra['trip_occasion'],
    'budget_range_eur':            extra['budget_range_eur'],
    'budget_per_day_eur':          extra['budget_per_day_eur'],
    'vacation_type':               extra['vacation_type'],
    'accommodation_type':          extra['accommodation_type'],
    'sports_activities':           extra['sports_activities'],
    'cultural_interests':          extra['cultural_interests'],
    'culinary_interests':          extra['culinary_interests'],
    'transport_modes':             extra['transport_modes'],
    'has_own_vehicle':             extra['has_own_vehicle'],
    'location_change_willingness': extra['location_change_willingness'],
    'max_travel_time_per_day_h':   extra['max_travel_time_per_day_h'],
  };
}


  /// Kopiert den aktiven Trip inkl. Parametern und allen Stops (T-052).
  Future<void> _duplicateTrip() async {
    final userId = SupaFlow.client.auth.currentUser?.id;
    if (userId == null || _tripId == null) return;
    final orig = _allTrips.firstWhere((t) => t['id'] == _tripId, orElse: () => {});
    if (orig.isEmpty) return;
    try {
      await SupaFlow.client.from('trips').update({'is_active': false}).eq('owner_id', userId);
      final newTrip = await SupaFlow.client.from('trips').insert({
        'owner_id': userId,
        'name': '${orig['name'] ?? 'Trip'} (Kopie)',
        'is_active': true,
        'start_date': orig['start_date'],
        'end_date': orig['end_date'],
        'total_days': orig['total_days'],
        'param_group_type': orig['param_group_type'],
        'param_diet': orig['param_diet'],
        'param_budget': orig['param_budget'],
        'param_trip_style': orig['param_trip_style'],
        'param_activity_level': orig['param_activity_level'],
        'param_extra': orig['param_extra'],
      }).select().single();
      final newTripId = newTrip['id'] as String;
      final rv = await SupaFlow.client.from('route_versions').insert({
        'trip_id': newTripId, 'owner_id': userId,
        'version_no': 1, 'is_active': true,
        'generated_by': 'user', 'generation_mode': 'manual',
      }).select().single();
      final newRvId = rv['id'] as String;

      // Stops kopieren: erst Top-Level (inkl. prefer/never), dann Kinder
      final topLevel = _stops.where((s) => s['parent_stop_id'] == null).toList();
      final oldToNew = <String, String>{};
      for (final s in topLevel) {
        final ins = await SupaFlow.client.from('stops').insert({
          'owner_id': userId, 'trip_id': newTripId, 'route_version_id': newRvId,
          'place_name': s['place_name'], 'place_level': s['place_level'],
          'place_id_ne': s['place_id_ne'], 'lat': s['lat'], 'lng': s['lng'],
          'sequence_index': s['sequence_index'], 'stop_type': s['stop_type'],
          'stop_role': s['stop_role'], 'is_container': s['is_container'] ?? true,
          'planned_days': s['planned_days'],
          'start_date': s['start_date'], 'end_date': s['end_date'],
          'is_time_fixed': s['is_time_fixed'] ?? false,
          'source': s['source'], 'is_ai_generated': s['is_ai_generated'] ?? false,
          'use_trip_params': s['use_trip_params'] ?? true,
        }).select().single();
        oldToNew[s['id'] as String] = ins['id'] as String;
      }
      for (final s in _stops.where((s) => s['parent_stop_id'] != null)) {
        final newParent = oldToNew[s['parent_stop_id'] as String];
        if (newParent == null) continue;
        await SupaFlow.client.from('stops').insert({
          'owner_id': userId, 'trip_id': newTripId, 'route_version_id': newRvId,
          'place_name': s['place_name'], 'place_level': s['place_level'],
          'place_id_ne': s['place_id_ne'], 'lat': s['lat'], 'lng': s['lng'],
          'sequence_index': s['sequence_index'], 'stop_type': s['stop_type'],
          'stop_role': s['stop_role'], 'is_container': s['is_container'] ?? false,
          'planned_days': s['planned_days'],
          'start_date': s['start_date'], 'end_date': s['end_date'],
          'is_time_fixed': s['is_time_fixed'] ?? false,
          'source': s['source'], 'is_ai_generated': s['is_ai_generated'] ?? false,
          'use_trip_params': s['use_trip_params'] ?? true,
          'parent_stop_id': newParent,
        });
      }

      await _clearMapVisuals();
      await _loadAllTrips();
      if (!mounted) return;
      setState(() {
        _tripId = newTripId;
        _tripName = newTrip['name'];
        _tripParams = _extractTripParams(newTrip);
        _routeVersionId = newRvId;
        _stops = []; _expandedContainers.clear(); _warnings = [];
        _glaettungPending = false;
      });
      await _loadStops();
      if (mounted) {
        try { ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Trip kopiert: ${newTrip['name']}'))); } catch (_) {}
      }
    } catch (e) { debugPrint('duplicateTrip error: $e'); }
  }

  Future<void> _switchTrip(String tripId) async {
    final userId = SupaFlow.client.auth.currentUser?.id;
    if (userId == null) return;
    await SupaFlow.client.from('trips').update({'is_active': false}).eq('owner_id', userId);
    await SupaFlow.client.from('trips').update({'is_active': true}).eq('id', tripId);
    final trip = _allTrips.firstWhere((t) => t['id'] == tripId);
    await _clearMapVisuals();
    if (!mounted) return;
    setState(() { _tripId = tripId; _tripName = trip['name']; _tripParams = _extractTripParams(trip);
      _stops = []; _expandedContainers.clear(); _warnings = []; _glaettungPending = false; });
    await _loadOrCreateRouteVersion();
    await _loadStops();
  }

  Future<void> _applyTripParamsToStops(Map<String, dynamic> tripPayload) async {
  if (_tripId == null) return;
  final extra = _buildParamExtra(tripPayload);
  await SupaFlow.client.from('stops').update({
    'override_param_group_type':     tripPayload['param_group_type'],
    'override_param_diet':           tripPayload['param_diet'],
    'override_param_budget':         tripPayload['param_budget'],
    'override_param_trip_style':     tripPayload['param_trip_style'],
    'override_param_activity_level': tripPayload['param_activity_level'],
    'override_param_extra':          extra.isNotEmpty ? extra : null,
  }).eq('trip_id', _tripId!).eq('use_trip_params', true);
}

  /// Raeumt alle sichtbaren Karten-Reste des aktuellen Trips
  /// (Highlights, Route, KI-Stops, Pins, Warnungen). T-049/T-053.
  Future<void> _clearMapVisuals() async {
    if (!_mapReady) return;
    const empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};
    for (final s in _stops.where((s) =>
        s['is_container'] == true && s['place_id_ne'] != null)) {
      final layer = s['place_level'] == 'country' ? 'eu-countries-fill' : 'regions-fill';
      await _highlightFeature?.call(s['place_id_ne'] as String, layer, 'none');
    }
    try { await _updateRoute?.call(Map<String, dynamic>.from(empty)); } catch (_) {}
    try { await _updateAiStops?.call(Map<String, dynamic>.from(empty)); } catch (_) {}
    try { await _updateContainerPins?.call(Map<String, dynamic>.from(empty)); } catch (_) {}
    try { await _updateWarningMarkers?.call(Map<String, dynamic>.from(empty)); } catch (_) {}
  }

  Future<void> _loadOrCreateRouteVersion() async {
    if (_tripId == null) return;
    final existing = await SupaFlow.client.from('route_versions').select('id')
        .eq('trip_id', _tripId!).eq('is_active', true).limit(1).maybeSingle();
    if (!mounted) return;
    if (existing != null) { setState(() => _routeVersionId = existing['id']); }
    else {
      final rv = await SupaFlow.client.from('route_versions').insert({
        'trip_id': _tripId, 'owner_id': SupaFlow.client.auth.currentUser?.id,
        'version_no': 1, 'is_active': true, 'generated_by': 'user', 'generation_mode': 'manual',
      }).select().single();
      if (!mounted) return;
      setState(() => _routeVersionId = rv['id']);
    }
  }

  Future<void> _loadStops({bool runChecks = true}) async {
    if (_tripId == null) return;
    var q = SupaFlow.client.from('stops').select(
  'id, place_name, place_level, place_id_ne, is_container, sequence_index, lat, lng, '
  'stop_type, stop_role, parent_stop_id, source, planned_days, start_date, end_date, is_time_fixed, '
  'use_trip_params, override_param_group_type, override_param_diet, override_param_budget, '
  'override_param_trip_style, override_param_activity_level'
).eq('trip_id', _tripId!);
if (_routeVersionId != null) q = q.eq('route_version_id', _routeVersionId!);
final data = await q.order('sequence_index');
   if (!mounted) return;
    setState(() => _stops = List<Map<String, dynamic>>.from(data));
    _calculateTimes();
    if (runChecks) {
      await _autoDeriveTripDates();
      final w = _getWarnings();
      if (!mounted) return;
      setState(() => _warnings = w);
      await _updateWarningMarkersOnMap();
      await _checkUpgradeNeeded();
      await _loadRouteVersions();
    }
    if (_mapReady) {
      await _highlightExistingStops();
      await _showAiStopsOnMap();
      await _updateRouteLine();
    }
  }

  void _calculateTimes() {
    int total = 0;
    for (final c in _stops.where((s) => s['is_container'] == true && s['parent_stop_id'] == null)) {
      final children = _stops.where((s) =>
          s['parent_stop_id'] == c['id'] &&
          s['stop_type'] != 'prefer' && s['stop_type'] != 'never').toList();
      final childSum = children.fold<int>(0, (sum, ch) => sum + ((ch['planned_days'] as int?) ?? 0));
      c['child_days_sum'] = childSum;
      final planned = c['planned_days'] as int?;
      c['open_days'] = planned != null ? planned - childSum : null;
      total += planned ?? childSum;
    }
    setState(() => _totalDaysUsed = total);
  }

  Future<void> _autoDeriveTripDates() async {
    if (_tripId == null) return;
    final trip = _allTrips.firstWhere((t) => t['id'] == _tripId, orElse: () => {});
    if (trip.isEmpty || trip['start_date'] != null) return;
    final topLevel = _stops.where((s) => s['parent_stop_id'] == null && s['stop_type'] == 'container').toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    if (topLevel.isEmpty) return;
    final firstDate = topLevel.first['start_date'] as String?;
    if (firstDate == null) return;
    await SupaFlow.client.from('trips').update({'start_date': firstDate}).eq('id', _tripId!);
    await _loadAllTrips();
    final idx = _allTrips.indexWhere((t) => t['id'] == _tripId);
    if (!mounted) return;
    if (idx >= 0) setState(() => _tripParams = _extractTripParams(_allTrips[idx]));
  }

  // ── Warning System ──────────────────────────────────────────
  List<Map<String, dynamic>> _getWarnings() {
    final warnings = <Map<String, dynamic>>[];
    final trip = _allTrips.firstWhere((t) => t['id'] == _tripId, orElse: () => {});
    final tripStart = trip.isNotEmpty ? DateTime.tryParse(trip['start_date'] ?? '') : null;
    final tripEnd   = trip.isNotEmpty ? DateTime.tryParse(trip['end_date']   ?? '') : null;
    final tripTotalDays = trip.isNotEmpty ? trip['total_days'] as int? : null;
    final topLevel = _stops.where((s) => s['parent_stop_id'] == null).toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    final activeTop = topLevel.where((s) => s['stop_type'] != 'prefer' && s['stop_type'] != 'never').toList();

    // 1. child_sum_exceeds
    for (final c in activeTop) {
      final planned = c['planned_days'] as int?;
      if (planned == null) continue;
      final childSum = (c['child_days_sum'] as int?) ?? 0;
      if (childSum > planned)
        warnings.add({'type': 'child_sum_exceeds', 'stopId': c['id'],
          'message': '${c['place_name']}: $childSum Tage belegt, nur $planned verfügbar',
          'lat': c['lat'], 'lng': c['lng']});
    }

    // 2. trip_days_exceeded: sum of container days > trip total_days
    if (tripTotalDays != null) {
      final containerSum = activeTop.fold<int>(0, (sum, c) {
        final p = c['planned_days'] as int?;
        final cs = (c['child_days_sum'] as int?) ?? 0;
        return sum + (p ?? cs);
      });
      if (containerSum > tripTotalDays)
        warnings.add({'type': 'trip_days_exceeded', 'stopId': null,
          'message': '$containerSum Tage geplant, Trip hat nur $tripTotalDays Tage',
          'lat': null, 'lng': null});
    }

    // 3. invalid_date_range: start > end for any stop
    for (final s in _stops.where((s) => s['stop_type'] != 'prefer' && s['stop_type'] != 'never')) {
      final start = DateTime.tryParse(s['start_date'] ?? '');
      final end   = DateTime.tryParse(s['end_date']   ?? '');
      if (start != null && end != null && start.isAfter(end))
        warnings.add({'type': 'invalid_date_range', 'stopId': s['id'],
          'message': '${s['place_name']}: Startdatum liegt nach Enddatum',
          'lat': s['lat'], 'lng': s['lng']});
    }

    // 4. date_triangle_inconsistent: all three set but start+days-1 != end
    for (final s in _stops.where((s) => s['stop_type'] != 'prefer' && s['stop_type'] != 'never')) {
      final start = DateTime.tryParse(s['start_date'] ?? '');
      final end   = DateTime.tryParse(s['end_date']   ?? '');
      final days  = s['planned_days'] as int?;
      if (start != null && end != null && days != null) {
        final expected = start.add(Duration(days: days - 1));
        if (expected != end)
          warnings.add({'type': 'date_triangle_inconsistent', 'stopId': s['id'],
            'message': '${s['place_name']}: Start + Tage stimmt nicht mit Enddatum überein',
            'lat': s['lat'], 'lng': s['lng']});
      }
    }

    // 5. container_outside_trip (uses effective dates)
    if (tripStart != null || tripEnd != null) {
      for (final c in activeTop) {
        final eff = _getEffectiveDates(c);
        final cStart = eff['start']; final cEnd = eff['end'];
        if (tripStart != null && cStart != null && cStart.isBefore(tripStart))
          warnings.add({'type': 'container_outside_trip', 'stopId': c['id'],
            'message': '${c['place_name']}: Beginn liegt vor Trip-Start',
            'lat': c['lat'], 'lng': c['lng']});
        if (tripEnd != null && cEnd != null && cEnd.isAfter(tripEnd))
          warnings.add({'type': 'container_outside_trip', 'stopId': c['id'],
            'message': '${c['place_name']}: Ende liegt nach Trip-Ende',
            'lat': c['lat'], 'lng': c['lng']});
      }
    }

    // 6. stop_outside_trip
    if (tripStart != null || tripEnd != null) {
      for (final s in _stops.where((s) => s['parent_stop_id'] != null &&
          s['stop_type'] != 'prefer' && s['stop_type'] != 'never')) {
        final sStart = DateTime.tryParse(s['start_date'] ?? '');
        final sEnd   = DateTime.tryParse(s['end_date']   ?? '');
        if (tripStart != null && sStart != null && sStart.isBefore(tripStart))
          warnings.add({'type': 'stop_outside_trip', 'stopId': s['id'],
            'message': '${s['place_name']}: Start liegt vor Trip-Beginn',
            'lat': s['lat'], 'lng': s['lng']});
        if (tripEnd != null && sEnd != null && sEnd.isAfter(tripEnd))
          warnings.add({'type': 'stop_outside_trip', 'stopId': s['id'],
            'message': '${s['place_name']}: Ende liegt nach Trip-Ende',
            'lat': s['lat'], 'lng': s['lng']});
      }
    }

    // 7. stop_outside_container (uses effective container dates)
    for (final c in activeTop) {
      final eff = _getEffectiveDates(c);
      final cStart = eff['start']; final cEnd = eff['end'];
      // Only check if container has explicit dates (not just derived)
      final explicitStart = DateTime.tryParse(c['start_date'] ?? '');
      final explicitEnd   = DateTime.tryParse(c['end_date']   ?? '');
      if (explicitStart == null && explicitEnd == null) continue;
      for (final s in _stops.where((s) =>
          s['parent_stop_id'] == c['id'] &&
          s['stop_type'] != 'prefer' && s['stop_type'] != 'never')) {
        final sStart = DateTime.tryParse(s['start_date'] ?? '');
        final sEnd   = DateTime.tryParse(s['end_date']   ?? '');
        if (explicitStart != null && sStart != null && sStart.isBefore(explicitStart))
          warnings.add({'type': 'stop_outside_container', 'stopId': s['id'],
            'message': '${s['place_name']}: Start liegt vor Container-Beginn',
            'lat': s['lat'], 'lng': s['lng']});
        if (explicitEnd != null && sEnd != null && sEnd.isAfter(explicitEnd))
          warnings.add({'type': 'stop_outside_container', 'stopId': s['id'],
            'message': '${s['place_name']}: Ende liegt nach Container-Ende',
            'lat': s['lat'], 'lng': s['lng']});
      }
    }

    // 8. container_overlap (uses effective dates)
    for (int i = 0; i < activeTop.length - 1; i++) {
      final a = activeTop[i]; final b = activeTop[i + 1];
      final aEff = _getEffectiveDates(a); final bEff = _getEffectiveDates(b);
      final aEnd = aEff['end']; final bStart = bEff['start'];
      if (aEnd != null && bStart != null && aEnd.isAfter(bStart))
        warnings.add({'type': 'container_overlap', 'stopId': a['id'],
          'message': '${a['place_name']} überschneidet ${b['place_name']}',
          'lat': a['lat'], 'lng': a['lng']});
    }

    // 9. stop_overlap (within container)
    for (final c in activeTop) {
      final children = _stops.where((s) =>
          s['parent_stop_id'] == c['id'] &&
          s['stop_type'] != 'prefer' && s['stop_type'] != 'never').toList()
        ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
      for (int i = 0; i < children.length - 1; i++) {
        final a = children[i]; final b = children[i + 1];
        final aEnd   = DateTime.tryParse(a['end_date']   ?? '');
        final bStart = DateTime.tryParse(b['start_date'] ?? '');
        if (aEnd != null && bStart != null && aEnd.isAfter(bStart))
          warnings.add({'type': 'stop_overlap', 'stopId': a['id'],
            'message': '${a['place_name']} überschneidet ${b['place_name']}',
            'lat': a['lat'], 'lng': a['lng']});
      }
    }

    // 10. trip_date_conflict
    if (tripStart != null && activeTop.isNotEmpty) {
      final firstEff = _getEffectiveDates(activeTop.first);
      final firstStart = firstEff['start'];
      if (firstStart != null && tripStart.isAfter(firstStart))
        warnings.add({'type': 'trip_date_conflict', 'stopId': null,
          'message': 'Trip-Start liegt nach dem ersten Container-Start',
          'lat': null, 'lng': null});
    }

    return warnings;
  }

  Future<void> _updateWarningMarkersOnMap() async {
    if (!_mapReady || _updateWarningMarkers == null) return;
    final seen = <String>{};
    final features = <Map<String, dynamic>>[];
    for (final w in _warnings) {
      final lat = w['lat']; final lng = w['lng'];
      if (lat == null || lng == null) continue;
      final key = '${lat}_$lng';
      if (seen.contains(key)) continue;
      seen.add(key);
      features.add({'type': 'Feature', 'properties': {'message': w['message']},
        'geometry': {'type': 'Point', 'coordinates': [lng, lat]}});
    }
    await _updateWarningMarkers!({'type': 'FeatureCollection', 'features': features});
  }

  Future<void> _checkUpgradeNeeded() async {
    final upgradeWarnings = _warnings.where((w) => w['type'] == 'child_sum_exceeds').toList();
    if (upgradeWarnings.isEmpty || !mounted) return;
    final ctx = context;
    _setMapLocked?.call(true);
    await showDialog<void>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 22),
          const SizedBox(width: 8),
          Text('Tage ueberschritten', style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 16)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Geplante Tage reichen nicht:', style: GoogleFonts.nunito(fontSize: 13, color: const Color(0xFF888888))),
          const SizedBox(height: 10),
          ...upgradeWarnings.map((w) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const Icon(Icons.circle, size: 6, color: Color(0xFFE85D3A)),
              const SizedBox(width: 8),
              Expanded(child: Text(w['message'] as String, style: GoogleFonts.nunito(fontSize: 13))),
            ]),
          )),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx),
              child: Text('Selbst anpassen', style: GoogleFonts.nunito(color: const Color(0xFF888888)))),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(dCtx);
              for (final w in upgradeWarnings) {
                final stopId = w['stopId'] as String?;
                if (stopId == null) continue;
                final container = _stops.firstWhere((s) => s['id'] == stopId, orElse: () => {});
                if (container.isEmpty) continue;
                final childSum = (container['child_days_sum'] as int?) ?? 0;
                await SupaFlow.client.from('stops').update({'planned_days': childSum}).eq('id', stopId);
              }
              await _loadStops();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE8A838),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: Text('Aufstocken', style: GoogleFonts.nunito(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    _setMapLocked?.call(false);
  }

  // ── Glaettung ───────────────────────────────────────────────
  void _applyGlaettung() {
    final snapshot = <String, Map<String, dynamic>>{};
    final topLevel = _stops.where((s) =>
        s['parent_stop_id'] == null && s['stop_type'] != 'prefer' && s['stop_type'] != 'never').toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));

    for (final c in topLevel) {
      final children = _stops.where((s) =>
          s['parent_stop_id'] == c['id'] &&
          s['stop_type'] != 'prefer' && s['stop_type'] != 'never').toList()
        ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));

      // Step A: Reorder children by start_date (undated go to end)
      final dated   = children.where((ch) => DateTime.tryParse(ch['start_date'] ?? '') != null).toList()
        ..sort((a, b) => DateTime.parse(a['start_date']).compareTo(DateTime.parse(b['start_date'])));
      final undated = children.where((ch) => DateTime.tryParse(ch['start_date'] ?? '') == null).toList();
      final sorted  = [...dated, ...undated];
      for (int i = 0; i < sorted.length; i++) {
        final ch = sorted[i];
        final id = ch['id'] as String;
        snapshot.putIfAbsent(id, () => {});
        snapshot[id]!['sequence_index'] = ch['sequence_index'];
        ch['sequence_index'] = i + 1;
      }

      // Step B: Fix overlaps — shorten planned_days + recalc end_date
      for (int i = 0; i < sorted.length - 1; i++) {
        final a = sorted[i]; final b = sorted[i + 1];
        final aEnd   = DateTime.tryParse(a['end_date']   ?? '');
        final bStart = DateTime.tryParse(b['start_date'] ?? '');
        if (aEnd == null || bStart == null || !aEnd.isAfter(bStart)) continue;
        final aStart = DateTime.tryParse(a['start_date'] ?? '');
        if (aStart == null) continue;
        final id = a['id'] as String;
        snapshot.putIfAbsent(id, () => {});
        snapshot[id]!['planned_days'] = a['planned_days'];
        snapshot[id]!['end_date']     = a['end_date'];
        final newDays = bStart.difference(aStart).inDays;
        final safeDays = newDays > 0 ? newDays : 1;
        a['planned_days'] = safeDays;
        a['end_date'] = _fmt(aStart.add(Duration(days: safeDays - 1)));
      }
    }

    setState(() { _glaettungSnapshot = snapshot; _glaettungPending = true; });
    _calculateTimes();
    setState(() => _warnings = _getWarnings());
  }

  void _undoGlaettung() {
    for (final entry in _glaettungSnapshot.entries) {
      final stop = _stops.firstWhere((s) => s['id'] == entry.key, orElse: () => {});
      if (stop.isEmpty) continue;
      final orig = entry.value;
      if (orig.containsKey('planned_days'))  stop['planned_days']  = orig['planned_days'];
      if (orig.containsKey('start_date'))    stop['start_date']    = orig['start_date'];
      if (orig.containsKey('end_date'))      stop['end_date']      = orig['end_date'];
      if (orig.containsKey('sequence_index')) stop['sequence_index'] = orig['sequence_index'];
    }
    setState(() { _glaettungPending = false; _glaettungSnapshot = {}; });
    _calculateTimes();
    setState(() => _warnings = _getWarnings());
  }

  Future<void> _saveGlaettung() async {
    for (final entry in _glaettungSnapshot.entries) {
      final stop = _stops.firstWhere((s) => s['id'] == entry.key, orElse: () => {});
      if (stop.isEmpty) continue;
      await SupaFlow.client.from('stops').update({
        'planned_days':   stop['planned_days'],
        'start_date':     stop['start_date'],
        'end_date':       stop['end_date'],
        'sequence_index': stop['sequence_index'],
      }).eq('id', entry.key);
    }
    if (!mounted) return;
    setState(() { _glaettungPending = false; _glaettungSnapshot = {}; });
    await _loadStops();
  }

  // ── Check Trip Dialog ───────────────────────────────────────
  Future<void> _showCheckTripDialog() async {
    _setMapLocked?.call(true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF5F0E8),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6, maxChildSize: 0.9, minChildSize: 0.4, expand: false,
        builder: (ctx, sc) => Column(children: [
          Container(margin: const EdgeInsets.only(top: 10, bottom: 12), width: 36, height: 4,
              decoration: BoxDecoration(color: const Color(0xFFCCC5B5), borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              Icon(_warnings.isEmpty ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                  color: _warnings.isEmpty ? const Color(0xFF3A9E8F) : const Color(0xFFF59E0B), size: 22),
              const SizedBox(width: 8),
              Text('Trip Check', style: GoogleFonts.nunito(fontSize: 18, fontWeight: FontWeight.w700, color: const Color(0xFF2C2416))),
              const Spacer(),
              _statusPill(_warnings.isEmpty ? 'Alles OK' : '${_warnings.length} Hinweis${_warnings.length == 1 ? '' : 'e'}',
                  _warnings.isEmpty ? const Color(0xFF3A9E8F) : const Color(0xFFF59E0B)),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFFE0D8C8)),
          Expanded(
            child: _warnings.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_outline, size: 56, color: Color(0xFF3A9E8F)),
                  const SizedBox(height: 12),
                  Text('Keine Konflikte', style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w600, color: const Color(0xFF888888))),
                ]))
              : ListView(controller: sc, padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  children: _buildWarningItems(ctx)),
          ),
          if (_warnings.any((w) => w['type'] == 'container_overlap' || w['type'] == 'stop_overlap'))
            SafeArea(child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(width: double.infinity, child: ElevatedButton.icon(
                onPressed: () { Navigator.pop(ctx); _applyGlaettung(); },
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: Text('Automatische Glaettung', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4A90D9), foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 12)),
              )),
            )),
        ]),
      ),
    );
    _setMapLocked?.call(false);
  }

  Widget _statusPill(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
    child: Text(label, style: GoogleFonts.nunito(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
  );

  List<Widget> _buildWarningItems(BuildContext ctx) {
    final typeConfig = <String, Map<String, dynamic>>{
      'child_sum_exceeds':          {'label': 'Tage ueberschritten',       'icon': Icons.access_time,         'color': const Color(0xFFE85D3A)},
      'trip_days_exceeded':         {'label': 'Trip-Tage ueberschritten',  'icon': Icons.calendar_today,      'color': const Color(0xFFE85D3A)},
      'invalid_date_range':         {'label': 'Ungueltige Datumsangabe',   'icon': Icons.error_outline,       'color': const Color(0xFFE85D3A)},
      'date_triangle_inconsistent': {'label': 'Datum/Tage inkonsistent',   'icon': Icons.warning_amber,       'color': const Color(0xFFE8A838)},
      'container_outside_trip':     {'label': 'Container ausserhalb Trip', 'icon': Icons.date_range,          'color': const Color(0xFFE8A838)},
      'stop_outside_trip':          {'label': 'Stop ausserhalb Trip',      'icon': Icons.date_range,          'color': const Color(0xFFE8A838)},
      'stop_outside_container':     {'label': 'Stop ausserhalb Container', 'icon': Icons.layers_outlined,     'color': const Color(0xFFE8A838)},
      'container_overlap':          {'label': 'Ueberlappende Container',   'icon': Icons.compare_arrows,      'color': const Color(0xFFE85D3A)},
      'stop_overlap':               {'label': 'Ueberlappende Stops',       'icon': Icons.compare_arrows,      'color': const Color(0xFFE85D3A)},
      'trip_date_conflict':         {'label': 'Trip-Datum Konflikt',       'icon': Icons.event_busy_outlined, 'color': const Color(0xFFE8A838)},
    };
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final w in _warnings) groups.putIfAbsent(w['type'] as String, () => []).add(w);
    final result = <Widget>[];
    for (final entry in groups.entries) {
      final cfg   = typeConfig[entry.key] ?? {'label': 'Warnung', 'icon': Icons.warning_amber, 'color': const Color(0xFFE8A838)};
      final label = cfg['label'] as String;
      final icon  = cfg['icon']  as IconData;
      final color = cfg['color'] as Color;
      result.add(Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(children: [
          Icon(icon, size: 14, color: color), const SizedBox(width: 6),
          Text(label, style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 13, color: color)),
          const SizedBox(width: 6),
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: Text('${entry.value.length}', style: GoogleFonts.nunito(fontSize: 11, color: color, fontWeight: FontWeight.w700))),
        ]),
      ));
      for (final w in entry.value) {
        final stopId = w['stopId'] as String?;
        final stop   = stopId != null ? _stops.firstWhere((s) => s['id'] == stopId, orElse: () => {}) : <String, dynamic>{};
        result.add(Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withOpacity(0.25))),
          child: Row(children: [
            Expanded(child: Text(w['message'] as String, style: GoogleFonts.nunito(fontSize: 13))),
            if (stop.isNotEmpty) ...[
              const SizedBox(width: 8),
              GestureDetector(onTap: () { Navigator.pop(ctx); _showStopParamsDialog(stop); },
                child: Container(padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: const Color(0xFFF5F0E8), borderRadius: BorderRadius.circular(6)),
                  child: const Icon(Icons.tune, size: 14, color: Color(0xFF888888)))),
            ],
            if (w['type'] == 'child_sum_exceeds' && stop.isNotEmpty) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () async {
                  Navigator.pop(ctx);
                  final childSum = (stop['child_days_sum'] as int?) ?? 0;
                  await SupaFlow.client.from('stops').update({'planned_days': childSum}).eq('id', stop['id']);
                  await _loadStops();
                },
                child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFFE8A838), borderRadius: BorderRadius.circular(6)),
                  child: Text('Aufstocken', style: GoogleFonts.nunito(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)))),
            ],
          ]),
        ));
      }
      result.add(const SizedBox(height: 6));
    }
    return result;
  }

  Widget _buildWarningBadge(String stopId) {
    final count = _warnings.where((w) => w['stopId'] == stopId).length;
    if (count == 0) return const SizedBox.shrink();
    return GestureDetector(
      onTap: _showCheckTripDialog,
      child: Container(width: 18, height: 18, decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle),
        child: Center(child: Text('!', style: GoogleFonts.nunito(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w800)))),
    );
  }

  // ── Re-run Guard ────────────────────────────────────────────
  Future<bool> _canRerun() async {
    final trip = _allTrips.firstWhere((t) => t['id'] == _tripId, orElse: () => {});
    final hasStart = trip['start_date'] != null && (trip['start_date'] as String).isNotEmpty;
    final hasDays  = trip['total_days'] != null;
    if (!hasStart || !hasDays) {
      _setMapLocked?.call(true);
      await showDialog<void>(context: context, builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [const Icon(Icons.info_outline, color: Color(0xFF4A90D9), size: 22), const SizedBox(width: 8),
          Text('Vor dem Re-run', style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 16))]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Die KI braucht diese Infos:', style: GoogleFonts.nunito(fontSize: 13, color: const Color(0xFF888888))),
          const SizedBox(height: 12),
          if (!hasStart) _prereqRow(Icons.calendar_today_outlined, 'Startdatum', 'Bestimmt Jahreszeit & Wetter'),
          if (!hasDays)  _prereqRow(Icons.schedule, 'Gesamttage', 'Verhindert Over-/Underplanning'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Abbrechen')),
          ElevatedButton(onPressed: () { Navigator.pop(dCtx); _showTripDialog(isEdit: true); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE8A838),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: Text('Trip bearbeiten', style: GoogleFonts.nunito(color: Colors.white, fontWeight: FontWeight.w600))),
        ],
      ));
      _setMapLocked?.call(false);
      return false;
    }
    if (_warnings.isNotEmpty) {
      _setMapLocked?.call(true);
      await showDialog<void>(context: context, builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 22), const SizedBox(width: 8),
          Text('Offene Konflikte', style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 16))]),
        content: Text('Es gibt noch ${_warnings.length} offene Hinweis${_warnings.length == 1 ? '' : 'e'}. '
            'Bitte loes diese zuerst.', style: GoogleFonts.nunito(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Abbrechen')),
          ElevatedButton(onPressed: () { Navigator.pop(dCtx); _showCheckTripDialog(); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF59E0B),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: Text('Trip Check oeffnen', style: GoogleFonts.nunito(color: Colors.white, fontWeight: FontWeight.w600))),
        ],
      ));
      _setMapLocked?.call(false);
      return false;
    }
    return true;
  }

  Widget _prereqRow(IconData icon, String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(children: [
      Icon(icon, size: 18, color: const Color(0xFF4A90D9)), const SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w700)),
        Text(subtitle, style: GoogleFonts.nunito(fontSize: 11, color: const Color(0xFF888888))),
      ]),
    ]),
  );

  // ── Trip Dialog ─────────────────────────────────────────────
  Future<void> _showTripDialog({bool isEdit = false}) async {
  final nameCtrl  = TextEditingController(text: isEdit ? _tripName : '');
  final startCtrl = TextEditingController(text: isEdit ? (_tripParams['start_date'] ?? '') : '');
  final endCtrl   = TextEditingController(text: isEdit ? (_tripParams['end_date']   ?? '') : '');
  final daysCtrl  = TextEditingController(text: isEdit ? (_tripParams['total_days']?.toString() ?? '') : '');
  final groupSizeCtrl    = TextEditingController(text: isEdit ? (_tripParams['group_size']?.toString() ?? '') : '');
  final ageGroupsCtrl    = TextEditingController(text: isEdit ? (_tripParams['age_groups'] ?? '') : '');
  final maxTravelCtrl    = TextEditingController(text: isEdit ? (_tripParams['max_travel_time_per_day_h']?.toString() ?? '') : '');
  final budgetMinCtrl    = TextEditingController(text: isEdit ? (_tripParams['budget_range_eur']?['min']?.toString() ?? '') : '');
  final budgetMaxCtrl    = TextEditingController(text: isEdit ? (_tripParams['budget_range_eur']?['max']?.toString() ?? '') : '');
  final budgetDayCtrl    = TextEditingController(text: isEdit ? (_tripParams['budget_per_day_eur']?.toString() ?? '') : '');
 
  String? groupType     = isEdit ? _tripParams['group_type']     : null;
  String? diet          = isEdit ? _tripParams['diet']           : null;
  String? budget        = isEdit ? _tripParams['budget']         : null;
  String? tripStyle     = isEdit ? _tripParams['trip_style']     : null;
  String? activityLevel = isEdit ? _tripParams['activity_level'] : null;
  String? locationChange= isEdit ? _tripParams['location_change_willingness'] : null;
  bool hasOwnVehicle    = isEdit ? (_tripParams['has_own_vehicle'] ?? false) : false;
 
  List<String> tripOccasion    = isEdit ? _toStringList(_tripParams['trip_occasion'])    : [];
  List<String> vacationType    = isEdit ? _toStringList(_tripParams['vacation_type'])    : [];
  List<String> accommodationType= isEdit ? _toStringList(_tripParams['accommodation_type']): [];
  List<String> sportsActivities = isEdit ? _toStringList(_tripParams['sports_activities']) : [];
  List<String> culturalInterests= isEdit ? _toStringList(_tripParams['cultural_interests']): [];
  List<String> culinaryInterests= isEdit ? _toStringList(_tripParams['culinary_interests']): [];
  List<String> transportModes  = isEdit ? _toStringList(_tripParams['transport_modes'])  : [];
 
  _setMapLocked?.call(true);
  final confirmed = await showDialog<bool>(
    context: context, barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      // Hierarchical logic
      final occasionOptions = _occasionOptionsForGroup(groupType);
      final showAgeGroups   = groupType == 'family';
 
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(isEdit ? 'Trip bearbeiten' : 'Neuer Trip',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─ Name ──────────────────────────────────────────
              TextField(
                controller: nameCtrl, autofocus: !isEdit,
                decoration: const InputDecoration(labelText: 'Trip Name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
 
              // ─ 1. Reisegruppe ─────────────────────────────────
              _sectionLabel('1 · Reisegruppe & Personen'), const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _paramDropdown('Gruppe', groupType,
                  ['solo', 'couple', 'family', 'friends'],
                  (v) => setS(() { groupType = v; tripOccasion = []; }),
                  labels: const {'solo': 'Solo', 'couple': 'Paar', 'family': 'Familie', 'friends': 'Freunde'})),
                const SizedBox(width: 8),
                Expanded(child: TextField(
                  controller: groupSizeCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Personen', border: OutlineInputBorder(), isDense: true),
                )),
              ]),
              if (occasionOptions.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildMultiSelectChips(
                  label: 'Reiseanlass',
                  options: occasionOptions,
                  selected: tripOccasion,
                  onChanged: (v) => setS(() => tripOccasion = v),
                  labels: const {
                    'honeymoon': '💑 Honeymoon', 'couple_trip': '❤️ Paar-Trip',
                    'family_trip': '👨‍👩‍👧 Familienreise', 'solo_travel': '🧳 Solo',
                    'bachelor_party': '🎉 JGA', 'bachelorette_party': '👰 JGAB',
                    'mens_trip': '🍺 Männertrip', 'girls_trip': '💃 Girls Trip',
                    'friends_trip': '🎒 Freundesreise',
                  },
                ),
              ],
              if (showAgeGroups) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: ageGroupsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Altersgruppen (z.B. 35–40, Kind 8)',
                    border: OutlineInputBorder(), isDense: true,
                    hintText: 'z.B. 35–40, Kind 8, Kind 12',
                  ),
                ),
              ],
              const SizedBox(height: 20),
 
              // ─ 2. Zeitraum ────────────────────────────────────
              _sectionLabel('2 · Zeitraum & Dauer'), const SizedBox(height: 8),
              InkWell(
                onTap: () async {
                  final res = await showTripCalendar(
                    context: context,
                    title: 'Reisezeitraum wählen',
                    subtitle: 'Ab heute wählbar',
                    minDate: DateTime.now(),
                    initialStart: DateTime.tryParse(startCtrl.text),
                    initialEnd: DateTime.tryParse(endCtrl.text),
                    initialDays: int.tryParse(daysCtrl.text),
                    showLockToggle: false,
                    allowDurationOnly: true,
                  );
                  if (res == null) return;
                  setS(() {
                    if (res.cleared) {
                      startCtrl.clear(); endCtrl.clear(); daysCtrl.clear();
                    } else if (res.start != null) {
                      startCtrl.text = _fmt(res.start!);
                      endCtrl.text = _fmt(res.end!);
                      daysCtrl.text = '${res.days}';
                    } else {
                      startCtrl.clear(); endCtrl.clear();
                      daysCtrl.text = '${res.days}';
                    }
                  });
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFCCC5B5)),
                    borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.date_range, size: 18, color: Color(0xFF3A9E8F)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(
                      startCtrl.text.isEmpty
                        ? (daysCtrl.text.isEmpty
                            ? 'Reisezeitraum wählen'
                            : '${daysCtrl.text} Tage · ohne Datum')
                        : '${_isoToDe(startCtrl.text)} – ${_isoToDe(endCtrl.text)}   ·   ${daysCtrl.text} Tage',
                      style: GoogleFonts.nunito(fontSize: 14,
                        color: startCtrl.text.isEmpty ? const Color(0xFFAAAAAA) : const Color(0xFF2C2416),
                        fontWeight: FontWeight.w600))),
                    const Icon(Icons.chevron_right, size: 18, color: Color(0xFFCCCCCC)),
                  ]),
                ),
              ),
              const SizedBox(height: 20),
 
              // ─ 3. Budget ──────────────────────────────────────
              _sectionLabel('3 · Budget'), const SizedBox(height: 8),
              _paramDropdown('Budget-Level', budget,
                ['low', 'medium', 'high', 'premium'],
                (v) => setS(() {
                  budget = v;
                  if (v != null) {
                    budgetMinCtrl.clear(); budgetMaxCtrl.clear(); budgetDayCtrl.clear();
                  }
                }),
                labels: const {'low': 'Niedrig', 'medium': 'Mittel', 'high': 'Hoch', 'premium': 'Premium'}),
              const SizedBox(height: 4),
              Text('Entweder Budget-Level oder eigener Rahmen — €/Tag wird berechnet.',
                style: GoogleFonts.nunito(fontSize: 11, color: const Color(0xFF9CA3AF))),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(
                  controller: budgetMinCtrl, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Budget min €', border: OutlineInputBorder(), isDense: true),
                  onChanged: (_) => setS(() {
                    budget = null;
                    _autoBudgetPerDay(budgetMinCtrl, budgetMaxCtrl, budgetDayCtrl, daysCtrl);
                  }),
                )),
                const SizedBox(width: 8),
                Expanded(child: TextField(
                  controller: budgetMaxCtrl, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Budget max €', border: OutlineInputBorder(), isDense: true),
                  onChanged: (_) => setS(() {
                    budget = null;
                    _autoBudgetPerDay(budgetMinCtrl, budgetMaxCtrl, budgetDayCtrl, daysCtrl);
                  }),
                )),
                const SizedBox(width: 8),
                Expanded(child: TextField(
                  controller: budgetDayCtrl, readOnly: true,
                  decoration: const InputDecoration(labelText: '€/Tag (auto)', border: OutlineInputBorder(), isDense: true),
                )),
              ]),
              const SizedBox(height: 20),
 
              // ─ 4. Reisestil ───────────────────────────────────
              _sectionLabel('4 · Urlaubstyp'), const SizedBox(height: 8),
              _buildMultiSelectChips(
                label: 'Urlaubstyp',
                options: const ['beach', 'city_trip', 'nature', 'camping', 'roadtrip', 'party', 'cultural', 'wellness', 'adventure', 'foodie', 'winter_vibes', 'summer_vibes', 'instagrammable', 'hidden_gems'],
                selected: vacationType,
                onChanged: (v) => setS(() => vacationType = v),
                labels: const {
                  'beach': '🏖️ Beach', 'city_trip': '🏙️ City', 'nature': '🌿 Natur',
                  'camping': '⛺ Camping', 'roadtrip': '🚗 Roadtrip', 'party': '🎉 Party',
                  'cultural': '🏛️ Kultur', 'wellness': '🧘 Wellness',
                  'adventure': '🧗 Adventure', 'foodie': '🍜 Foodie',
                  'winter_vibes': '❄️ Winterurlaub', 'summer_vibes': '☀️ Sommerurlaub',
                  'instagrammable': '📸 Instagrammable', 'hidden_gems': '💎 Hidden Gems',
                },
              ),
              const SizedBox(height: 10),
              _buildMultiSelectChips(
                label: 'Unterkunft',
                options: const ['hotel', 'hostel', 'airbnb', 'camping', 'glamping', 'resort'],
                selected: accommodationType,
                onChanged: (v) => setS(() => accommodationType = v),
                labels: const {
                  'hotel': '🏨 Hotel', 'hostel': '🛏️ Hostel', 'airbnb': '🏠 Airbnb',
                  'camping': '⛺ Camping', 'glamping': '✨ Glamping', 'resort': '🌴 Resort',
                },
              ),
              const SizedBox(height: 20),
 
              // ─ 5. Aktivitäten ─────────────────────────────────
              _sectionLabel('5 · Aktivitäten & Interessen'), const SizedBox(height: 8),
              _paramDropdown('Aktivitätslevel', activityLevel,
                ['low', 'moderate', 'high'],
                (v) => setS(() => activityLevel = v),
                labels: const {'low': 'Niedrig', 'moderate': 'Moderat', 'high': 'Hoch'}),
              const SizedBox(height: 10),
              _buildMultiSelectChips(
                label: 'Sport & Outdoor',
                options: const ['hiking', 'cycling', 'fitness', 'racket_sports', 'winter_sports', 'diving', 'surfing', 'yoga', 'swimming', 'running'],
                selected: sportsActivities,
                onChanged: (v) => setS(() => sportsActivities = v),
                labels: const {
                  'hiking': '🥾 Wandern', 'cycling': '🚴 Radfahren', 'fitness': '💪 Fitness',
                  'racket_sports': '🎾 Racket', 'winter_sports': '⛷️ Wintersport', 'diving': '🤿 Tauchen',
                  'surfing': '🏄 Surfen', 'yoga': '🧘 Yoga', 'swimming': '🏊 Schwimmen', 'running': '🏃 Laufen',
                },
              ),
              const SizedBox(height: 10),
              _buildMultiSelectChips(
                label: 'Kulturelle Interessen',
                options: const ['museums', 'historical_sites', 'concerts', 'theatre', 'galleries', 'architecture', 'local_markets'],
                selected: culturalInterests,
                onChanged: (v) => setS(() => culturalInterests = v),
                labels: const {
                  'museums': '🏛️ Museen', 'historical_sites': '🏰 Geschichte',
                  'concerts': '🎵 Konzerte', 'theatre': '🎭 Theater',
                  'galleries': '🖼️ Galerien', 'architecture': '🏗️ Architektur',
                  'local_markets': '🛒 Märkte',
                },
              ),
              const SizedBox(height: 10),
              _buildMultiSelectChips(
                label: 'Kulinarik',
                options: const ['street_food', 'fine_dining', 'cooking_classes', 'wine_tours', 'brewery_tours'],
                selected: culinaryInterests,
                onChanged: (v) => setS(() => culinaryInterests = v),
                labels: const {
                  'street_food': '🌮 Street Food', 'fine_dining': '🍽️ Fine Dining',
                  'cooking_classes': '👨‍🍳 Lokaler Kochkurs', 'wine_tours': '🍷 Weintour',
                  'brewery_tours': '🍺 Brauerei',
                },
              ),
              const SizedBox(height: 20),
 
              // ─ 6. Ernährung ───────────────────────────────────
              _sectionLabel('6 · Ernährung'), const SizedBox(height: 8),
              _paramDropdown('Ernährung', diet,
                ['omnivore', 'vegetarian', 'vegan', 'halal', 'kosher'],
                (v) => setS(() => diet = v),
                labels: const {'omnivore': 'Alles', 'vegetarian': 'Vegetarisch',
                  'vegan': 'Vegan', 'halal': 'Halal', 'kosher': 'Koscher'}),
              const SizedBox(height: 20),
 
              // ─ 7. Transport ───────────────────────────────────
              _sectionLabel('7 · Transport & Mobilität'), const SizedBox(height: 8),
              _buildMultiSelectChips(
                label: 'Transportmittel',
                options: const ['flight', 'train', 'car', 'bicycle', 'on_foot'],
                selected: transportModes,
                onChanged: (v) => setS(() => transportModes = v),
                labels: const {
                  'flight': '✈️ Flug', 'train': '🚂 Bahn / Interrail', 'car': '🚗 Auto',
                  'bicycle': '🚲 Fahrrad', 'on_foot': '🚶 Zu Fuß',
                },
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _paramDropdown('Ortswechsel-Bereitschaft', locationChange,
                  ['low', 'moderate', 'high'],
                  (v) => setS(() => locationChange = v),
                  labels: const {'low': 'Wenig', 'moderate': 'Mittel', 'high': 'Viel'})),
                const SizedBox(width: 8),
                Expanded(child: TextField(
                  controller: maxTravelCtrl, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Max h/Tag reisen', border: OutlineInputBorder(), isDense: true),
                )),
              ]),
              const SizedBox(height: 8),
              _buildToggleParam('Eigenes Fahrzeug / Mietwagen', hasOwnVehicle,
                (v) => setS(() => hasOwnVehicle = v)),
            ],
          )),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: Text('Abbrechen', style: GoogleFonts.nunito(color: const Color(0xFF6B7280)))),
          TextButton(
            onPressed: () { if (nameCtrl.text.trim().isNotEmpty) Navigator.pop(ctx, true); },
            child: Text('Speichern', style: GoogleFonts.nunito(color: const Color(0xFFE8A838), fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }),
  );
  await Future.delayed(const Duration(milliseconds: 300));
  _setMapLocked?.call(false);
  if (confirmed != true) return;
 
  final userId = SupaFlow.client.auth.currentUser?.id;
  if (userId == null) return;
  final s = DateTime.tryParse(startCtrl.text);
  final d = int.tryParse(daysCtrl.text);
  if (s != null && d != null && d > 0) endCtrl.text = _fmt(s.add(Duration(days: d - 1)));
 
  // Neue Params zusammenbauen
  final budgetMin = int.tryParse(budgetMinCtrl.text);
  final budgetMax = int.tryParse(budgetMaxCtrl.text);
  final extra = _buildParamExtra({
    'group_size':                  int.tryParse(groupSizeCtrl.text),
    'age_groups':                  ageGroupsCtrl.text.isNotEmpty ? ageGroupsCtrl.text : null,
    'trip_occasion':               tripOccasion.isNotEmpty ? tripOccasion : null,
    'budget_range_eur':            (budgetMin != null && budgetMax != null) ? {'min': budgetMin, 'max': budgetMax} : null,
    'budget_per_day_eur':          int.tryParse(budgetDayCtrl.text),
    'vacation_type':               vacationType.isNotEmpty ? vacationType : null,
    'accommodation_type':          accommodationType.isNotEmpty ? accommodationType : null,
    'sports_activities':           sportsActivities.isNotEmpty ? sportsActivities : null,
    'cultural_interests':          culturalInterests.isNotEmpty ? culturalInterests : null,
    'culinary_interests':          culinaryInterests.isNotEmpty ? culinaryInterests : null,
    'transport_modes':             transportModes.isNotEmpty ? transportModes : null,
    'has_own_vehicle':             hasOwnVehicle,
    'location_change_willingness': locationChange,
    'max_travel_time_per_day_h':   int.tryParse(maxTravelCtrl.text),
  });
 
  final payload = {
    'name':               nameCtrl.text.trim(),
    'start_date':         startCtrl.text.isNotEmpty ? startCtrl.text : null,
    'end_date':           endCtrl.text.isNotEmpty   ? endCtrl.text   : null,
    'total_days':         int.tryParse(daysCtrl.text),
    'param_group_type':   groupType,
    'param_diet':         diet,
    'param_budget':       budget,
    'param_trip_style':   tripStyle,
    'param_activity_level': activityLevel,
    'param_extra':        extra.isNotEmpty ? extra : null,
  };
 
  if (isEdit && _tripId != null) {
    await SupaFlow.client.from('trips').update(payload).eq('id', _tripId!);
    await _applyTripParamsToStops(payload);
    if (!mounted) return;
    setState(() {
      _tripName = payload['name'] as String;
      final merged = <String, dynamic>{
  'group_type': groupType, 'diet': diet, 'budget': budget,
  'trip_style': tripStyle, 'activity_level': activityLevel,
  'start_date': payload['start_date'], 'end_date': payload['end_date'],
  'total_days': payload['total_days'],
};
merged.addAll(extra);
_tripParams = merged;
    });
    await _loadAllTrips(); await _loadStops();
  } else {
    await SupaFlow.client.from('trips').update({'is_active': false}).eq('owner_id', userId);
    final trip = await SupaFlow.client.from('trips')
        .insert({...payload, 'owner_id': userId, 'is_active': true}).select().single();
    await _clearMapVisuals();
    if (!mounted) return;
    setState(() {
      _tripId = trip['id']; _tripName = trip['name'];
      _tripParams = _extractTripParams(trip);
      _stops = []; _expandedContainers.clear(); _warnings = [];
    });
    await _loadAllTrips(); await _loadOrCreateRouteVersion(); await _loadStops();
  }
}

  // ── Stop Params Dialog ───────────────────────────────────────
  Future<void> _showStopParamsDialog(Map<String, dynamic> stop) async {
    final daysCtrl  = TextEditingController(text: stop['planned_days']?.toString() ?? '');
    final startCtrl = TextEditingController(text: stop['start_date'] ?? '');
    final endCtrl   = TextEditingController(text: stop['end_date']   ?? '');
    String? groupType     = stop['override_param_group_type']     ?? _tripParams['group_type'];
    String? diet          = stop['override_param_diet']           ?? _tripParams['diet'];
    String? budget        = stop['override_param_budget']         ?? _tripParams['budget'];
    String? tripStyle     = stop['override_param_trip_style']     ?? _tripParams['trip_style'];
    String? activityLevel = stop['override_param_activity_level'] ?? _tripParams['activity_level'];
    bool useTripParams    = stop['use_trip_params'] ?? true;
    bool isTimeFixed = stop['is_time_fixed'] ?? false;
    final stopType = stop['stop_type'] as String? ?? 'container';
    final isPrefer = stopType == 'prefer';
    final isNever  = stopType == 'never';

    String? dateWarning() {
      final trip = _allTrips.firstWhere((t) => t['id'] == _tripId, orElse: () => {});
      if (trip.isEmpty) return null;
      final tripStart = DateTime.tryParse(trip['start_date'] ?? '');
      final tripEnd   = DateTime.tryParse(trip['end_date']   ?? '');
      final s = DateTime.tryParse(startCtrl.text);
      final e = DateTime.tryParse(endCtrl.text);
      if (s != null && e != null && s.isAfter(e)) return 'Start liegt nach Enddatum';
      if (tripStart != null && s != null && s.isBefore(tripStart)) return 'Start liegt vor Trip-Beginn';
      if (tripEnd   != null && e != null && e.isAfter(tripEnd))    return 'Ende liegt nach Trip-Ende';
      return null;
    }

    _setMapLocked?.call(true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final warn = dateWarning();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(stop['place_name'] ?? 'Stop', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!isPrefer && !isNever) ...[
              _sectionLabel('Zeit'), const SizedBox(height: 8),
              InkWell(
                onTap: () async {
                  final trip = _allTrips.firstWhere((t) => t['id'] == _tripId, orElse: () => {});
                  final tripStart = DateTime.tryParse(trip['start_date'] ?? '');
                  final tripEnd   = DateTime.tryParse(trip['end_date'] ?? '');
                  final tripDays  = trip['total_days'];
                  final parentId  = stop['parent_stop_id'] as String?;
                  final parentC   = parentId != null
                      ? _stops.firstWhere((s) => s['id'] == parentId,
                          orElse: () => <String, dynamic>{})
                      : <String, dynamic>{};
                  final cStart = DateTime.tryParse(parentC['start_date'] ?? '');
                  final cEnd   = DateTime.tryParse(parentC['end_date'] ?? '');
                  final tripPart = tripStart != null && tripEnd != null
                      ? 'Trip: ${_isoToDe(trip['start_date'])} – ${_isoToDe(trip['end_date'])}${tripDays != null ? ' · $tripDays Tage' : ''}'
                      : '';
                  final containerPart = (cStart != null && cEnd != null)
                      ? '${tripPart.isNotEmpty ? ' · ' : ''}${parentC['place_name'] ?? 'Container'}: ${_isoToDe(parentC['start_date'])} – ${_isoToDe(parentC['end_date'])}'
                      : '';
                  final res = await showTripCalendar(
                    context: context,
                    title: '${stop['place_name'] ?? 'Stop'} — Zeit wählen',
                    subtitle: (tripPart + containerPart).isNotEmpty
                        ? tripPart + containerPart : null,
                    minDate: tripStart ?? DateTime.now(),
                    maxDate: tripEnd,
                    softMinDate: cStart,
                    softMaxDate: cEnd,
                    initialStart: DateTime.tryParse(startCtrl.text),
                    initialEnd: DateTime.tryParse(endCtrl.text),
                    initialDays: int.tryParse(daysCtrl.text),
                    initialFixed: isTimeFixed,
                    showLockToggle: true,
                    allowDurationOnly: true,
                    occupancy: _buildOccupancy(exceptId: stop['id'] as String?),
                  );
                  if (res == null) return;
                  setS(() {
                    if (res.cleared) {
                      startCtrl.clear(); endCtrl.clear(); daysCtrl.clear();
                      isTimeFixed = false;
                    } else if (res.start != null) {
                      startCtrl.text = _fmt(res.start!);
                      endCtrl.text = _fmt(res.end!);
                      daysCtrl.text = '${res.days}';
                      isTimeFixed = res.isFixed;
                    } else {
                      startCtrl.clear(); endCtrl.clear();
                      daysCtrl.text = '${res.days}';
                      isTimeFixed = false;
                    }
                  });
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFCCC5B5)),
                    borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    Icon(isTimeFixed ? Icons.lock : Icons.date_range,
                      size: 18, color: isTimeFixed ? const Color(0xFFE8A838) : const Color(0xFF3A9E8F)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(
                      startCtrl.text.isNotEmpty
                        ? '${_isoToDe(startCtrl.text)} – ${_isoToDe(endCtrl.text)} · ${daysCtrl.text} Tage${isTimeFixed ? ' · fixiert' : ''}'
                        : (daysCtrl.text.isNotEmpty
                            ? '${daysCtrl.text} Tage · ohne Datum'
                            : 'Zeit wählen (Tage oder Zeitraum)'),
                      style: GoogleFonts.nunito(fontSize: 14,
                        color: (startCtrl.text.isEmpty && daysCtrl.text.isEmpty)
                            ? const Color(0xFF888888) : const Color(0xFF2C2416),
                        fontWeight: FontWeight.w600))),
                    const Icon(Icons.chevron_right, size: 18, color: Color(0xFFCCCCCC)),
                  ]),
                ),
              ),
              if (warn != null) ...[const SizedBox(height: 6), Text(warn, style: const TextStyle(color: Color(0xFFE8A838), fontSize: 12))],
              const SizedBox(height: 12),
            ],
            if (!isNever) ...[
              CheckboxListTile(
                value: useTripParams,
                onChanged: (v) => setS(() {
                  useTripParams = v ?? true;
                  if (useTripParams) { groupType = _tripParams['group_type']; diet = _tripParams['diet'];
                    budget = _tripParams['budget']; tripStyle = _tripParams['trip_style']; activityLevel = _tripParams['activity_level']; }
                }),
                title: Text('Trip-Parameter uebernehmen', style: GoogleFonts.nunito(fontSize: 13)),
                subtitle: Text('Aenderungen am Trip uebertragen sich', style: GoogleFonts.nunito(fontSize: 11, color: const Color(0xFF888888))),
                contentPadding: EdgeInsets.zero, dense: true,
              ),
              if (!useTripParams) ...[
                const SizedBox(height: 8), _sectionLabel('Parameter'), const SizedBox(height: 8),
                _paramDropdown('Reisegruppe', groupType, ['solo','couple','family','friends'],
                  (v) => setS(() => groupType = v),
                  labels: const {'solo': 'Solo', 'couple': 'Paar', 'family': 'Familie', 'friends': 'Freunde'}),
                const SizedBox(height: 8),
                _paramDropdown('Ernährung', diet, ['omnivore','vegetarian','vegan','halal','kosher'],
                  (v) => setS(() => diet = v),
                  labels: const {'omnivore': 'Alles', 'vegetarian': 'Vegetarisch', 'vegan': 'Vegan', 'halal': 'Halal', 'kosher': 'Koscher'}),
                const SizedBox(height: 8),
                _paramDropdown('Budget', budget, ['low','medium','high','premium'],
                  (v) => setS(() => budget = v),
                  labels: const {'low': 'Niedrig', 'medium': 'Mittel', 'high': 'Hoch', 'premium': 'Premium'}),
                const SizedBox(height: 8),
                _paramDropdown('Aktivitätslevel', activityLevel, ['low','moderate','high'],
                  (v) => setS(() => activityLevel = v),
                  labels: const {'low': 'Niedrig', 'moderate': 'Moderat', 'high': 'Hoch'}),
              ],
            ],
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Speichern', style: TextStyle(color: Color(0xFFE8A838)))),
          ],
        );
      }),
    );
    await Future.delayed(const Duration(milliseconds: 300));
    _setMapLocked?.call(false);
    if (confirmed != true) return;
    // Enforce triangle: start+days -> end
    final s = DateTime.tryParse(startCtrl.text);
    final d = int.tryParse(daysCtrl.text);
    if (s != null && d != null && d > 0) endCtrl.text = _fmt(s.add(Duration(days: d - 1)));
    await SupaFlow.client.from('stops').update({
      'planned_days': int.tryParse(daysCtrl.text),
      'start_date':   startCtrl.text.isNotEmpty ? startCtrl.text : null,
      'end_date':     endCtrl.text.isNotEmpty   ? endCtrl.text   : null,
      'use_trip_params': useTripParams,
      'is_time_fixed': isTimeFixed,
      'override_param_group_type':     useTripParams ? _tripParams['group_type']     : groupType,
      'override_param_diet':           useTripParams ? _tripParams['diet']           : diet,
      'override_param_budget':         useTripParams ? _tripParams['budget']         : budget,
      'override_param_trip_style':     useTripParams ? _tripParams['trip_style']     : tripStyle,
      'override_param_activity_level': useTripParams ? _tripParams['activity_level'] : activityLevel,
    }).eq('id', stop['id']);
    await _loadStops();
  }

  Map<String, dynamic> _buildParamExtra(Map<String, dynamic> p) {
  final extra = <String, dynamic>{};
  const newKeys = [
    'group_size', 'age_groups', 'trip_occasion', 'budget_range_eur',
    'budget_per_day_eur', 'vacation_type', 'accommodation_type',
    'sports_activities', 'cultural_interests', 'culinary_interests',
    'transport_modes',
    'has_own_vehicle', 'location_change_willingness',
    'max_travel_time_per_day_h',
  ];
  for (final k in newKeys) {
    if (p[k] != null) extra[k] = p[k];
  }
  return extra;
}

Widget _buildMultiSelectChips({
  required String label,
  required List<String> options,
  required List<String> selected,
  required void Function(List<String>) onChanged,
  Map<String, String>? labels,  // optional display labels
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _sectionLabel(label),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: options.map((opt) {
          final isSelected = selected.contains(opt);
          final displayLabel = labels?[opt] ?? opt;
          return GestureDetector(
            onTap: () {
              final updated = List<String>.from(selected);
              if (isSelected) { updated.remove(opt); } else { updated.add(opt); }
              onChanged(updated);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF3A9E8F) : const Color(0xFFF5F0E8),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? const Color(0xFF3A9E8F) : const Color(0xFFDDD8CC),
                ),
              ),
              child: Text(
                displayLabel,
                style: GoogleFonts.nunito(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? Colors.white : const Color(0xFF2C2416),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    ],
  );
}

Widget _buildToggleParam(String label, bool? value, void Function(bool) onChanged) {
  return Row(
    children: [
      Expanded(child: _sectionLabel(label)),
      Switch(
        value: value ?? false,
        onChanged: onChanged,
        activeColor: const Color(0xFF3A9E8F),
      ),
    ],
  );
}

List<String> _occasionOptionsForGroup(String? groupType) {
  switch (groupType) {
    case 'solo':    return ['solo_travel'];
    case 'couple':  return ['honeymoon', 'couple_trip'];
    case 'family':  return ['family_trip'];
    case 'friends': return ['bachelor_party', 'bachelorette_party', 'mens_trip', 'girls_trip', 'friends_trip'];
    default:        return [];
  }
}

List<String> _toStringList(dynamic v) {
  if (v == null) return [];
  if (v is List) return v.map((e) => e.toString()).toList();
  return [];
}

  Widget _sectionLabel(String text) => Text(text,
    style: GoogleFonts.nunito(fontWeight: FontWeight.w600, fontSize: 13, color: const Color(0xFF888888)));

  Widget _paramDropdown(String label, String? value, List<String> options, ValueChanged<String?> onChanged, {Map<String, String>? labels}) =>
    DropdownButtonFormField<String>(
      value: options.contains(value) ? value : null,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      items: options.map((o) => DropdownMenuItem(value: o, child: Text(labels?[o] ?? o))).toList(),
      onChanged: onChanged,
    );

  // ── Map Highlight / AI / Route ──────────────────────────────
  Future<void> _highlightExistingStops() async {
    for (final stop in _stops) {
      if (stop['is_container'] == true) {
        final id = stop['place_id_ne'] as String?;
        final level = stop['place_level'] as String?;
        if (id == null || level == null) continue;
        final layerId  = level == 'country' ? 'eu-countries-fill' : 'regions-fill';
        final stopType = stop['stop_type'] as String?;
        final mapState = stopType == 'prefer' ? 'prefer' : stopType == 'never' ? 'never' : 'selected';
        await _highlightFeature?.call(id, layerId, mapState);
      }
    }
  }

  Future<void> _showAiStopsOnMap() async {
    if (!_mapReady || _updateAiStops == null) return;
    final features = _stops
        .where((s) => s['source'] == 'ai' && s['place_level'] == 'city' && s['lat'] != null && s['lng'] != null)
        .map((s) => {'type': 'Feature', 'properties': {'name': s['place_name'], 'planned_days': s['planned_days'] ?? 0},
          'geometry': {'type': 'Point', 'coordinates': [s['lng'], s['lat']]}}).toList();
    await _updateAiStops!({'type': 'FeatureCollection', 'features': features});
  }

  Future<void> _updateRouteLine() async {
    if (!_mapReady || _updateRoute == null) return;
    final active = _stops.where((s) => s['stop_type'] != 'prefer' && s['stop_type'] != 'never' && s['lat'] != null && s['lng'] != null).toList();
    final containers = active.where((s) => s['parent_stop_id'] == null).toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    final coords = <List<double>>[];
    for (final c in containers) {
      final children = active.where((s) => s['parent_stop_id'] == c['id']).toList()
        ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
      if (children.isEmpty) coords.add([c['lng'] as double, c['lat'] as double]);
      else for (final ch in children) coords.add([ch['lng'] as double, ch['lat'] as double]);
    }
    if (coords.length < 2) {
      const empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};
      try { await _updateRoute!(Map<String, dynamic>.from(empty)); } catch (_) {}
      try { await _updateContainerPins?.call(Map<String, dynamic>.from(empty)); } catch (_) {}
      return;
    }
    await _updateRoute!({'type': 'FeatureCollection', 'features': [
      {'type': 'Feature', 'properties': {}, 'geometry': {'type': 'LineString', 'coordinates': coords}}]});
    final emptyContainerFeatures = containers
        .where((c) => !active.any((s) => s['parent_stop_id'] == c['id']))
        .map((c) => {'type': 'Feature', 'properties': {'name': c['place_name']},
          'geometry': {'type': 'Point', 'coordinates': [c['lng'] as double, c['lat'] as double]}}).toList();
    await _updateContainerPins!({'type': 'FeatureCollection', 'features': emptyContainerFeatures});
  }

  // ── Map Message Handler ──────────────────────────────────────
  Future<void> _handleMapMessage(String message) async {
    final data = jsonDecode(message);
    if (data['type'] == 'mapReady') {
      setState(() => _mapReady = true);
      if (_stops.isNotEmpty) { await _highlightExistingStops(); await _showAiStopsOnMap(); await _updateRouteLine(); await _updateWarningMarkersOnMap(); }
      return;
    }
    if (data['type'] == 'regionsLoaded') { _lastCountryCode = data['payload']['iso3']; await _highlightExistingStops(); return; }
    if (data['type'] == 'replaceTap') {
      _pendingReplacePayload = data['payload'] as Map<String, dynamic>;
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (data['type'] != 'select') return;
    if (_tripId == null || _routeVersionId == null) { await _showTripDialog(isEdit: false); return; }
    final payload  = data['payload'];
    final id       = payload['id'] as String;
    final level    = payload['place_level'] as String;
    final lat      = payload['lat'] as double;
    final lng      = payload['lng'] as double;
    _setMapLocked?.call(true);
    final content  = await SupaFlow.client.from('place_content').select().eq('place_id', id).maybeSingle();
    final action   = await showGeneralDialog<String>(
      context: context, barrierDismissible: false, barrierColor: Colors.transparent,
      pageBuilder: (ctx, _, __) => Align(alignment: Alignment.centerRight,
        child: Padding(padding: const EdgeInsets.only(right: 16, top: 16, bottom: 16),
          child: SizedBox(width: MediaQuery.sizeOf(context).width * 0.28,
            child: _buildPlaceDialog(id: id, placeLevel: level, content: content)))),
    );
    await Future.delayed(const Duration(milliseconds: 450));
    _setMapLocked?.call(false);
    _resetTapping?.call();
    if (action == null) {
      if (_pendingReplacePayload != null) {
        final pending = _pendingReplacePayload!; _pendingReplacePayload = null;
        await _handleMapMessage(jsonEncode({'type': 'select', 'payload': pending}));
      }
      return;
    }
    if (action == 'delete') {
      await SupaFlow.client.from('stops').delete().eq('trip_id', _tripId!).eq('place_id_ne', id);
      await _highlightFeature?.call(id, level == 'country' ? 'eu-countries-fill' : 'regions-fill', 'none');
      await _loadStops(); return;
    }
    try {
      final count = await SupaFlow.client.from('stops').select('id').eq('trip_id', _tripId!);
      final seqIdx = (count as List).length;
      final existing = await SupaFlow.client.from('stops').select('id').eq('trip_id', _tripId!).eq('place_id_ne', id).maybeSingle();
      if (existing != null) {
        await SupaFlow.client.from('stops').update({'stop_type': action}).eq('id', existing['id']);
      } else {
        String? parentStopId;
        const iso2to3 = {'DE':'DEU','FR':'FRA','AT':'AUT','CH':'CHE','IT':'ITA','ES':'ESP',
          'NL':'NLD','BE':'BEL','PL':'POL','CZ':'CZE','HU':'HUN','SK':'SVK','HR':'HRV',
          'DK':'DNK','SE':'SWE','NO':'NOR','GB':'GBR','IE':'IRL','PT':'PRT','GR':'GRC','RO':'ROU','BG':'BGR'};
        if (level == 'region' || level == 'state') {
          String? cc;
          if (id.contains('-')) cc = iso2to3[id.split('-')[0]];
          if (cc != null) {
            final existC = _stops.firstWhere((s) => s['place_id_ne'] == cc && s['place_level'] == 'country', orElse: () => {});
            if (existC.isNotEmpty) { parentStopId = existC['id'] as String?; }
            else {
              final c2 = await SupaFlow.client.from('place_content').select().eq('place_id', cc).maybeSingle();
              final ci = await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
                'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': seqIdx,
                'stop_type': 'container', 'place_level': 'country', 'place_name': c2?['name_de'] ?? cc,
                'place_id_ne': cc, 'place_source': 'natural_earth', 'lat': lat, 'lng': lng,
                'is_container': true, 'source': 'auto', 'is_ai_generated': false, 'use_trip_params': true}).select().single();
              parentStopId = ci['id'] as String?;
              await _highlightFeature?.call(cc, 'eu-countries-fill', 'selected');
            }
          }
        } else if (level == 'city') {
          final cStop = _stops.firstWhere((s) => s['place_level'] == 'country' && s['is_container'] == true && s['place_id_ne'] == _lastCountryCode, orElse: () => {});
          if (cStop.isNotEmpty) { parentStopId = cStop['id'] as String?; }
          else if (_lastCountryCode != null) {
            final c2 = await SupaFlow.client.from('place_content').select().eq('place_id', _lastCountryCode!).maybeSingle();
            final ci = await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
              'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': seqIdx,
              'stop_type': 'container', 'place_level': 'country', 'place_name': c2?['name_de'] ?? _lastCountryCode,
              'place_id_ne': _lastCountryCode, 'place_source': 'natural_earth', 'lat': lat, 'lng': lng,
              'is_container': true, 'source': 'auto', 'is_ai_generated': false, 'use_trip_params': true}).select().single();
            parentStopId = ci['id'] as String?;
            await _highlightFeature?.call(_lastCountryCode!, 'eu-countries-fill', 'selected');
          }
        }
        await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
          'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': seqIdx + 1,
          'stop_type': action, 'place_level': level, 'place_name': content?['name_de'] ?? id,
          'place_id_ne': id, 'place_source': 'natural_earth', 'lat': lat, 'lng': lng,
          'is_container': level != 'city', 'source': 'user', 'is_ai_generated': false,
          'parent_stop_id': parentStopId, 'use_trip_params': true});
        final mapState = action == 'prefer' ? 'prefer' : action == 'never' ? 'never' : 'selected';
        await _highlightFeature?.call(id, level == 'country' ? 'eu-countries-fill' : 'de-states-fill', mapState);
      }
      await _loadStops();
    } catch (e) { debugPrint('handleMapMessage error: $e'); }
  }

  Future<void> _handleSearchResult(Map<String, dynamic> result, int insertAfterIndex) async {
    await _flyTo?.call(result['lat'] as double, result['lng'] as double, 8.0);
    _setMapLocked?.call(true);
    final content     = await SupaFlow.client.from('place_content').select().eq('place_id', result['text']).maybeSingle();
    final designation = result['place_designation'] as String? ?? '';
    final categories  = (result['categories'] as List?)?.cast<String>() ?? [];
    final isAirport   = designation == 'airport' || categories.contains('airport') || result['kind'] == 'aerodrome';
    final placeLevel  = designation == 'country' ? 'country' : designation == 'state' ? 'region' : isAirport ? 'transit' : 'city';
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context, barrierDismissible: true, barrierColor: Colors.transparent,
      builder: (dCtx) => Align(alignment: Alignment.centerRight,
        child: Padding(padding: const EdgeInsets.only(right: 16, top: 16, bottom: 16),
          child: SizedBox(width: MediaQuery.sizeOf(context).width * 0.28,
            child: _buildPlaceDialog(id: result['text'], placeLevel: placeLevel, content: content, isTransit: isAirport)))),
    );
    await Future.delayed(const Duration(milliseconds: 500));
    _setMapLocked?.call(false); _resetTapping?.call();
    if (action == null || action == 'delete') return;
    final addNearbyCity   = action == 'transit_with_city';
    final effectiveAction = isAirport ? 'container' : action;
    await _addStopFromSearch(result, insertAfterIndex, action: effectiveAction, isTransit: isAirport, addNearbyCity: addNearbyCity);
  }

Future<void> _importAiRoute(String jsonString) async {
  final clean = jsonString
      .replaceAll(RegExp(r'//[^\n]*'), '')
      .replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  try {
    final data = jsonDecode(clean);
    final newStops = data['step1a']['new_stops'] as List;
 
    // Alte Versionen deaktivieren
    await SupaFlow.client.from('route_versions')
        .update({'is_active': false})
        .eq('trip_id', _tripId!)
        .neq('id', _routeVersionId!);
 
    final currentRv = await SupaFlow.client.from('route_versions')
        .select('version_no').eq('id', _routeVersionId!).single();
    final nextVersionNo = (currentRv['version_no'] as int? ?? 1) + 1;
 
    final rv = await SupaFlow.client.from('route_versions').insert({
      'trip_id': _tripId,
      'owner_id': SupaFlow.client.auth.currentUser?.id,
      'version_no': nextVersionNo,
      'is_active': true,
      'generated_by': 'ai',
      'generation_mode': 'ai_rerun'
    }).select().single();
    final newRvId = rv['id'] as String;
 
    // Container kopieren
    final containers = _stops.where((s) =>
        s['parent_stop_id'] == null &&
        s['stop_type'] != 'prefer' &&
        s['stop_type'] != 'never').toList();
 
    final Map<String, String> oldToNew = {};
    for (final c in containers) {
      final ins = await SupaFlow.client.from('stops').insert({
        'trip_id': _tripId,
        'route_version_id': newRvId,
        'owner_id': SupaFlow.client.auth.currentUser?.id,
        'place_name': c['place_name'],
        'place_level': c['place_level'],
        'place_id_ne': c['place_id_ne'],
        'lat': c['lat'],
        'lng': c['lng'],
        'sequence_index': c['sequence_index'],
        'stop_type': c['stop_type'],
        'is_container': true,
        'source': c['source'],
        'is_ai_generated': false,
        'use_trip_params': c['use_trip_params'] ?? true,
      }).select().single();
      oldToNew[c['id'] as String] = ins['id'] as String;
    }
 
    // Bestehende Child-Stops kopieren
    final childStops = _stops.where((s) {
      if (s['parent_stop_id'] == null) return false;
      if (s['stop_type'] == 'prefer' || s['stop_type'] == 'never') return false;
      return oldToNew.containsKey(s['parent_stop_id'] as String);
    }).toList();
    for (final child in childStops) {
      final newParentId = oldToNew[child['parent_stop_id'] as String]!;
      await SupaFlow.client.from('stops').insert({
        'trip_id': _tripId,
        'route_version_id': newRvId,
        'owner_id': SupaFlow.client.auth.currentUser?.id,
        'place_name': child['place_name'],
        'place_level': child['place_level'],
        'lat': child['lat'],
        'lng': child['lng'],
        'planned_days': child['planned_days'],
        'parent_stop_id': newParentId,
        'sequence_index': child['sequence_index'],
        'stop_type': child['stop_type'],
        'stop_role': child['stop_role'],
        'is_container': child['is_container'] ?? false,
        'is_ai_generated': false,
        'source': child['source'],
        'use_trip_params': child['use_trip_params'] ?? true,
      });
    }
 
    // ── Fund #7 Fix: Neue KI-Stops mit country_or_region-Zuordnung ──────────
    const validLevels = ['city', 'continent', 'country', 'island_group', 'landmark', 'region', 'state', 'area', 'national_park'];
 
    // Counter für neue Top-Level-Container
    int nextContainerSeqIdx = containers.isNotEmpty
        ? containers.map((c) => (c['sequence_index'] as int? ?? 0)).reduce((a, b) => a > b ? a : b) + 1
        : 1;
 
    // Map für in dieser Session neu angelegte Country-Container
    final Map<String, String> aiContainersByCountry = {};
 
    for (final stop in newStops) {
      final rawLevel = stop['place_level'] as String?;
      final placeLevel = validLevels.contains(rawLevel) ? rawLevel : 'city';
      final stopType = stop['stop_type'] as String? ?? 'place';
 
      String? newParentId;
 
      // Fall 1: KI gibt explicit parent_stop_id → oldToNew-Lookup
      final oldP = stop['parent_stop_id'] as String?;
      if (oldP != null) {
        newParentId = oldToNew[oldP];
      }
 
      // Fall 2: Neuer Top-Level-Container (z.B. neues Land von der KI)
      if (stopType == 'container' || placeLevel == 'country') {
        final countryName = stop['place_name'] as String? ?? '';
        final ins = await SupaFlow.client.from('stops').insert({
          'trip_id': _tripId,
          'route_version_id': newRvId,
          'owner_id': SupaFlow.client.auth.currentUser?.id,
          'place_name': countryName,
          'place_level': placeLevel ?? 'country',
          'lat': stop['lat'],
          'lng': stop['lng'],
          'sequence_index': nextContainerSeqIdx++,
          'stop_type': 'container',
          'is_container': true,
          'is_ai_generated': true,
          'source': 'ai',
          'use_trip_params': true,
        }).select().single();
        // Für spätere Stops in diesem Land merken
        aiContainersByCountry[countryName.toLowerCase()] = ins['id'] as String;
        continue; // Container ist fertig, kein child-insert
      }
 
      // Fall 3: Place-Stop ohne parent → country_or_region für Container-Zuordnung
      if (newParentId == null) {
        final cor = (stop['country_or_region'] as String? ?? '').trim();
        if (cor.isNotEmpty && cor != 'unknown_region') {
          final corKey = cor.toLowerCase();
 
          // Zuerst im diesem Lauf neu erstellte Container prüfen
          if (aiContainersByCountry.containsKey(corKey)) {
            newParentId = aiContainersByCountry[corKey];
          } else {
            // Dann in kopierten bestehenden Containern suchen
            for (final entry in oldToNew.entries) {
              final origC = containers.firstWhere(
                (c) => c['id'] == entry.key, orElse: () => {});
              if (origC.isNotEmpty &&
                  (origC['place_name'] as String? ?? '').toLowerCase() == corKey) {
                newParentId = entry.value;
                aiContainersByCountry[corKey] = newParentId!;
                break;
              }
            }
 
            // Neuen Country-Container anlegen
            if (newParentId == null) {
              final newC = await SupaFlow.client.from('stops').insert({
                'trip_id': _tripId,
                'route_version_id': newRvId,
                'owner_id': SupaFlow.client.auth.currentUser?.id,
                'place_name': cor,
                'place_level': 'country',
                'lat': stop['lat'],
                'lng': stop['lng'],
                'sequence_index': nextContainerSeqIdx++,
                'stop_type': 'container',
                'is_container': true,
                'is_ai_generated': true,
                'source': 'ai',
                'use_trip_params': true,
              }).select().single();
              newParentId = newC['id'] as String;
              aiContainersByCountry[corKey] = newParentId;
            }
          }
        }
      }
 
      // Stop einfügen (immer als place, nie als container)
      await SupaFlow.client.from('stops').insert({
        'trip_id': _tripId,
        'route_version_id': newRvId,
        'owner_id': SupaFlow.client.auth.currentUser?.id,
        'place_name': stop['place_name'],
        'place_level': placeLevel,
        'lat': stop['lat'],
        'lng': stop['lng'],
        'planned_days': stop['planned_days'],
        'parent_stop_id': newParentId,
        'sequence_index': stop['sequence_index'],
        'stop_type': 'place',
        'is_container': false,
        'is_ai_generated': true,
        'source': 'ai',
      });
    }
    // ── Ende Fund #7 Fix ─────────────────────────────────────────────────────
 
    if (!mounted) return;
    setState(() => _routeVersionId = newRvId);
    await _loadStops();
    await _recalcAllDatesFromStart();
    await _loadStops(runChecks: false);
    await _loadRouteVersions();
 
    if (mounted) {
      try { ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('KI-Route importiert'))); } catch (_) {}
    }
  } catch (e) {
    debugPrint('Import error: $e');
    if (mounted) {
      try { ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import fehlgeschlagen: $e'))); } catch (_) {}
    }
  }
}
 

  // ── Place Dialog ─────────────────────────────────────────────
  Widget _buildPlaceDialog({required String id, required String placeLevel, Map<String, dynamic>? content, bool isTransit = false}) {
    return Material(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (content?['image_url'] != null)
          ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Image.network(content!['image_url'], height: 220, width: double.infinity, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholderHeader(isTransit, 220)))
        else _placeholderHeader(isTransit, isTransit ? 80 : 220),
        Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(content?['name_de'] ?? id,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white,
                shadows: [Shadow(color: Colors.black54, blurRadius: 4)]))),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
              child: Text(isTransit ? 'Transit' : placeLevel, style: const TextStyle(fontSize: 11, color: Colors.white70))),
          ]),
          if (!isTransit && content?['description_de'] != null) ...[
            const SizedBox(height: 8),
            Text(content!['description_de'], style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4,
              shadows: [Shadow(color: Colors.black54, blurRadius: 3)]), maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 16),
          if (isTransit) ...[
            _fullBtn('Als Transit hinzufuegen', Icons.flight, const Color(0xFF888888), 'transit'),
            const SizedBox(height: 8),
            _fullBtn('Transit + naheg. Ort', Icons.flight_land, const Color(0xFF4A90D9), 'transit_with_city'),
          ] else Row(children: [
            _actionButton('Nie',    Icons.block,    const Color(0xFFBDBDBD), 'never'),
            const SizedBox(width: 8),
            _actionButton('Gerne', Icons.favorite, const Color(0xFF5BA68A), 'prefer'),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton.icon(onPressed: () => Navigator.pop(context, 'container'),
              icon: const Icon(Icons.add, size: 16), label: const Text('Stop'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE8A838), foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))))),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => Navigator.pop(context, 'delete'),
              child: const Text('Entfernen', style: TextStyle(color: Colors.red, fontSize: 12)))),
            TextButton(onPressed: () => Navigator.pop(context, null),
              child: const Text('Abbrechen', style: TextStyle(color: Color(0xFF888888), fontSize: 12))),
          ]),
        ])),
      ]),
    );
  }

  Widget _placeholderHeader(bool isTransit, double height) => Container(height: height, width: double.infinity,
    decoration: const BoxDecoration(color: Color(0xFFE8D8B8), borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    child: Icon(isTransit ? Icons.flight : Icons.landscape, size: isTransit ? 32 : 48, color: const Color(0xFFE8A838)));

  Widget _fullBtn(String label, IconData icon, Color color, String action) => SizedBox(width: double.infinity,
    child: ElevatedButton.icon(onPressed: () => Navigator.pop(context, action),
      icon: Icon(icon, size: 16), label: Text(label),
      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))));

  Widget _actionButton(String label, IconData icon, Color color, String action) => Expanded(
    child: OutlinedButton.icon(onPressed: () => Navigator.pop(context, action),
      icon: Icon(icon, size: 14, color: color), label: Text(label, style: TextStyle(color: color, fontSize: 12)),
      style: OutlinedButton.styleFrom(side: BorderSide(color: color),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))));

  // ── Sidebar Header ───────────────────────────────────────────
  Widget _buildSidebarHeader() {
    final warningCount = _warnings.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 32, height: 32,
            decoration: BoxDecoration(color: const Color(0xFFE8A838), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.explore, color: Colors.white, size: 18)),
          const SizedBox(width: 8),
          Text('Way2GoX', style: GoogleFonts.nunito(fontSize: 18, fontWeight: FontWeight.w800, color: const Color(0xFF2C2416))),
          const Spacer(),
          GestureDetector(onTap: _showCheckTripDialog,
            child: Stack(clipBehavior: Clip.none, children: [
              const Icon(Icons.health_and_safety_outlined, size: 22, color: Color(0xFF888888)),
              if (warningCount > 0) Positioned(top: -4, right: -4,
                child: Container(width: 16, height: 16,
                  decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle),
                  child: Center(child: Text('$warningCount',
                    style: GoogleFonts.nunito(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w800))))),
            ])),
          const SizedBox(width: 12),
          IconButton(onPressed: () => _showTripDialog(isEdit: false),
            icon: const Icon(Icons.add_circle_outline, size: 20, color: Color(0xFF888888)),
            padding: EdgeInsets.zero, constraints: const BoxConstraints(), tooltip: 'Neuer Trip'),
          const SizedBox(width: 8),
          IconButton(onPressed: _duplicateTrip,
            icon: const Icon(Icons.copy_outlined, size: 18, color: Color(0xFF888888)),
            padding: EdgeInsets.zero, constraints: const BoxConstraints(), tooltip: 'Trip kopieren'),
          const SizedBox(width: 8),
          IconButton(onPressed: () => _showTripDialog(isEdit: true),
            icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF888888)),
            padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ]),
        const SizedBox(height: 8),
        if (_allTrips.length > 1) _buildTripDropdown()
        else Text(_tripName ?? 'Mein Trip',
          style: GoogleFonts.nunito(fontSize: 20, fontWeight: FontWeight.w700, color: const Color(0xFF2C2416))),
        if (_totalDaysUsed > 0)
          Text('$_totalDaysUsed Tage geplant', style: GoogleFonts.nunito(fontSize: 13, color: const Color(0xFF888888))),
        const SizedBox(height: 12),
        if (_allRouteVersions.length > 1 &&
    _allRouteVersions.any((v) => v['id'] == _routeVersionId))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Text('Version:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _routeVersionId,
                  isDense: true,
                  underline: const SizedBox(),
                  style: const TextStyle(color: Color(0xFF2C2416), fontSize: 13),
                  items: _allRouteVersions.map((v) {
                    final no = v['version_no'];
                    final by = v['generated_by'] == 'ai' ? '🤖 KI' : '👤 Manuell';
                    return DropdownMenuItem<String>(
                      value: v['id'] as String,
                      child: Text('v$no — $by', style: const TextStyle(fontSize: 13)),
                    );
                  }).toList(),
                  onChanged: (newId) async {
                    if (newId == null || newId == _routeVersionId) return;
                    setState(() => _routeVersionId = newId);
                    await _loadStops();
                  },
                ),
              ],
            ),
          ),
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
  onPressed: () async {
    if (!await _canRerun()) return;
    if (!mounted) return;
    setState(() => _rerunLoading = true);
    try {
      final response = await SupaFlow.client.functions.invoke(
        'generate-freebie',
        body: {'trip_id': _tripId},
      );
      if (response.data != null) {
        await _importAiRoute(jsonEncode(response.data));
        if (mounted) {
          try { ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Route neu berechnet'))); } catch (_) {}
        }
      } else {
        if (mounted) {
          try { ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Fehler: Keine Antwort von der KI'))); } catch (_) {}
        }
      }
    } catch (e) {
      if (mounted) {
        try { ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e'))); } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _rerunLoading = false);
    }
  },
  icon: const Icon(Icons.refresh, size: 16),
  label: _rerunLoading
    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
    : Text('Route neu berechnen', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
  style: ElevatedButton.styleFrom(
    backgroundColor: const Color(0xFF3A9E8F),
    foregroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    padding: const EdgeInsets.symmetric(vertical: 12)),
)),
const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: _showFreebieSheet,
          icon: const Icon(Icons.auto_awesome_outlined, size: 16),
          label: Text('Routendetails', style: GoogleFonts.nunito(fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF3A9E8F),
            side: const BorderSide(color: Color(0xFF3A9E8F)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(vertical: 11)),
        )),
      ]),
    );
  }

  Widget _buildTripDropdown() {
    final unique = <String, Map<String, dynamic>>{};
    for (final t in _allTrips) unique[t['id'] as String] = t;
    final list = unique.values.toList();
    final safe = list.any((t) => t['id'] == _tripId) ? _tripId : list.first['id'] as String;
    return DropdownButton<String>(
      value: safe, isExpanded: true, underline: const SizedBox(),
      style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w600, color: const Color(0xFF2C2416)),
      items: list.map((t) => DropdownMenuItem<String>(value: t['id'] as String, child: Text(t['name'] ?? ''))).toList(),
      onChanged: (id) { if (id != null && id != _tripId) _switchTrip(id); },
    );
  }

  Widget _buildGlaettungBanner() {
    if (!_glaettungPending) return const SizedBox.shrink();
    return Container(
      color: const Color(0xFF4A90D9).withOpacity(0.1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        const Icon(Icons.auto_fix_high, size: 14, color: Color(0xFF4A90D9)),
        const SizedBox(width: 6),
        Expanded(child: Text('Glaettung vorgeschaut', style: GoogleFonts.nunito(fontSize: 12, color: const Color(0xFF4A90D9), fontWeight: FontWeight.w600))),
        GestureDetector(onTap: _undoGlaettung,
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFF4A90D9)), borderRadius: BorderRadius.circular(6)),
            child: Text('Rueckgaengig', style: GoogleFonts.nunito(fontSize: 11, color: const Color(0xFF4A90D9), fontWeight: FontWeight.w600)))),
        const SizedBox(width: 6),
        GestureDetector(onTap: _saveGlaettung,
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFF4A90D9), borderRadius: BorderRadius.circular(6)),
            child: Text('Speichern', style: GoogleFonts.nunito(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)))),
      ]),
    );
  }

  // ── Split / Merge ─────────────────────────────────────────────
  Future<void> _splitContainer(Map<String, dynamic> stop, List<Map<String, dynamic>> allChildren) async {
    final normal = allChildren.where((c) => c['stop_type'] != 'prefer' && c['stop_type'] != 'never').toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    final stopIndex = normal.indexWhere((c) => c['id'] == stop['id']);
    if (stopIndex < 0) return;
    final toMove = normal.sublist(stopIndex);
    if (toMove.isEmpty) return;
    final parent = _stops.firstWhere((s) => s['id'] == stop['parent_stop_id'], orElse: () => {});
    if (parent.isEmpty) return;
    final topLevel = _stops.where((s) => s['parent_stop_id'] == null).toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    final pIdx = topLevel.indexWhere((s) => s['id'] == parent['id']);
    try {
      for (int i = pIdx + 1; i < topLevel.length; i++)
        await SupaFlow.client.from('stops').update({'sequence_index': i + 2}).eq('id', topLevel[i]['id']);
      final newC = await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
        'trip_id': _tripId, 'route_version_id': _routeVersionId,
        'sequence_index': (parent['sequence_index'] as int) + 1,
        'stop_type': 'container', 'place_level': parent['place_level'], 'place_name': parent['place_name'],
        'place_id_ne': parent['place_id_ne'], 'place_source': 'natural_earth',
        'lat': parent['lat'], 'lng': parent['lng'], 'is_container': true, 'source': 'auto', 'is_ai_generated': false}).select().single();
      for (int i = 0; i < toMove.length; i++)
        await SupaFlow.client.from('stops').update({'parent_stop_id': newC['id'], 'sequence_index': i + 1}).eq('id', toMove[i]['id']);
      await _loadStops();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Container gesplittet')));
    } catch (e) { debugPrint('Split error: $e'); }
  }

  Future<void> _mergeContainers(Map<String, dynamic> container) async {
    final topLevel = _stops.where((s) => s['parent_stop_id'] == null).toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    final ci = topLevel.indexWhere((s) => s['id'] == container['id']);
    if (ci <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kein vorheriger Container'))); return; }
    final prev = topLevel[ci - 1];
    if (prev['place_id_ne'] != container['place_id_ne']) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Merge nur mit gleichem Land/Region'))); return; }
    try {
      final curChildren  = _stops.where((s) => s['parent_stop_id'] == container['id']).toList();
      final prevChildren = _stops.where((s) => s['parent_stop_id'] == prev['id']).toList();
      final maxIdx = prevChildren.isEmpty ? 0 : prevChildren.map((c) => (c['sequence_index'] as int?) ?? 0).reduce((a, b) => a > b ? a : b);
      for (int i = 0; i < curChildren.length; i++)
        await SupaFlow.client.from('stops').update({'parent_stop_id': prev['id'], 'sequence_index': maxIdx + i + 1}).eq('id', curChildren[i]['id']);
      await SupaFlow.client.from('stops').delete().eq('id', container['id']);
      for (int i = ci; i < topLevel.length; i++)
        await SupaFlow.client.from('stops').update({'sequence_index': i}).eq('id', topLevel[i]['id']);
      await _loadStops();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Mit ${prev['place_name']} gemergt')));
    } catch (e) { debugPrint('Merge error: $e'); }
  }

  Future<void> _addTravelDay(Map<String, dynamic> container) async {
    if (_tripId == null) return;
    final children = _stops.where((s) => s['parent_stop_id'] == container['id']).toList();
    final nextIdx = children.isEmpty ? 1
      : children.map((c) => (c['sequence_index'] as int?) ?? 0).reduce((a, b) => a > b ? a : b) + 1;
    await SupaFlow.client.from('stops').insert({
      'owner_id': SupaFlow.client.auth.currentUser?.id,
      'trip_id': _tripId,
      'route_version_id': _routeVersionId,
      'sequence_index': nextIdx,
      'stop_type': 'place',
      'stop_role': 'transit',
      'place_level': 'city',
      'place_name': 'Reisetag',
      'lat': container['lat'],
      'lng': container['lng'],
      'planned_days': 1,
      'is_container': false,
      'source': 'user',
      'is_ai_generated': false,
      'parent_stop_id': container['id'],
      'use_trip_params': true,
    });
    await _loadStops();
  }

  Future<void> _addStopFromSearch(Map<String, dynamic> result, int insertAfterIndex,
      {String action = 'container', bool isTransit = false, bool addNearbyCity = false}) async {
    if (_tripId == null) return;
    final lat = result['lat'] as double; final lng = result['lng'] as double;
    final name = result['text'] as String;
    final countryCode = (result['country_code'] as String? ?? '').toUpperCase();
    final designation = result['place_designation'] as String? ?? '';
    const iso2to3 = {'DE':'DEU','FR':'FRA','AT':'AUT','CH':'CHE','IT':'ITA','ES':'ESP',
      'NL':'NLD','BE':'BEL','PL':'POL','CZ':'CZE','HU':'HUN','SK':'SVK','HR':'HRV',
      'DK':'DNK','SE':'SWE','NO':'NOR','GB':'GBR','IE':'IRL','PT':'PRT','GR':'GRC','RO':'ROU','BG':'BGR'};
    final iso3 = iso2to3[countryCode] ?? (countryCode.length == 3 ? countryCode : null);
    final topLevel = _stops.where((s) => s['parent_stop_id'] == null).toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    final isCountry = designation == 'country';
    final isCity    = ['city','town','municipality','village','airport'].contains(designation);
    final cBefore   = (insertAfterIndex >= 0 && insertAfterIndex < topLevel.length) ? topLevel[insertAfterIndex] : null;
    final cAfter    = (insertAfterIndex + 1 < topLevel.length) ? topLevel[insertAfterIndex + 1] : null;
    final fitsBefore = cBefore != null && cBefore['place_id_ne'] == iso3 && isCity;
    final fitsAfter  = cAfter  != null && cAfter['place_id_ne']  == iso3 && isCity;
    try {
      if (!fitsBefore && !fitsAfter)
        for (int i = insertAfterIndex + 1; i < topLevel.length; i++)
          await SupaFlow.client.from('stops').update({'sequence_index': i + 2}).eq('id', topLevel[i]['id']);
      if (isTransit) {
        String? parentId = fitsBefore ? cBefore!['id'] as String : fitsAfter ? cAfter!['id'] as String : null;
        if (parentId == null && iso3 != null) {
          final c2 = await SupaFlow.client.from('place_content').select().eq('place_id', iso3).maybeSingle();
          final newC = await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
            'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': insertAfterIndex + 2,
            'stop_type': 'container', 'place_level': 'country', 'place_name': c2?['name_de'] ?? iso3,
            'place_id_ne': iso3, 'lat': lat, 'lng': lng, 'is_container': true, 'source': 'auto',
            'is_ai_generated': false, 'use_trip_params': true}).select().single();
          parentId = newC['id'] as String;
          await _highlightFeature?.call(iso3, 'eu-countries-fill', 'selected');
        }
        final existCh = parentId != null ? _stops.where((s) => s['parent_stop_id'] == parentId).toList() : <Map<String, dynamic>>[];
        final nextIdx = existCh.isEmpty ? 1 : existCh.map((c) => (c['sequence_index'] as int?) ?? 0).reduce((a, b) => a > b ? a : b) + 1;
        await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
          'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': nextIdx,
          'stop_type': 'container', 'stop_role': 'transit', 'place_level': 'city', 'place_name': name,
          'lat': lat, 'lng': lng, 'is_container': false, 'source': 'user', 'is_ai_generated': false,
          'planned_days': 0, 'parent_stop_id': parentId, 'use_trip_params': true});
        if (addNearbyCity && parentId != null) {
          final cityName = (result['city'] as String?) ?? '';
          if (cityName.isNotEmpty)
            await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
              'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': nextIdx + 1,
              'stop_type': 'container', 'place_level': 'city', 'place_name': cityName,
              'lat': lat, 'lng': lng, 'is_container': false, 'source': 'user',
              'is_ai_generated': false, 'parent_stop_id': parentId, 'use_trip_params': true});
        }
      } else if (fitsBefore) {
        final ch = _stops.where((s) => s['parent_stop_id'] == cBefore!['id']).toList();
        await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
          'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': ch.length + 1,
          'stop_type': action, 'place_level': 'city', 'place_name': name, 'lat': lat, 'lng': lng,
          'is_container': false, 'source': 'user', 'is_ai_generated': false,
          'parent_stop_id': cBefore!['id'], 'use_trip_params': true});
      } else if (fitsAfter) {
        final ch = _stops.where((s) => s['parent_stop_id'] == cAfter!['id']).toList();
        await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
          'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': ch.length + 1,
          'stop_type': action, 'place_level': 'city', 'place_name': name, 'lat': lat, 'lng': lng,
          'is_container': false, 'source': 'user', 'is_ai_generated': false,
          'parent_stop_id': cAfter!['id'], 'use_trip_params': true});
      } else {
        final c2 = iso3 != null ? await SupaFlow.client.from('place_content').select().eq('place_id', iso3).maybeSingle() : null;
        String cName   = isCountry ? (c2?['name_de'] ?? name) : (c2?['name_de'] ?? countryCode);
        String? cPlId  = iso3; String cLevel = 'country';
        if (iso3 == null) { cName = name; cPlId = null; cLevel = 'city'; }
        final newC = await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
          'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': insertAfterIndex + 2,
          'stop_type': action, 'place_level': cLevel, 'place_name': cName, 'place_id_ne': cPlId,
          'lat': lat, 'lng': lng, 'is_container': true, 'source': 'user', 'is_ai_generated': false, 'use_trip_params': true}).select().single();
        if (cPlId != null) {
          final lId = cLevel == 'country' ? 'eu-countries-fill' : 'regions-fill';
          final ms  = action == 'prefer' ? 'prefer' : action == 'never' ? 'never' : 'selected';
          await _highlightFeature?.call(cPlId, lId, ms);
        }
        if (isCity && iso3 != null)
          await SupaFlow.client.from('stops').insert({'owner_id': SupaFlow.client.auth.currentUser?.id,
            'trip_id': _tripId, 'route_version_id': _routeVersionId, 'sequence_index': 1,
            'stop_type': action, 'place_level': 'city', 'place_name': name, 'lat': lat, 'lng': lng,
            'is_container': false, 'source': 'user', 'is_ai_generated': false,
            'parent_stop_id': newC['id'], 'use_trip_params': true});
      }
      await _loadStops();
      await _flyTo?.call(lat, lng, 8.0);
    } catch (e) { debugPrint('_addStopFromSearch error: $e'); }
  }

  Future<void> _reorderContainers(int oldIndex, int newIndex) async {
    final tl = _stops.where((s) => s['parent_stop_id'] == null).toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    if (newIndex > oldIndex) newIndex--;
    final item = tl.removeAt(oldIndex); tl.insert(newIndex, item);
    for (int i = 0; i < tl.length; i++)
      await SupaFlow.client.from('stops').update({'sequence_index': i + 1}).eq('id', tl[i]['id']);
    await _loadStops();
    await _recalcAllDatesFromStart();
    await _loadStops(runChecks: false);  
  }

  Future<void> _reorderChildren(String parentId, int oldIndex, int newIndex) async {
    final ch = _stops.where((s) => s['parent_stop_id'] == parentId && s['stop_type'] != 'prefer' && s['stop_type'] != 'never').toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    if (newIndex > oldIndex) newIndex--;
    final item = ch.removeAt(oldIndex); ch.insert(newIndex, item);
    for (int i = 0; i < ch.length; i++)
      await SupaFlow.client.from('stops').update({'sequence_index': i + 1}).eq('id', ch[i]['id']);
    await _loadStops();
    await _recalcAllDatesFromStart();
    await _loadStops(runChecks: false);
  }

  // ── Stop List ─────────────────────────────────────────────────
  Widget _buildStopList({ScrollController? scrollController}) {
    final topLevel = _stops.where((s) => s['parent_stop_id'] == null).toList()
      ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
    if (topLevel.isEmpty) {
      return Column(children: [
        _buildSearchField(-1),
        Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.explore_outlined, size: 48, color: Color(0xFFCCC5B5)), const SizedBox(height: 12),
          Text('Noch keine Stops', style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w600, color: const Color(0xFF888888))),
          const SizedBox(height: 4),
          Text('Klick auf ein Land oder nutze die Suche',
            style: GoogleFonts.nunito(fontSize: 13, color: const Color(0xFFAAAAAA)), textAlign: TextAlign.center),
        ]))),
      ]);
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
      itemCount: topLevel.length * 2 + 1,
      itemBuilder: (ctx, i) {
        if (i.isEven) return _buildSearchField((i ~/ 2) - 1);
        final ci   = i ~/ 2;
        final stop = topLevel[ci];
        final allCh = _stops.where((s) => s['parent_stop_id'] == stop['id']).toList()
          ..sort((a, b) => ((a['sequence_index'] as int?) ?? 0).compareTo((b['sequence_index'] as int?) ?? 0));
        return KeyedSubtree(key: ValueKey(stop['id']),
          child: _buildContainerCard(stop, allCh, ci + 1, listIndex: ci));
      },
    );
  }

  Widget _buildContainerCard(Map<String, dynamic> stop, List<Map<String, dynamic>> allChildren, int index, {int listIndex = 0}) {
    final plannedDays = stop['planned_days'] as int?;
    final childSum    = (stop['child_days_sum'] as int?) ?? 0;
    final isExpanded  = _expandedContainers[stop['id']] ?? true;
    final lat = stop['lat'] as double?; final lng = stop['lng'] as double?;
    final cType   = stop['stop_type'] as String? ?? 'container';
    final isPrefer  = cType == 'prefer'; final isNever = cType == 'never'; final isSpecial = isPrefer || isNever;
    final stopId    = stop['id'] as String;
    final hasWarning = _warnings.any((w) => w['stopId'] == stopId);
    final timeOverflow = plannedDays != null && childSum > plannedDays;
    final progressVal  = (plannedDays != null && plannedDays > 0) ? (childSum / plannedDays).clamp(0.0, 1.0) : 0.0;

    Color accent; IconData cIcon; String statusLabel; Color bg;
    if (isPrefer)     { accent = const Color(0xFF3A9E8F); cIcon = Icons.star_outline;          statusLabel = 'Bevorzugt'; bg = const Color(0xFFEFF8F6); }
    else if (isNever) { accent = const Color(0xFFE85D3A); cIcon = Icons.remove_circle_outline; statusLabel = 'Ausgeschlossen'; bg = const Color(0xFFFDF2EF); }
    else              { accent = const Color(0xFF888888); cIcon = Icons.location_on_outlined;  statusLabel = '';          bg = Colors.white; }

    final normalCh    = allChildren.where((c) => c['stop_type'] != 'prefer' && c['stop_type'] != 'never').toList();
    final prefNeverCh = allChildren.where((c) => c['stop_type'] == 'prefer' || c['stop_type'] == 'never').toList();

    return Container(
      key: ValueKey(stopId), margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12),
        border: isSpecial ? Border(left: BorderSide(color: accent, width: 4)) : null,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))]),
      child: Column(children: [
        Row(children: [
          Padding(padding: const EdgeInsets.only(left: 8), child: Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(onTap: listIndex > 0 ? () => _reorderContainers(listIndex, listIndex - 1) : null,
              child: Icon(Icons.arrow_drop_up, size: 20, color: listIndex > 0 ? const Color(0xFF888888) : const Color(0xFFDDDDDD))),
            GestureDetector(onTap: listIndex < _stops.where((s) => s['parent_stop_id'] == null).length - 1 ? () => _reorderContainers(listIndex, listIndex + 1) : null,
              child: Icon(Icons.arrow_drop_down, size: 20, color: listIndex < _stops.where((s) => s['parent_stop_id'] == null).length - 1 ? const Color(0xFF888888) : const Color(0xFFDDDDDD))),
          ])),
          Expanded(child: InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () { setState(() => _expandedContainers[stopId] = !isExpanded); if (lat != null && lng != null) _flyTo?.call(lat, lng, 5.0); },
            child: Padding(padding: const EdgeInsets.fromLTRB(8, 12, 12, 10), child: Row(children: [
              Container(width: 24, height: 24,
                decoration: BoxDecoration(color: isSpecial ? accent.withOpacity(0.12) : const Color(0xFFF5F0E8), borderRadius: BorderRadius.circular(6)),
                child: Center(child: isSpecial ? Icon(cIcon, size: 14, color: accent)
                  : Text('$index', style: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w700, color: const Color(0xFF888888))))),
              const SizedBox(width: 10),
              Expanded(child: Text(stop['place_name'] ?? '', style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w700, color: const Color(0xFF2C2416)))),
              if (hasWarning) ...[_buildWarningBadge(stopId), const SizedBox(width: 6)],
              if (!isSpecial) ...[
                GestureDetector(onTap: () => _showStopParamsDialog(stop),
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: timeOverflow ? const Color(0xFFFFEBEB) : const Color(0xFFF5F0E8), borderRadius: BorderRadius.circular(8)),
                    child: Text(plannedDays != null ? '$childSum / $plannedDays d' : childSum > 0 ? '$childSum d' : '- d',
                      style: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w700,
                        color: timeOverflow ? const Color(0xFFE85D3A) : const Color(0xFF2C2416))))),
                const SizedBox(width: 6),
                if (plannedDays != null)
                  SizedBox(width: 40, child: ClipRRect(borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: progressVal, backgroundColor: const Color(0xFFEEEEEE),
                      valueColor: AlwaysStoppedAnimation<Color>(timeOverflow ? const Color(0xFFE85D3A) : const Color(0xFF3A9E8F)), minHeight: 6))),
                const SizedBox(width: 6),
              ] else ...[
                Text(statusLabel, style: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w600, color: accent)),
                const SizedBox(width: 8),
              ],
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _showStopParamsDialog(stop),
                child: const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.tune, size: 16, color: Color(0xFFCCCCCC)))),
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: () async {
                _setMapLocked?.call(true);
                final confirm = await showDialog<bool>(context: context, builder: (dCtx) => AlertDialog(
                  title: const Text('Container loeschen'),
                  content: Text('${stop['place_name']} und alle Stops darin loeschen?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Abbrechen')),
                    TextButton(onPressed: () => Navigator.pop(dCtx, true),
                      style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('Loeschen')),
                  ],
                ));
                if (confirm != true) { await Future.delayed(const Duration(milliseconds: 500)); _setMapLocked?.call(false); return; }
                for (final ch in allChildren) await SupaFlow.client.from('stops').delete().eq('id', ch['id']);
                await SupaFlow.client.from('stops').delete().eq('id', stopId);
                await _highlightFeature?.call(stop['place_id_ne'] ?? '', stop['place_level'] == 'country' ? 'eu-countries-fill' : 'regions-fill', 'none');
                await _loadStops();
                await Future.delayed(const Duration(milliseconds: 500)); _setMapLocked?.call(false);
              }, child: const Icon(Icons.delete_outline, size: 16, color: Color(0xFFCCCCCC))),
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _mergeContainers(stop),
                child: const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.merge, size: 16, color: Color(0xFFCCCCCC)))),
              const SizedBox(width: 4),
              Icon(isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 20, color: const Color(0xFF888888)),
            ])),
          )),
        ]),
        if (isExpanded) ...[
          if (normalCh.isNotEmpty)
            ReorderableListView(
              shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false, padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
              onReorder: (o, n) => _reorderChildren(stopId, o, n),
              proxyDecorator: (child, i, a) => Material(elevation: 4, borderRadius: BorderRadius.circular(10), child: child),
              children: normalCh.map<Widget>((c) => _buildChildCard(c, allChildren, stopId, key: ValueKey(c['id']))).toList()),
          if (prefNeverCh.isNotEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Column(children: prefNeverCh.map<Widget>((c) => _buildChildCard(c, allChildren, stopId, key: ValueKey('pn_${c['id']}'))).toList())),
              if (!isSpecial)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: GestureDetector(
                onTap: () => _addTravelDay(stop),
                child: Row(children: [
                  const Icon(Icons.directions, size: 13, color: Color(0xFF7B8794)),
                  const SizedBox(width: 6),
                  Text('Reisetag hinzufügen',
                    style: GoogleFonts.nunito(fontSize: 12, color: const Color(0xFF7B8794), fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          if (plannedDays != null && plannedDays > childSum)
            Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 10), child: Row(children: [
              const Icon(Icons.auto_awesome, size: 12, color: Color(0xFF3A9E8F)), const SizedBox(width: 6),
              Text('${plannedDays - childSum} Tage offen fuer KI',
                style: GoogleFonts.nunito(fontSize: 12, color: const Color(0xFF3A9E8F), fontWeight: FontWeight.w600)),
            ])),
        ],
      ]),
    );
  }

  Widget _buildChildCard(Map<String, dynamic> stop, List<Map<String, dynamic>> allChildren, String parentId, {Key? key}) {
    final stopType    = stop['stop_type'] as String? ?? 'place';
    final stopRole    = stop['stop_role'] as String?;
    final plannedDays = stop['planned_days'] as int?;
    final lat = stop['lat'] as double?; final lng = stop['lng'] as double?;
    final isPreferNever = stopType == 'prefer' || stopType == 'never';
    final isTransit     = stopRole == 'transit';
    final stopId        = stop['id'] as String;
    final hasWarning    = _warnings.any((w) => w['stopId'] == stopId);

    Color accent; IconData iconData; String statusLabel = '';
    if (isTransit) { accent = const Color(0xFF7B8794); iconData = (plannedDays ?? 0) > 0 ? Icons.directions : Icons.flight; statusLabel = (plannedDays ?? 0) > 0 ? '' : 'Transit'; }
    else if (stopType == 'prefer') { accent = const Color(0xFF3A9E8F); iconData = Icons.star_outline; statusLabel = 'Bevorzugt'; }
    else if (stopType == 'never')  { accent = const Color(0xFFE85D3A); iconData = Icons.remove_circle_outline; statusLabel = 'Ausgeschlossen'; }
    else { accent = const Color(0xFF4A90D9); iconData = Icons.location_on_outlined; }

    return Container(
      key: key, margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFEEEEEE))),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        leading: Row(mainAxisSize: MainAxisSize.min, children: [
          if (!isPreferNever)
            (stop['is_time_fixed'] == true)
              ? const MouseRegion(cursor: SystemMouseCursors.basic,
                  child: Icon(Icons.lock, size: 16, color: Color(0xFFE8A838)))
              : ReorderableDragStartListener(
                  index: allChildren.where((c) => c['stop_type'] != 'prefer' && c['stop_type'] != 'never').toList().indexWhere((c) => c['id'] == stopId),
                  child: const MouseRegion(cursor: SystemMouseCursors.grab, child: Icon(Icons.drag_indicator, size: 16, color: Color(0xFFCCCCCC)))),
          const SizedBox(width: 4),
          Container(width: 28, height: 28,
            decoration: BoxDecoration(color: accent.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(iconData, size: 14, color: accent)),
        ]),
        title: Text(stop['place_name'] ?? '', style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF2C2416))),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (hasWarning) ...[_buildWarningBadge(stopId), const SizedBox(width: 4)],
          if (stop['is_time_fixed'] == true) ...[
            const Icon(Icons.lock, size: 13, color: Color(0xFFE8A838)),
            const SizedBox(width: 4),
          ],
          if (statusLabel.isNotEmpty)
            Text(statusLabel, style: GoogleFonts.nunito(fontSize: 11, color: accent, fontWeight: FontWeight.w600))
          else if (plannedDays != null)
            GestureDetector(onTap: () async {
              final ctrl = TextEditingController(text: '$plannedDays');
              _setMapLocked?.call(true);
              final val = await showDialog<String>(context: context, builder: (dCtx) => AlertDialog(
                title: Text(stop['place_name'] ?? '', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
                content: TextField(controller: ctrl, autofocus: true, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Tage', border: OutlineInputBorder()),
                  onSubmitted: (v) => Navigator.pop(dCtx, v)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dCtx, null), child: const Text('Abbrechen')),
                  TextButton(onPressed: () => Navigator.pop(dCtx, ctrl.text),
                    child: const Text('OK', style: TextStyle(color: Color(0xFFE8A838)))),
                ],
              ));
              await Future.delayed(const Duration(milliseconds: 300)); _setMapLocked?.call(false);
              if (val == null) return;
              final days = int.tryParse(val); if (days == null) return;
              await SupaFlow.client.from('stops').update({'planned_days': days}).eq('id', stopId);
              await _loadStops();
            }, child: Text('$plannedDays d', style: GoogleFonts.nunito(fontSize: 12, color: const Color(0xFF888888), decoration: TextDecoration.underline))),
          if (!isPreferNever && !isTransit) ...[
            const SizedBox(width: 4),
            GestureDetector(onTap: () => _splitContainer(stop, allChildren),
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFFF5F0E8), borderRadius: BorderRadius.circular(6)),
                child: const Icon(Icons.call_split, size: 12, color: Color(0xFF888888)))),
          ],
          const SizedBox(width: 4),
          IconButton(onPressed: () => _showStopParamsDialog(stop),
            icon: const Icon(Icons.tune, size: 16, color: Color(0xFFCCCCCC)), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          IconButton(
            onPressed: () async {
              _setMapLocked?.call(true);
              final confirm = await showDialog<bool>(context: context, builder: (dCtx) => AlertDialog(
                title: const Text('Stop loeschen'),
                content: Text('${stop['place_name']} wirklich loeschen?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Abbrechen')),
                  TextButton(onPressed: () => Navigator.pop(dCtx, true),
                    style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('Loeschen')),
                ],
              ));
              _setMapLocked?.call(false);
              if (confirm != true) return;
              await SupaFlow.client.from('stops').delete().eq('id', stopId);
              await _loadStops();
            },
            icon: const Icon(Icons.delete_outline, size: 16, color: Color(0xFFCCCCCC)), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ]),
        onTap: () { if (lat != null && lng != null) _flyTo?.call(lat, lng, 9.0); },
      ),
    );
  }

  Widget _buildSearchField(int insertAfterIndex) {
    final searchCtrl = TextEditingController();
    final results    = ValueNotifier<List<Map<String, dynamic>>>([]);
    final isExpanded = ValueNotifier<bool>(false);
    return ValueListenableBuilder(
      valueListenable: isExpanded,
      builder: (context, expanded, _) => Column(children: [
        if (!expanded)
          GestureDetector(onTap: () => isExpanded.value = true,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: const Color(0xFFF5F0E8), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE0D8C8))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.add, size: 14, color: Color(0xFF888888)), const SizedBox(width: 4),
                Text('Stop hinzufuegen', style: GoogleFonts.nunito(fontSize: 12, color: const Color(0xFF888888))),
              ])))
        else Column(children: [
          TextField(
            controller: searchCtrl, autofocus: true,
            onChanged: (val) async {
              if (val.isEmpty) { results.value = []; return; }
              try {
                final rpc = await http.post(
                  Uri.parse('https://bangedotpvtglphlmbng.supabase.co/rest/v1/rpc/search_airports'),
                  headers: {'apikey': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJhbmdlZG90cHZ0Z2xwaGxtYm5nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg0MjA0NTcsImV4cCI6MjA5Mzk5NjQ1N30.bF25BZmm2a14SSMs6D2x0jgLx2VQi-IlS430k0w90Mk',
                    'Authorization': 'Bearer ${SupaFlow.client.auth.currentSession?.accessToken}', 'Content-Type': 'application/json'},
                  body: jsonEncode({'query': val}));
                final airports = (jsonDecode(rpc.body) as List).map<Map<String, dynamic>>((a) => {
                  'name': '${a['iata']} - ${a['city']}', 'city': a['city'] ?? '', 'text': a['name_de'] ?? '',
                  'lat': a['lat'], 'lng': a['lng'], 'country_code': a['country_code'] ?? '',
                  'place_designation': 'airport', 'categories': ['airport'], 'kind': 'aerodrome'}).toList();
                final uri = Uri.parse('https://api.maptiler.com/geocoding/${Uri.encodeComponent(val)}.json?key=bq7edtBllgSIwDJY9mGU&limit=10&language=de');
                final resp = await http.get(uri);
                List<Map<String, dynamic>> places = [];
                if (resp.statusCode == 200) {
                  final json = jsonDecode(resp.body);
                  final features = (json['features'] as List? ?? []).where((f) {
                    final p = f['properties'] as Map? ?? {};
                    final des = p['place_designation'] as String? ?? ''; final kind = p['kind'] as String? ?? '';
                    final cats = (p['categories'] as List?)?.cast<String>() ?? [];
                    return kind == 'admin_area' || ['city','town','state','country','municipality','island','archipelago'].contains(des) ||
                        cats.contains('lake') || cats.contains('island') || cats.contains('sea') || cats.contains('bay');
                  }).toList();
                  places = features.map<Map<String, dynamic>>((f) {
                    final p = f['properties'] as Map? ?? {};
                    return {'name': f['place_name'] ?? f['text'] ?? '', 'text': f['text'] ?? '',
                      'lat': (f['center'] as List)[1], 'lng': (f['center'] as List)[0],
                      'place_type': (f['place_type'] as List?)?.first ?? 'place',
                      'country_code': p['country_code'] ?? '', 'place_designation': p['place_designation'] ?? '',
                      'categories': (p['categories'] as List?)?.cast<String>() ?? [], 'kind': p['kind'] ?? ''};
                  }).toList();
                }
                results.value = [...airports, ...places];
              } catch (e) { debugPrint('Search error: $e'); }
            },
            decoration: InputDecoration(
              hintText: 'Ort suchen…', hintStyle: GoogleFonts.nunito(fontSize: 13, color: const Color(0xFFAAAAAA)),
              prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF888888)),
              suffixIcon: IconButton(icon: const Icon(Icons.close, size: 16, color: Color(0xFF888888)),
                onPressed: () { isExpanded.value = false; results.value = []; searchCtrl.clear(); }),
              filled: true, fillColor: const Color(0xFFF5F0E8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 10))),
          ValueListenableBuilder(
            valueListenable: results,
            builder: (context, list, _) {
              if (list.isEmpty) return const SizedBox();
              return Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 2))]),
                child: Column(children: list.map((result) {
                  final cats = (result['categories'] as List?)?.cast<String>() ?? [];
                  final isAir = result['place_designation'] == 'airport' || cats.contains('airport') || result['kind'] == 'aerodrome';
                  return ListTile(dense: true,
                    leading: Icon(isAir ? Icons.flight : Icons.location_on_outlined, size: 16, color: const Color(0xFF888888)),
                    title: Text(result['text'], style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600, color: const Color(0xFF2C2416)), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(result['name'], style: GoogleFonts.nunito(fontSize: 11, color: const Color(0xFF888888)), maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () async {
                      isExpanded.value = false; results.value = []; searchCtrl.clear();
                      await _handleSearchResult(result, insertAfterIndex);
                    });
                }).toList()));
            }),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width > 600;
    return Scaffold(key: scaffoldKey, body: isWide ? _buildWebLayout() : _buildMobileLayout());
  }

  Widget _buildWebLayout() {
    return Row(children: [
      Container(width: 450, color: const Color(0xFFF5F0E8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 40),
          _buildSidebarHeader(),
          _buildGlaettungBanner(),
          const Divider(color: Color(0xFFE0D8C8), height: 1),
          Expanded(child: _buildStopList()),
        ])),
      Expanded(child: custom_widgets.MapWebView(
        width: double.infinity, height: double.infinity,
        mapUrl: 'https://api.maptiler.com/maps/aquarelle-v4/style.json?key=bq7edtBllgSIwDJY9mGU',
        onMessageReceived: _handleMapMessage,
        onControllerReady: (highlight, setLocked, flyTo, updateAiStops, updateRoute, updateContainerPins, resetTapping, updateWarningMarkers) {
          _highlightFeature = highlight; _setMapLocked = setLocked; _flyTo = flyTo;
          _updateAiStops = updateAiStops; _updateRoute = updateRoute;
          _updateContainerPins = updateContainerPins; _resetTapping = resetTapping;
          _updateWarningMarkers = updateWarningMarkers;
        },
      )),
    ]);
  }

  Widget _buildMobileLayout() {
    return Stack(children: [
      custom_widgets.MapWebView(
        width: double.infinity, height: double.infinity,
        mapUrl: 'https://api.maptiler.com/maps/aquarelle-v4/style.json?key=bq7edtBllgSIwDJY9mGU',
        onMessageReceived: _handleMapMessage,
        onControllerReady: (highlight, setLocked, flyTo, updateAiStops, updateRoute, updateContainerPins, resetTapping, updateWarningMarkers) {
          _highlightFeature = highlight; _setMapLocked = setLocked; _flyTo = flyTo;
          _updateAiStops = updateAiStops; _updateRoute = updateRoute;
          _updateContainerPins = updateContainerPins; _resetTapping = resetTapping;
          _updateWarningMarkers = updateWarningMarkers;
        },
      ),
      DraggableScrollableSheet(
        controller: _sheetController, initialChildSize: 0.35, minChildSize: 0.08, maxChildSize: 0.85,
        builder: (ctx, sc) => Container(
          decoration: const BoxDecoration(color: Color(0xFFF5F0E8),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -2))]),
          child: Column(children: [
            Container(margin: const EdgeInsets.only(top: 10, bottom: 4), width: 36, height: 4,
              decoration: BoxDecoration(color: const Color(0xFFCCC5B5), borderRadius: BorderRadius.circular(2))),
            _buildSidebarHeader(),
            _buildGlaettungBanner(),
            const Divider(color: Color(0xFFE0D8C8), height: 1),
            Expanded(child: _buildStopList(scrollController: sc)),
          ]),
        ),
      ),
    ]);
  }
}
