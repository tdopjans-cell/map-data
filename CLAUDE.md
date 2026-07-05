# Way2GoX — Claude Code Kontext

## Projekt-Übersicht
Intelligenter Reiseroutenplaner. Hauptprodukt: detailliertes Reisebooklet mit täglichen Aktivitäten.
Zielgruppe: Reisende die mehrere Orte besuchen wollen.

## Tech Stack
- **Frontend:** Flutter (VS Code, Windows)
- **Backend:** Supabase (PostgreSQL + Auth + RPC)
- **Map:** MapLibre GL (`maplibre_gl 0.26.0`) + MapTiler Aquarelle Style
- **Hosting:** Netlify (App) + GitHub Pages (Geo-Daten)
- **Fonts:** Nunito (google_fonts)

## URLs
- App GitHub: https://github.com/tdopjans-cell/way2gox-app (branch: master)
- Netlify: https://leafy-selkie-49eae2.netlify.app
- GitHub Pages (Geo-Daten): https://tdopjans-cell.github.io/map-data/
- Supabase: https://bangedotpvtglphlmbng.supabase.co

## Supabase
**Anon Key:**
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJhbmdlZG90cHZ0Z2xwaGxtYm5nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg0MjA0NTcsImV4cCI6MjA5Mzk5NjQ1N30.bF25BZmm2a14SSMs6D2x0jgLx2VQi-IlS430k0w90Mk

**Tabellen:**
- `trips`: id, owner_id, name, start_date, end_date, total_days, param_group_type, param_diet, param_budget, param_trip_style, param_activity_level, is_active, created_at
- `stops`: id, trip_id, route_version_id, owner_id, sequence_index, stop_type, stop_role, place_level, place_name, place_id_ne, lat, lng, planned_days, start_date, end_date, is_container, source, is_ai_generated, parent_stop_id, use_trip_params, override_param_group_type, override_param_diet, override_param_budget, override_param_trip_style, override_param_activity_level, created_at
- `route_versions`: id, trip_id, version_no, is_active, generated_by, generation_mode, owner_id
- `profiles`: id, subscription_tier, rerun_credits_remaining, preferred_language
- `airports`: id, iata, name_de, city, country_code, lat, lng (~100 europäische Flughäfen)

**SQL Functions:**
- `search_airports(query text)` — RPC, GRANT EXECUTE TO authenticated
- Row Level Security auf airports: DISABLED

## Architektur / Datenmodell
**Planungshierarchie:** Kontinent → Land → Region/Bundesstaat → Stadt
(Städte sind KEINE Container — sie sind Child-Stops)

**Backend:** Flat sequential stop list.
**UI:** Hierarchische Container-Ansicht (Container expandierbar, Children darin)

**stop_type Werte:** `container`, `prefer`, `never`, `transit`
**stop_role Werte:** `transit` (für Flughäfen)
**place_level Werte:** `country`, `region`, `city`, `transit`
**is_container:** true für Länder/Regionen, false für Städte/Transits

## Dateistruktur (relevante Dateien)
```
lib/
  map_screen/
    map_screen_widget.dart   ← Haupt-UI, Sidebar, Stop-Liste
    map_screen_model.dart
  custom_code/
    widgets/
      map_web_view.dart      ← MapLibre Widget, Karten-Interaktion
      index.dart
```

## Farben & Design
- Gold:       #E8A838
- Grün:       #3A9E8F
- Rot:        #E85D3A
- Blau:       #4A90D9
- Hintergrund:#F5F0E8
- Amber (Warning): #F59E0B
- Sidebar Breite Web: 450px
- Border Radius Cards: 12px (Container), 10px (Child)

