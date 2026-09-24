// Tests der Regionszuordnung.
//
//   node --test tools/assign-city-regions.test.mjs
//
// Liegt neben dem Werkzeug statt unter `test/`, weil `.gitignore:59` das
// Verzeichnis `test/` ausschliesst — ein Ueberbleibsel der Bereinigung in
// `0d62017 map-data bereinigt: Flutter-App-Reste entfernt`. Eine Testdatei
// dort waere fuer Git unsichtbar.
//
// Zwei Teile: kuenstliche Geometrien, an denen sich jeder Sonderfall genau
// stellen laesst, und die echten Geodaten, damit ein spaeterer Datentausch
// nicht still etwas anderes bedeutet.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import {
  EPSILON, pointOnSegment, pointInRing, pointInPolygon, pointInFeature,
  validRegionCode, countryPrefix, assignRegion, STATUS,
  auditAll, auditCountry, formatReport, cityCountries, REGION_CODE_PROPERTY,
} from './assign-city-regions.mjs';

const GEODATA = 'geodata';

// Ein Quadrat von (0,0) bis (10,10), gegen den Uhrzeigersinn.
const QUADRAT = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]];
// Dasselbe Quadrat, im Uhrzeigersinn gespeichert.
const QUADRAT_UMGEKEHRT = [[0, 0], [0, 10], [10, 10], [10, 0], [0, 0]];
// Ein Loch von (3,3) bis (7,7).
const LOCH = [[3, 3], [7, 3], [7, 7], [3, 7], [3, 3]];

const polygon = (rings) => ({ type: 'Polygon', coordinates: rings });
const multi = (polys) => ({ type: 'MultiPolygon', coordinates: polys });
const region = (code, geometry) => ({ type: 'Feature', properties: { [REGION_CODE_PROPERTY]: code }, geometry });

// ── 1. Geometrie ───────────────────────────────────────────────────────────

test('1 — ein Punkt im Inneren eines einfachen Polygons', () => {
  assert.equal(pointInPolygon([5, 5], [QUADRAT]), 'inside');
});

test('2 — ein Punkt ausserhalb', () => {
  assert.equal(pointInPolygon([50, 50], [QUADRAT]), 'outside');
  assert.equal(pointInPolygon([-1, 5], [QUADRAT]), 'outside');
});

test('3 — ein Punkt auf einer Aussenkante ist ein Grenzfall', () => {
  assert.equal(pointInPolygon([5, 0], [QUADRAT]), 'boundary');
  assert.equal(pointInPolygon([0, 5], [QUADRAT]), 'boundary');
  assert.equal(pointInPolygon([10, 5], [QUADRAT]), 'boundary');
});

test('4 — ein Punkt genau auf einem Eckpunkt ebenfalls', () => {
  for (const ecke of [[0, 0], [10, 0], [10, 10], [0, 10]]) {
    assert.equal(pointInPolygon(ecke, [QUADRAT]), 'boundary', `Ecke ${ecke}`);
  }
});

test('5 — ein Punkt im Loch liegt ausserhalb des Polygons', () => {
  // Das Loch wird abgezogen, nicht hinzugerechnet.
  assert.equal(pointInPolygon([5, 5], [QUADRAT, LOCH]), 'outside');
  // Zwischen Aussenkante und Loch dagegen: drinnen.
  assert.equal(pointInPolygon([1, 1], [QUADRAT, LOCH]), 'inside');
});

test('6 — ein Punkt auf der Lochkante ist ein Grenzfall', () => {
  assert.equal(pointInPolygon([5, 3], [QUADRAT, LOCH]), 'boundary');
  assert.equal(pointInPolygon([3, 3], [QUADRAT, LOCH]), 'boundary');
});

test('7 — ein Punkt in einem MultiPolygon-Teil', () => {
  const g = multi([[QUADRAT], [[[20, 20], [30, 20], [30, 30], [20, 30], [20, 20]]]]);
  assert.equal(pointInFeature([5, 5], g), 'inside');
  assert.equal(pointInFeature([25, 25], g), 'inside');
});

