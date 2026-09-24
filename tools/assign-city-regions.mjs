// Ordnet jeder Stadt ihre Region zu — rein geometrisch.
//
// Der Weg ist bewusst der einzige, der ohne Raten auskommt: ein Stadtpunkt
// liegt in genau einem Regionspolygon, oder er liegt in keinem. Es gibt
// keinen Namensvergleich, keine Nachbarsuche, keinen Puffer und keine
// Korrekturliste fuer einzelne Orte.
//
// Warum ueberhaupt: die Staedtedateien fuehren `NAME`, `NAME_EN` und
// `SCALERANK` — **keinen** Regionshinweis. Ohne Geometrie gibt es keine
// belastbare Zuordnung.
//
// Dieses Werkzeug **liest nur**. Es schreibt keine Datei, oeffnet kein Netz
// und haelt keine Stadt gesondert fest.
//
//   node tools/assign-city-regions.mjs                 # Bericht ueber alles
//   node tools/assign-city-regions.mjs --country DEU   # ein Land
//   node tools/assign-city-regions.mjs --geodata ./geodata
//
// Die Ausgabe ist deterministisch: zwei Laeufe gegen denselben Datenstand
// liefern byte-gleichen Text. Keine Zeitstempel, keine absoluten Pfade.

import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// ── Geometrie ──────────────────────────────────────────────────────────────

/// Toleranz **nur** fuer die Frage „liegt der Punkt auf dieser Kante?".
///
/// 1e-12 Grad sind rund ein Zehntel Mikrometer — das ist Rechenungenauigkeit,
/// kein geografischer Puffer. Die Toleranz darf niemals benutzt werden, um
/// einen Punkt in ein Polygon hineinzuziehen, in dem er nicht liegt.
export const EPSILON = 1e-12;

/// Liegt `[px, py]` auf der Strecke `[ax, ay] → [bx, by]`?
///
/// Zuerst Kollinearitaet ueber das Kreuzprodukt, dann die Frage, ob der Punkt
/// zwischen den Enden liegt. Ohne den zweiten Teil traefe auch die verlaengerte
/// Gerade zu.
export function pointOnSegment(px, py, ax, ay, bx, by) {
  const cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
  if (Math.abs(cross) > EPSILON) return false;
  return px >= Math.min(ax, bx) - EPSILON && px <= Math.max(ax, bx) + EPSILON &&
         py >= Math.min(ay, by) - EPSILON && py <= Math.max(ay, by) + EPSILON;
}

/// Lage eines Punktes zu einem einzelnen Ring: `'inside' | 'outside' | 'boundary'`.
///
/// Strahlverfahren. Die Umlaufrichtung des Rings spielt dabei keine Rolle —
/// gezaehlt werden Kreuzungen, nicht Drehsinn. Deshalb ist es gleichgueltig,
/// ob ein Ring im oder gegen den Uhrzeigersinn gespeichert ist.
///
/// `ring` ist eine Liste von `[lng, lat]`.
export function pointInRing(point, ring) {
  const [px, py] = point;
  if (!Array.isArray(ring) || ring.length < 3) return 'outside';
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [ax, ay] = ring[j];
    const [bx, by] = ring[i];
    // Die Grenze gewinnt immer: wer auf der Kante sitzt, ist weder drinnen
    // noch draussen, und darf nicht still einer Seite zugeschlagen werden.
    if (pointOnSegment(px, py, ax, ay, bx, by)) return 'boundary';
    if ((ay > py) !== (by > py) && px < ((bx - ax) * (py - ay)) / (by - ay) + ax) {
      inside = !inside;
    }
  }
  return inside ? 'inside' : 'outside';
}

/// Lage zu einem GeoJSON-Polygon: `rings[0]` ist die Aussenkante, alles
/// weitere sind Loecher.
///
/// Ein Punkt in einem Loch liegt **ausserhalb** des Polygons — das Loch wird
/// abgezogen, nicht hinzugerechnet. Eine Lochkante zaehlt wie jede Grenze.
export function pointInPolygon(point, rings) {
  if (!Array.isArray(rings) || rings.length === 0) return 'outside';
  const outer = pointInRing(point, rings[0]);
  if (outer !== 'inside') return outer;
  for (let k = 1; k < rings.length; k++) {
    const hole = pointInRing(point, rings[k]);
    if (hole === 'boundary') return 'boundary';
    if (hole === 'inside') return 'outside';
  }
  return 'inside';
}