## Map Pin Styles (map_web_view.dart)
- **Cities:** circleRadius 6.0, weiß fill, 2.5px roter Stroke (#E85D3A)
- **Container pins:** circleRadius 9.0, weiß fill, 3.0px goldener Stroke (#E8A838)
- **AI stops:** circleRadius 6.0, weiß fill, 2.5px blauer Stroke (#4A90D9)
- **Warning markers:** circleRadius 9.0, amber (#F59E0B) fill, 2px weißer Stroke, "!" Symbol

## Konventionen (WICHTIG)
- `_setMapLocked?.call(true/false)` + `_resetTapping?.call()` IMMER um Dialoge wrappen
- Löschen immer mit `onTap` nicht `onLongPress`
- `buildDefaultDragHandles: false` auf allen ReorderableListViews
- ISO2→ISO3 Mapping in `_addStopFromSearch`
- Suche: MapTiler Geocoding + Supabase RPC für Airports
- Alle Änderungen direkt in Supabase (kein lokales State-only)
- `final ctx = context` vor await speichern
- Dart: Keine Non-ASCII Zeichen in Identifiern (kein ä/ö/ü) → ae/oe/ue verwenden
- Kein Block `{ }` mit `final`-Variablen innerhalb von Widget-Listen (Column/Row children)
  → Stattdessen Hilfsmethode extrahieren

## onControllerReady Signatur (8 Parameter)
```dart
void Function(
  Future<void> Function(String, String, String) highlight,
  void Function(bool) setLocked,
  Future<void> Function(double, double, double) flyTo,
  Future<void> Function(Map<String, dynamic>) updateAiStops,
  Future<void> Function(Map<String, dynamic>) updateRoute,
  Future<void> Function(Map<String, dynamic>) updateContainerPins,
  void Function() resetTapping,
  Future<void> Function(Map<String, dynamic>) updateWarningMarkers,  // ← NEU
)
```

## State-Variablen in map_screen_widget.dart
```dart
// Map callbacks
Future<void> Function(String, String, String)? _highlightFeature;
Future<void> Function(double, double, double)? _flyTo;
Future<void> Function(Map<String, dynamic>)? _updateAiStops;
Future<void> Function(Map<String, dynamic>)? _updateRoute;
Future<void> Function(Map<String, dynamic>)? _updateContainerPins;
Future<void> Function(Map<String, dynamic>)? _updateWarningMarkers;
void Function(bool)? _setMapLocked;
void Function()? _resetTapping;

// Trip
String? _tripId;
String? _tripName;
String? _routeVersionId;
String? _lastCountryCode;
List<Map<String, dynamic>> _stops = [];
List<Map<String, dynamic>> _allTrips = [];
List<Map<String, dynamic>> _warnings = [];
int _totalDaysUsed = 0;
bool _mapReady = false;
Map<String, dynamic> _tripParams = {};

// Glättung
bool _glaettungPending = false;
Map<String, int?> _glaettungSnapshot = {};

// Replace-Popup
Map<String, dynamic>? _pendingReplacePayload;
```

## Warning System
`_getWarnings()` gibt Liste von Maps zurück mit keys: `type`, `stopId`, `message`, `lat`, `lng`

**Warning-Typen:**
1. `child_sum_exceeds` — Child-Summe > Container planned_days
2. `container_outside_trip` — Container außerhalb Trip-Zeitraum
3. `stop_outside_trip` — Stop außerhalb Trip-Zeitraum
4. `stop_outside_container` — Stop außerhalb Container-Zeitraum
5. `container_overlap` — Container überschneidet anderen Container
6. `stop_overlap` — Stop überschneidet anderen Stop im Container
7. `trip_date_conflict` — Trip start_date nach erstem Container start_date

**Flow nach _loadStops():**
1. `_calculateTimes()` → setzt `child_days_sum`, `open_days` auf Container
2. `_autoDeriveTripDates()` → übernimmt start_date des ersten Containers wenn Trip keins hat
3. `_getWarnings()` → berechnet alle Warnungen
4. `_updateWarningMarkersOnMap()` → schickt GeoJSON an Karte (dedupliziert nach lat/lng)
5. `_checkUpgradeNeeded()` → Dialog wenn child_sum > planned_days

## Glättung
- `_applyGlaettung()` — In-Memory: kürzt planned_days wenn Overlaps, speichert Snapshot
- `_undoGlaettung()` — stellt Snapshot wieder her
- `_saveGlaettung()` — schreibt in Supabase, löscht Snapshot
- `_buildGlaettungBanner()` — schmales Banner unter Header wenn _glaettungPending:
  "↩ Rückgängig" + "✓ Speichern"

## Check Trip Dialog
- `_showCheckTripDialog()` — ModalBottomSheet, DraggableScrollableSheet
- Warnungen gruppiert nach Typ, jede Zeile mit Tune-Button → springt zu _showStopParamsDialog
- Bei child_sum_exceeds: "Aufstocken"-Button
- Bei Overlaps: "Automatische Glättung"-Button
- Header-Icon: `health_and_safety_outlined` mit orangem Badge (Anzahl Warnungen)

## Re-run Guard (`_canRerun()`)
Blockiert Re-run wenn:
1. Trip hat kein `start_date` ODER kein `total_days` → erklärender Dialog
2. `_warnings.isNotEmpty` → Dialog mit "Trip Check öffnen"-Button

## Replace-Popup Feature
Wenn Nutzer auf neue Karten-Location klickt während Popup offen:
- `map_web_view.dart`: `_onFeatureTapped` sendet `replaceTap`-Message statt zu ignorieren
- `map_screen_widget.dart`: speichert payload in `_pendingReplacePayload`, poppt Dialog
- Nach Dialog-Close: verarbeitet pending payload als neuen `select`

## Stop-Params Dialog
- 2-of-3 Logik: start+days→end, start+end→days, end+days→start
- Keine duplizierten Parameter-Dropdowns (war Bug, behoben)
- useTripParams Checkbox: wenn true, Parameter-Dropdowns ausgeblendet

## Trip-Dropdown Schutz
- `_loadAllTrips()` dedupliziert nach ID vor setState
- `_buildTripDropdown()` als eigene Hilfsmethode (wegen Dart Block-if Limitation)
- safeValue: fällt auf ersten Trip zurück wenn _tripId nicht in Liste

## Container Card — Zeit-Anzeige
- Format: `child_sum / planned_days d` (z.B. "12 / 15 d")
- Nur child_sum wenn kein planned_days: "12 d"
- Leer: "– d"
- Progress-Bar: grün normal, rot wenn overflow
- GestureDetector auf Zeit-Chip → öffnet _showStopParamsDialog

## Suche (Search Field)
- Zwei Quellen parallel: MapTiler Geocoding + Supabase RPC `search_airports`
- Airports kommen zuerst in der Liste
- Airport-Erkennung: `place_designation == 'airport'` || `categories.contains('airport')` || `kind == 'aerodrome'`
- Bei Airport-Auswahl: Dialog mit "Als Transit" oder "Transit + naheg. Ort"

## KI Re-run JSON Format
```json
{
  "trip": { "id", "name", "total_days", "start_date", "params": {...} },
  "containers": [{
    "stop_id", "place_name", "place_level", "sequence_index",
    "planned_days", "child_stops": [...], "open_days",
    "rules": {"entries": [...]}
  }],
  "route_rules": { "entries": [{"place_name", "state", "applies_to_descendants"}] },
  "rerun_scope": "container" | "full_route",
  "rerun_target_stop_id": "uuid | null"
}
```

## MapTiler Keys
- Map Style Key: `bq7edtBllgSIwDJY9mGU`
- Map URL: `https://api.maptiler.com/maps/aquarelle-v4/style.json?key=bq7edtBllgSIwDJY9mGU`

## ISO2→ISO3 Mapping (häufig verwendet)
```dart
const iso2to3 = {
  'DE':'DEU','FR':'FRA','AT':'AUT','CH':'CHE','IT':'ITA','ES':'ESP',
  'NL':'NLD','BE':'BEL','PL':'POL','CZ':'CZE','HU':'HUN','SK':'SVK',
  'HR':'HRV','DK':'DNK','SE':'SWE','NO':'NOR','GB':'GBR','IE':'IRL',
  'PT':'PRT','GR':'GRC','RO':'ROU','BG':'BGR',
};
```

## Geo-Daten URLs (Netlify)
- Länder: `https://leafy-selkie-49eae2.netlify.app/geodata/world_countries.json`
- Länder-Labels: `https://leafy-selkie-49eae2.netlify.app/geodata/country_labels.json`
- Regionen: `https://leafy-selkie-49eae2.netlify.app/geodata/regions_{ISO3}.json`
- Städte: `https://leafy-selkie-49eae2.netlify.app/geodata/cities_{ISO3}.json`
- Leer: `https://leafy-selkie-49eae2.netlify.app/empty.json`

## GeoJSON Sources in map_web_view.dart
- `eu_countries` — promoteId: ADM0_A3
- `country_labels`
- `regions` — promoteId: iso_3166_2
- `cities` — promoteId: NAME
- `container_pins`
- `ai_stops`
- `route_line`
- `warning_markers` ← NEU
- `flags`

## Layer-IDs in map_web_view.dart
- `eu-countries-fill` / `eu-countries-line` / `eu-countries-labels`
- `regions-fill` / `regions-line` / `regions-labels`
- `cities-circles` / `cities-labels`
- `ai-stops-circles` / `ai-stops-labels`
- `container-pins-circles` / `container-pins-labels`
- `route-line`
- `warning-markers-circles` / `warning-markers-labels` ← NEU

## Kamera-Logik (_onCameraIdle)
- zoom < 5.0 → Regionen + Städte entfernen (leere Sources)
- zoom >= 5.0 → Regionen laden (Reverse Geocoding für ISO3)
- zoom >= 7.0 → Städte laden
- Reverse Geocoding: MapTiler `/geocoding/{lng},{lat}.json?types=country`

## Message Types (onMessageReceived)
- `mapReady` — Karte fertig geladen
- `regionsLoaded` — payload: {iso3}
- `select` — payload: {id, place_level, lat, lng}
- `replaceTap` — payload: {id, place_level, lat, lng} ← NEU (Popup ersetzen)

## Bekannte Bugs / Offene Punkte

### BEHOBEN in dieser Session:
- ✅ Doppelte Parameter-Dropdowns in _showStopParamsDialog
- ✅ ä/ö/ü in Dart-Identifiern (→ ae/oe/ue)
- ✅ Block-if in Widget-Liste (→ _buildTripDropdown Hilfsmethode)
- ✅ Dropdown-Assertion bei neuem Trip (Dedup + safeValue)
- ✅ Click-through bei Dialog-Buttons (Delay 300→450ms + resetTapping)
- ✅ Replace-Popup: neuer Ort-Tap ersetzt aktuelles Popup

### NOCH OFFEN:
- ⚠️ Transit-Reihenfolge im Container: Flughafen + nahegelegene Stadt landen am Ende statt an richtiger sequenzieller Position
- ⚠️ Vollautomatischer Re-run (OpenAI API direkt aus App)
- ⚠️ Flaggen für Container (niedrige Priorität)
- ⚠️ FlutterFlow UI-Merge (nach Design-Freeze)
- ⚠️ Security Pass (niedrige Priorität)

## Flutter Run Command
```
cd C:\Users\timdo\Documents\Business\way2_go_x
flutter run -d chrome
```

## Wichtige Hinweise für Claude Code
- Immer nur gezielte str_replace-Fixes, keine kompletten Dateien neu schreiben
- Dart erlaubt keine Non-ASCII Zeichen in Identifiern
- Widget-Listen (Column children etc.) brauchen Expressions, keine Statements mit `final`
- Nach jedem Dialog: `_setMapLocked?.call(false)` + `_resetTapping?.call()`
- `_loadStops()` ist der zentrale Reload — immer nach Supabase-Writes aufrufen
- FlutterFlow-Imports nicht anfassen (erste Zeilen jeder Datei)