test('8 — ein Punkt ausserhalb aller MultiPolygon-Teile', () => {
  const g = multi([[QUADRAT], [[[20, 20], [30, 20], [30, 30], [20, 30], [20, 20]]]]);
  assert.equal(pointInFeature([15, 15], g), 'outside');
});

test('9 — ein MultiPolygon mit Loch zieht das Loch ebenfalls ab', () => {
  const g = multi([[QUADRAT, LOCH]]);
  assert.equal(pointInFeature([5, 5], g), 'outside');
  assert.equal(pointInFeature([1, 1], g), 'inside');
  assert.equal(pointInFeature([5, 3], g), 'boundary');
});

test('10 — die Umlaufrichtung des Rings aendert nichts', () => {
  // Das Strahlverfahren zaehlt Kreuzungen, nicht Drehsinn.
  for (const punkt of [[5, 5], [50, 50], [5, 0]]) {
    assert.equal(
      pointInRing(punkt, QUADRAT),
      pointInRing(punkt, QUADRAT_UMGEKEHRT),
      `Punkt ${punkt}`);
  }
  assert.equal(pointInPolygon([5, 5], [QUADRAT_UMGEKEHRT]), 'inside');
});

test('11 — pointOnSegment trifft nur die Strecke, nicht die Gerade', () => {
  assert.equal(pointOnSegment(5, 0, 0, 0, 10, 0), true);
  // Auf der Verlaengerung derselben Geraden, aber ausserhalb der Strecke.
  assert.equal(pointOnSegment(20, 0, 0, 0, 10, 0), false);
  assert.equal(pointOnSegment(5, 1, 0, 0, 10, 0), false);
});

test('12 — die Toleranz ist Rechenungenauigkeit, kein geografischer Puffer', () => {
  assert.equal(EPSILON, 1e-12);
  // Ein Zehntel Millimeter daneben ist bereits draussen — nichts wird
  // herangezogen.
  assert.equal(pointInPolygon([-0.000001, 5], [QUADRAT]), 'outside');
  assert.equal(pointInPolygon([5, -0.000001], [QUADRAT]), 'outside');
});

// ── 2. Codes und Zusammenfassung ───────────────────────────────────────────

test('13 — zwei Features mit demselben Code sind keine Mehrdeutigkeit', () => {
  // Ein Land darf seine Region in beliebig viele Teile zerlegen.
  const regionen = [
    region('DE-BY', polygon([QUADRAT])),
    region('DE-BY', polygon([[[2, 2], [8, 2], [8, 8], [2, 8], [2, 2]]])),
  ];
  const r = assignRegion([5, 5], regionen, 'DE');
  assert.equal(r.status, STATUS.unique);
  assert.equal(r.code, 'DE-BY');
});

test('14 — dasselbe gilt fuer mehrere Polygone eines MultiPolygons', () => {
  const regionen = [region('DE-BY', multi([[QUADRAT], [[[2, 2], [8, 2], [8, 8], [2, 8], [2, 2]]]]))];
  const r = assignRegion([5, 5], regionen, 'DE');
  assert.equal(r.status, STATUS.unique);
  assert.equal(r.code, 'DE-BY');
});

test('15 — Treffer auf verschiedene Codes ergeben ambiguous', () => {
  const regionen = [
    region('DE-BY', polygon([QUADRAT])),
    region('DE-BW', polygon([[[2, 2], [8, 2], [8, 8], [2, 8], [2, 2]]])),
  ];
  const r = assignRegion([5, 5], regionen, 'DE');
  assert.equal(r.status, STATUS.ambiguous);
  assert.equal(r.code, null, 'bei Mehrdeutigkeit wird kein Code vergeben');
  assert.deepEqual(r.codes, ['DE-BW', 'DE-BY'], 'lexikografisch sortiert');
});

test('16 — kein Treffer ergibt unresolved und keinen Code', () => {
  const r = assignRegion([50, 50], [region('DE-BY', polygon([QUADRAT]))], 'DE');
  assert.equal(r.status, STATUS.unresolved);
  assert.equal(r.code, null);
});