/// Lage zu einer GeoJSON-Geometrie. `Polygon` und `MultiPolygon`, jeweils
/// mit beliebig vielen Loechern.
///
/// Beim MultiPolygon gewinnt ein echtes Innen vor einer Grenze: liegt der
/// Punkt in einem Teil wirklich drin, ist die Sache entschieden. Nur wenn
/// kein Teil ihn enthaelt und mindestens einer ihn auf der Kante hat, bleibt
/// es ein Grenzfall.
export function pointInFeature(point, geometry) {
  if (!geometry) return 'outside';
  if (geometry.type === 'Polygon') return pointInPolygon(point, geometry.coordinates);
  if (geometry.type === 'MultiPolygon') {
    let touched = false;
    for (const rings of geometry.coordinates) {
      const hit = pointInPolygon(point, rings);
      if (hit === 'inside') return 'inside';
      if (hit === 'boundary') touched = true;
    }
    return touched ? 'boundary' : 'outside';
  }
  return 'outside';
}

// ── Regionscodes ───────────────────────────────────────────────────────────

/// Das Property, in dem der Regionscode steht. Am Datenbestand geprueft:
/// alle 4527 Regionsfeatures tragen `iso_3166_2`.
export const REGION_CODE_PROPERTY = 'iso_3166_2';

/// Die strenge ISO-3166-2-Form: zwei Buchstaben, Bindestrich, ein bis drei
/// alphanumerische Zeichen.
const ISO_3166_2 = /^[A-Z]{2}-[A-Z0-9]{1,3}$/;

/// Taugt dieser Wert als Regionscode fuer ein Land mit dem Praefix `prefix`?
///
/// Drei Arten von Werten fallen durch, und alle drei aus gutem Grund:
///
///   * **Tilde** (`AQ-X01~`) — Natural-Earth-Platzhalter fuer ein Gebiet ohne
///     eigenen ISO-Code. 188 Stueck im Bestand.
///   * **Unterstrich** (`BA-BIH_4`) — eine Erfindung der Quelldaten, um
///     mehrere Gebiete mit demselben Basiscode auseinanderzuhalten. Kein
///     gueltiger ISO-Code, also wird er nicht ausgegeben.
///   * **fremdes Landespraefix** — `UA-43` steht in `regions_RUS.json`. Fuer
///     eine russische Stadt waere das der Code eines anderen Landes.
///
/// Lieber kein Code als ein erfundener: ein `unresolved` ist sichtbar, ein
/// falscher Code nicht.
export function validRegionCode(code, prefix) {
  if (typeof code !== 'string') return false;
  if (!ISO_3166_2.test(code)) return false;
  if (typeof prefix !== 'string' || prefix.length === 0) return false;
  return code.slice(0, 2) === prefix;
}