test('17 — ein Grenzfall vergibt niemals einen Code', () => {
  const r = assignRegion([5, 0], [region('DE-BY', polygon([QUADRAT]))], 'DE');
  assert.equal(r.status, STATUS.boundary);
  assert.equal(r.code, null);
  assert.deepEqual(r.boundaryCodes, ['DE-BY']);
});

test('18 — die Grenze gewinnt auch gegen einen Treffer im Inneren', () => {
  // Wer auf einer Kante sitzt, wird nicht stillschweigend einer Seite
  // zugeschlagen — selbst wenn ein anderes Gebiet ihn klar enthaelt.
  const regionen = [
    region('DE-BY', polygon([[[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]]])),
    region('DE-BW', polygon([[[5, 0], [20, 0], [20, 10], [5, 10], [5, 0]]])),
  ];
  const r = assignRegion([5, 5], regionen, 'DE');
  assert.equal(r.status, STATUS.boundary);
  assert.equal(r.code, null);
});

test('19 — ein ungueltiger Code wird nie vergeben', () => {
  for (const schlecht of ['AQ-X01~', 'BA-BIH_4', 'DE', 'DE-', 'de-by', '', null, undefined, 42]) {
    assert.equal(validRegionCode(schlecht, 'DE'), false, `Code ${schlecht}`);
  }
  // Ein Punkt mitten in einem Platzhaltergebiet bleibt ohne Code.
  const r = assignRegion([5, 5], [region('AQ-X01~', polygon([QUADRAT]))], 'AQ');
  assert.equal(r.status, STATUS.unresolved);
  assert.equal(r.code, null);
});

test('20 — ein fremdes Landespraefix wird nie vergeben', () => {
  assert.equal(validRegionCode('UA-43', 'RU'), false);
  assert.equal(validRegionCode('UA-43', 'UA'), true);
  const r = assignRegion([5, 5], [region('UA-43', polygon([QUADRAT]))], 'RU');
  assert.equal(r.status, STATUS.unresolved,
    'eine russische Stadt bekommt keinen ukrainischen Regionscode');
});

test('21 — countryPrefix nimmt das haeufigste formgueltige Praefix', () => {
  const regionen = [
    region('RU-MOW', polygon([QUADRAT])), region('RU-SPE', polygon([QUADRAT])),
    region('UA-43', polygon([QUADRAT])),
  ];
  assert.equal(countryPrefix(regionen), 'RU');
  // Nur Platzhalter: kein Praefix, also spaeter kein Code.
  assert.equal(countryPrefix([region('AQ-X01~', polygon([QUADRAT]))]), null);
  assert.equal(countryPrefix([]), null);
  // Gleichstand bleibt bewusst unentschieden.
  assert.equal(countryPrefix([region('RU-MOW', polygon([QUADRAT])), region('UA-43', polygon([QUADRAT]))]), null);
});

// ── 3. Echte Geodaten ──────────────────────────────────────────────────────

/// Eine Stadt aus den echten Dateien nachschlagen und zuordnen.
///
/// Die Staedtedateien sind zweisprachig: `NAME` traegt den deutschen, `NAME_EN`
/// den englischen Namen. Beide koennen abweichen — Brno steht als
/// `NAME="Brünn"` / `NAME_EN="Brno"`, Muenchen als `NAME="München"` /
/// `NAME_EN="Munich"`. Deshalb wird gegen **beide** Felder gesucht, und der
/// Treffer muss eindeutig sein; es gibt in diesen Dateien keine stabile ID.
function ordneZu(iso3, stadtname) {
  const regions = JSON.parse(readFileSync(`${GEODATA}/regions_${iso3}.json`, 'utf8')).features;
  const cities = JSON.parse(readFileSync(`${GEODATA}/cities_${iso3}.json`, 'utf8')).features;
  const treffer = cities.filter(
    (f) => f.properties?.NAME === stadtname || f.properties?.NAME_EN === stadtname);
  assert.equal(treffer.length, 1,
    `"${stadtname}" muss in cities_${iso3}.json genau einmal vorkommen, gefunden: ${treffer.length}`);
  return assignRegion(treffer[0].geometry.coordinates, regions, countryPrefix(regions));
}

test('22 — Muenchen liegt in Bayern', () => {
  const r = ordneZu('DEU', 'München');
  assert.equal(r.status, STATUS.unique);
  assert.equal(r.code, 'DE-BY');
});

test('23 — Nuernberg ebenfalls', () => {
  const r = ordneZu('DEU', 'Nürnberg');
  assert.equal(r.status, STATUS.unique);
  assert.equal(r.code, 'DE-BY');
});

test('24 — Berlin ist sein eigenes Land', () => {
  const r = ordneZu('DEU', 'Berlin');
  assert.equal(r.status, STATUS.unique);
  assert.equal(r.code, 'DE-BE');
});

test('25 — Hamburg auch', () => {
  const r = ordneZu('DEU', 'Hamburg');
  assert.equal(r.status, STATUS.unique);
  assert.equal(r.code, 'DE-HH');
});

test('26 — Brno liegt in Suedmaehren und NICHT in Vysocina', () => {
  // Der Grund, warum dieses Werkzeug ueberhaupt existiert: das Namensfeld
  // der frueheren Datenquelle behauptete fuer Brno „Kraj Vysocina".
  // In diesen Dateien heisst der Ort `NAME="Brünn"`, `NAME_EN="Brno"`.
  const r = ordneZu('CZE', 'Brno');
  assert.equal(r.status, STATUS.unique);
  assert.equal(r.code, 'CZ-JM');
  assert.notEqual(r.code, 'CZ-VY');
});

test('27 — Viana do Castelo bleibt unresolved, es wird nicht gesnappt', () => {
  // Der Punkt liegt rund 145 m ausserhalb der generalisierten Kuestenlinie.
  // Fachlich waere PT-16 richtig — genau deshalb steht dieser Test hier: die
  // naechstgelegene Region zu nehmen ist verboten.
  const r = ordneZu('PRT', 'Viana do Castelo');
  assert.equal(r.status, STATUS.unresolved);
  assert.equal(r.code, null);
});

test('28 — die Amundsen-Scott-Suedpolstation ist ein Grenzfall', () => {
  const r = ordneZu('ATA', 'Amundsen-Scott-Südpolstation');
  assert.equal(r.status, STATUS.boundary);
  assert.equal(r.code, null);
});

// ── 4. Gesamtbestand ───────────────────────────────────────────────────────

test('29 — die Bestandsaufnahme des gesamten Datenbestands', () => {
  const { totals } = auditAll(GEODATA);
  // Bewusst exakt: aendern sich die Geodaten, muss dieser Test bewusst
  // angefasst werden, statt dass eine Verschlechterung durchrutscht.
  assert.deepEqual(
    {
      countries: totals.countries, cities: totals.cities, unique: totals.unique,
      unresolved: totals.unresolved, ambiguous: totals.ambiguous,
      boundary: totals.boundary, invalidCoordinates: totals.invalidCoordinates,
      missingRegionDataset: totals.missingRegionDataset,
    },
    {
      countries: 230, cities: 7342, unique: 7103, unresolved: 173,
      ambiguous: 0, boundary: 1, invalidCoordinates: 0, missingRegionDataset: 65,
    });
});

test('30 — die Summe geht vollstaendig auf', () => {
  const { totals } = auditAll(GEODATA);
  const summe = totals.unique + totals.unresolved + totals.ambiguous +
                totals.boundary + totals.invalidCoordinates + totals.missingRegionDataset;
  assert.equal(summe, totals.cities, 'jede Stadt liegt in genau einer Kategorie');
});

test('31 — Mindestabdeckung', () => {
  const { totals } = auditAll(GEODATA);
  const zuordenbar = totals.cities - totals.missingRegionDataset;
  assert.ok(totals.unique / zuordenbar >= 0.95,
    `Abdeckung ${(100 * totals.unique / zuordenbar).toFixed(1)}% unter 95%`);
  assert.equal(totals.ambiguous, 0, 'keine Stadt darf mehrdeutig sein');
});