/// Das Alpha-2-Praefix, das zu einer Regionsdatei gehoert.
///
/// Aus den Daten selbst gewonnen statt aus einer gepflegten Liste: das
/// haeufigste formgueltige Praefix der Datei. Fuer 257 der 258 Dateien gibt es
/// ohnehin nur eines. Die Ausnahme ist `regions_RUS.json`, die neben 84
/// `RU-`-Codes auch `UA-43` und `UA-40` fuehrt; dort gewinnt `RU`, und die
/// beiden `UA`-Eintraege gelten fuer russische Staedte als fremd.
///
/// Bei Gleichstand: `null` — dann wird fuer dieses Land kein Code vergeben.
export function countryPrefix(regionFeatures) {
  const counts = new Map();
  for (const feature of regionFeatures ?? []) {
    const code = feature?.properties?.[REGION_CODE_PROPERTY];
    if (typeof code !== 'string' || !ISO_3166_2.test(code)) continue;
    const prefix = code.slice(0, 2);
    counts.set(prefix, (counts.get(prefix) ?? 0) + 1);
  }
  if (counts.size === 0) return null;
  const ranked = [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  if (ranked.length > 1 && ranked[0][1] === ranked[1][1]) return null;
  return ranked[0][0];
}

// ── Zuordnung ──────────────────────────────────────────────────────────────

/// Das Ergebnis einer Zuordnung.
///
///   * `unique`     — genau ein gueltiger Code
///   * `unresolved` — in keinem gueltigen Regionspolygon
///   * `ambiguous`  — in Polygonen mit mindestens zwei verschiedenen Codes
///   * `boundary`   — auf einer Aussen- oder Lochgrenze; **kein** Code
export const STATUS = Object.freeze({
  unique: 'unique',
  unresolved: 'unresolved',
  ambiguous: 'ambiguous',
  boundary: 'boundary',
});

/// Ordnet einem Punkt seine Region zu.
///
/// Reihenfolge mit Absicht:
///
///   1. **Geometrie zuerst.** Ein Grenzfall bleibt ein Grenzfall, auch wenn
///      das beruehrte Gebiet gar keinen gueltigen Code hat. Sonst verschwaende
///      ein Ort, der genau auf einer Kante sitzt, still im `unresolved` —
///      statt als das sichtbar zu sein, was er ist.
///   2. **Danach die Codes.** Von den echten Treffern bleiben nur die mit
///      gueltigem Code uebrig.
///   3. **Dann zusammenfassen.** Mehrere Polygone oder Features mit
///      *demselben* Code sind keine Mehrdeutigkeit — ein Land darf seine
///      Region in beliebig viele Teile zerlegen.
///
/// `point` ist `[lng, lat]`, wie GeoJSON es speichert.
export function assignRegion(point, regionFeatures, prefix) {
  const inside = [];
  const touched = [];
  for (const feature of regionFeatures ?? []) {
    const where = pointInFeature(point, feature?.geometry);
    if (where === 'inside') inside.push(feature?.properties?.[REGION_CODE_PROPERTY]);
    else if (where === 'boundary') touched.push(feature?.properties?.[REGION_CODE_PROPERTY]);
  }

  const sortedUnique = (list) =>
    [...new Set(list.filter((c) => typeof c === 'string'))].sort();

  if (touched.length > 0) {
    return { status: STATUS.boundary, code: null,
             codes: sortedUnique(inside), boundaryCodes: sortedUnique(touched) };
  }

  const valid = sortedUnique(inside.filter((c) => validRegionCode(c, prefix)));
  if (valid.length === 1) {
    return { status: STATUS.unique, code: valid[0], codes: valid, boundaryCodes: [] };
  }
  if (valid.length === 0) {
    return { status: STATUS.unresolved, code: null,
             codes: sortedUnique(inside), boundaryCodes: [] };
  }
  return { status: STATUS.ambiguous, code: null, codes: valid, boundaryCodes: [] };
}

// ── Lesen ──────────────────────────────────────────────────────────────────

const readJson = (file) => JSON.parse(readFileSync(file, 'utf8'));

/// Die ISO3-Kuerzel aller vorhandenen Staedtedateien, aufsteigend sortiert.
export function cityCountries(geodataDir) {
  return readdirSync(geodataDir)
    .filter((f) => /^cities_[A-Z]{3}\.json$/.test(f))
    .map((f) => f.slice('cities_'.length, -'.json'.length))
    .sort();
}

/// Die Features einer Datei, oder `null`, wenn es sie nicht gibt.
function featuresOf(geodataDir, name) {
  try {
    const data = readJson(join(geodataDir, name));
    return Array.isArray(data?.features) ? data.features : null;
  } catch {
    return null;
  }
}

/// Eine Stadt so beschreiben, dass sie stabil sortierbar und wiedererkennbar
/// ist. Die Staedtedateien fuehren **keine** ID — deshalb Name, englischer
/// Name und zuletzt die Koordinate.
function describeCity(feature) {
  const props = feature?.properties ?? {};
  const coords = feature?.geometry?.coordinates;
  const valid = Array.isArray(coords) && coords.length >= 2 &&
    typeof coords[0] === 'number' && typeof coords[1] === 'number' &&
    Number.isFinite(coords[0]) && Number.isFinite(coords[1]);
  return {
    name: typeof props.NAME === 'string' ? props.NAME : '',
    nameEn: typeof props.NAME_EN === 'string' ? props.NAME_EN : '',
    lng: valid ? coords[0] : null,
    lat: valid ? coords[1] : null,
    hasCoordinate: valid,
  };
}

/// Stabile Reihenfolge ohne ID: Name, englischer Name, dann die Koordinate.
function compareCities(a, b) {
  return a.name.localeCompare(b.name, 'en') ||
         a.nameEn.localeCompare(b.nameEn, 'en') ||
         (a.lng ?? 0) - (b.lng ?? 0) ||
         (a.lat ?? 0) - (b.lat ?? 0);
}

// ── Audit ──────────────────────────────────────────────────────────────────

/// Prueft ein Land. Veraendert nichts.
export function auditCountry(geodataDir, iso3) {
  const cities = featuresOf(geodataDir, `cities_${iso3}.json`) ?? [];
  const regions = featuresOf(geodataDir, `regions_${iso3}.json`);
  const rows = cities.map(describeCity).sort(compareCities);

  if (regions === null) {
    return { iso3, prefix: null, missingRegionDataset: true, total: rows.length,
             unique: 0, unresolved: 0, ambiguous: 0, boundary: 0,
             invalidCoordinates: 0, invalidCodes: 0, invalidCodeSamples: [], rows: [] };
  }

  const prefix = countryPrefix(regions);
  let invalidCodes = 0;
  const invalidCodeSamples = new Set();
  for (const feature of regions) {
    const code = feature?.properties?.[REGION_CODE_PROPERTY];
    if (!validRegionCode(code, prefix)) {
      invalidCodes++;
      if (typeof code === 'string') invalidCodeSamples.add(code);
    }
  }

  const out = { iso3, prefix, missingRegionDataset: false, total: rows.length,
                unique: 0, unresolved: 0, ambiguous: 0, boundary: 0,
                invalidCoordinates: 0, invalidCodes,
                invalidCodeSamples: [...invalidCodeSamples].sort(), rows: [] };

  for (const city of rows) {
    if (!city.hasCoordinate) {
      out.invalidCoordinates++;
      out.rows.push({ ...city, status: 'invalid-coordinate', code: null, codes: [], boundaryCodes: [] });
      continue;
    }
    const result = assignRegion([city.lng, city.lat], regions, prefix);
    out[result.status]++;
    out.rows.push({ ...city, ...result });
  }
  return out;
}

/// Prueft alle Laender mit Staedtedatei.
export function auditAll(geodataDir) {
  const countries = cityCountries(geodataDir).map((iso3) => auditCountry(geodataDir, iso3));
  const totals = { countries: countries.length, cities: 0, unique: 0, unresolved: 0,
                   ambiguous: 0, boundary: 0, invalidCoordinates: 0,
                   missingRegionDataset: 0, invalidCodes: 0 };
  for (const c of countries) {
    totals.cities += c.total;
    if (c.missingRegionDataset) { totals.missingRegionDataset += c.total; continue; }
    totals.unique += c.unique;
    totals.unresolved += c.unresolved;
    totals.ambiguous += c.ambiguous;
    totals.boundary += c.boundary;
    totals.invalidCoordinates += c.invalidCoordinates;
    totals.invalidCodes += c.invalidCodes;
  }
  return { totals, countries };
}

// ── Bericht ────────────────────────────────────────────────────────────────

const pad = (v, n) => String(v).padStart(n);

/// Der Bericht als Text. Deterministisch: keine Zeitstempel, keine Pfade,
/// keine zufaelligen Kennungen. Zwei Laeufe liefern denselben String.
export function formatReport({ totals, countries }) {
  const out = [];
  const sum = totals.unique + totals.unresolved + totals.ambiguous +
              totals.boundary + totals.invalidCoordinates + totals.missingRegionDataset;

  out.push('REGIONSZUORDNUNG — GESAMT');
  out.push('');
  out.push(`  Laender mit Staedtedatei   ${pad(totals.countries, 6)}`);
  out.push(`  Staedte                    ${pad(totals.cities, 6)}`);
  out.push(`  unique                     ${pad(totals.unique, 6)}`);
  out.push(`  unresolved                 ${pad(totals.unresolved, 6)}`);
  out.push(`  ambiguous                  ${pad(totals.ambiguous, 6)}`);
  out.push(`  boundary                   ${pad(totals.boundary, 6)}`);
  out.push(`  invalid coordinates        ${pad(totals.invalidCoordinates, 6)}`);
  out.push(`  missing region dataset     ${pad(totals.missingRegionDataset, 6)}`);
  out.push(`  ungueltige Regionscodes    ${pad(totals.invalidCodes, 6)}`);
  out.push(`  Summe stimmt               ${sum === totals.cities ? 'ja' : 'NEIN (' + sum + ')'}`);
  out.push('');

  out.push('JE LAND');
  out.push('  ISO3   Staedte  unique  unres  ambig  bound  badxy  ungCodes');
  for (const c of countries) {
    if (c.missingRegionDataset) {
      out.push(`  ${c.iso3}    ${pad(c.total, 6)}       —      —      —      —      —         —  (keine Regionsdatei)`);
      continue;
    }
    out.push(`  ${c.iso3}    ${pad(c.total, 6)}  ${pad(c.unique, 6)} ${pad(c.unresolved, 6)} ` +
             `${pad(c.ambiguous, 6)} ${pad(c.boundary, 6)} ${pad(c.invalidCoordinates, 6)} ${pad(c.invalidCodes, 9)}`);
  }
  out.push('');

  const listing = (title, status) => {
    const rows = [];
    for (const c of countries) {
      for (const r of c.rows) if (r.status === status) rows.push({ iso3: c.iso3, ...r });
    }
    out.push(`${title} (${rows.length})`);
    for (const r of rows) {
      const extra = r.boundaryCodes?.length ? `  grenze=${r.boundaryCodes.join(',')}`
                  : r.codes?.length ? `  codes=${r.codes.join(',')}` : '';
      out.push(`  ${r.iso3}  ${r.name}  [${r.lng}, ${r.lat}]${extra}`);
    }
    out.push('');
  };
  listing('UNRESOLVED', STATUS.unresolved);
  listing('BOUNDARY', STATUS.boundary);
  listing('AMBIGUOUS', STATUS.ambiguous);
  listing('UNGUELTIGE KOORDINATE', 'invalid-coordinate');

  const missing = countries.filter((c) => c.missingRegionDataset);
  out.push(`LAENDER OHNE REGIONSDATENSATZ (${missing.length})`);
  for (const c of missing) out.push(`  ${c.iso3}  ${c.total} Staedte`);
  out.push('');

  return out.join('\n');
}

// ── CLI ────────────────────────────────────────────────────────────────────

function main(argv) {
  let geodataDir = 'geodata';
  let only = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--geodata' && argv[i + 1]) geodataDir = argv[++i];
    else if (argv[i] === '--country' && argv[i + 1]) only = argv[++i].toUpperCase();
  }
  const report = only
    ? { totals: null, countries: [auditCountry(geodataDir, only)] }
    : auditAll(geodataDir);
  if (report.totals === null) {
    const c = report.countries[0];
    report.totals = { countries: 1, cities: c.total, unique: c.unique,
      unresolved: c.unresolved, ambiguous: c.ambiguous, boundary: c.boundary,
      invalidCoordinates: c.invalidCoordinates,
      missingRegionDataset: c.missingRegionDataset ? c.total : 0,
      invalidCodes: c.invalidCodes };
  }
  process.stdout.write(formatReport(report) + '\n');
}

if (import.meta.filename === process.argv[1]) main(process.argv.slice(2));