test('32 — die drei Laender ohne Regionsdatensatz', () => {
  const { countries } = auditAll(GEODATA);
  const ohne = countries.filter((c) => c.missingRegionDataset)
    .map((c) => `${c.iso3}:${c.total}`).sort();
  assert.deepEqual(ohne, ['ESP:49', 'SJM:1', 'SSD:15']);
});

test('33 — kein ausgegebener Code ist ungueltig', () => {
  const { countries } = auditAll(GEODATA);
  for (const land of countries) {
    for (const row of land.rows) {
      if (row.status !== STATUS.unique) {
        assert.equal(row.code, null, `${land.iso3} ${row.name} traegt einen Code ohne unique`);
        continue;
      }
      assert.ok(validRegionCode(row.code, land.prefix), `${land.iso3} ${row.name}: ${row.code}`);
      assert.ok(!row.code.includes('~') && !row.code.includes('_'));
    }
  }
});

// ── 5. Determinismus ───────────────────────────────────────────────────────

test('34 — zwei Laeufe liefern byte-gleichen Bericht', () => {
  const a = formatReport(auditAll(GEODATA));
  const b = formatReport(auditAll(GEODATA));
  assert.equal(a, b);
  assert.equal(Buffer.byteLength(a, 'utf8'), Buffer.byteLength(b, 'utf8'));
});

test('35 — der Bericht traegt weder Zeitstempel noch absolute Pfade', () => {
  const text = formatReport(auditAll(GEODATA));
  assert.ok(!/\d{4}-\d{2}-\d{2}T\d{2}:/.test(text), 'kein ISO-Zeitstempel');
  assert.ok(!/[A-Za-z]:\\/.test(text), 'kein Windows-Pfad');
  assert.ok(!/\/(?:home|Users)\//.test(text), 'kein Unix-Heimatpfad');
});

test('36 — Laender und Orte sind stabil sortiert', () => {
  const { countries } = auditAll(GEODATA);
  const iso = countries.map((c) => c.iso3);
  assert.deepEqual(iso, [...iso].sort(), 'Laender nach ISO3');
  assert.deepEqual(iso, cityCountries(GEODATA));
  const de = auditCountry(GEODATA, 'DEU').rows.map((r) => r.name);
  assert.deepEqual(de, [...de].sort((a, b) => a.localeCompare(b, 'en')));
});

// ── 6. Das Werkzeug bleibt lesend ──────────────────────────────────────────

test('37 — das Werkzeug schreibt nicht, laedt nichts und kennt keine Sonderfaelle', () => {
  const quelle = readFileSync('tools/assign-city-regions.mjs', 'utf8');
  for (const verboten of [
    'writeFile', 'appendFile', 'createWriteStream', 'rename', 'unlink', 'rmdir',
    'rm(', 'mkdir', 'fetch(', 'http', 'XMLHttpRequest', 'child_process', 'exec(',
    'ADM1NAME', 'nearest', 'distance', 'haversine',
  ]) {
    assert.ok(!quelle.includes(verboten), `"${verboten}" darf im Werkzeug nicht vorkommen`);
  }
  // Nur lesende fs-Aufrufe.
  assert.ok(quelle.includes('readFileSync') && quelle.includes('readdirSync'));
  assert.deepEqual(quelle.match(/from 'node:[a-z]+'/g).sort(),
    ["from 'node:fs'", "from 'node:path'"], 'keine externe Abhaengigkeit');
});

test('38 — keine der Pflichtstaedte steht im Werkzeug', () => {
  // Sie duerfen in Tests vorkommen, nie aber als Sonderfall im Algorithmus.
  const quelle = readFileSync('tools/assign-city-regions.mjs', 'utf8');
  for (const ort of ['München', 'Nürnberg', 'Berlin', 'Hamburg', 'Brno',
                     'Viana', 'Amundsen', 'DE-BY', 'CZ-JM', 'PT-16']) {
    assert.ok(!quelle.includes(ort), `"${ort}" darf nicht im Werkzeug stehen`);
  }
});
