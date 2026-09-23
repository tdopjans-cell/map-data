// Tests des Schreibwerkzeugs.
//
//   node --test tools/apply-city-region-codes.test.mjs
//
// **Kein Test schreibt jemals in das echte `geodata/`.** Alles, was schreibt,
// laeuft in einem frischen temporaeren Verzeichnis mit selbstgebauten
// Fixtures; der echte Bestand wird ausschliesslich gelesen.
//
// Liegt neben dem Werkzeug statt unter `test/`, weil `.gitignore:59` das
// Verzeichnis `test/` ausschliesst.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import {
  serializeLikeSource, inspectCityFile, planCityFileUpdate, planAllCityUpdates,
  applyPlannedUpdates, runCheck, runDryRun, runWrite, parseArgs, cityFilesIn,
  ApplyError, GEODATA_DIR,
} from './apply-city-region-codes.mjs';

const ECHT = 'geodata';

// ── Fixtures ───────────────────────────────────────────────────────────────

/// Ein Quadrat von (0,0) bis (10,10) als Region mit frei waehlbarem Code.
const quadrat = (code, name = 'Region') => ({
  type: 'Feature',
  properties: { iso_3166_2: code, NAME: name, NAME_EN: name, ADM0_A3: 'XXX' },
  geometry: { type: 'Polygon', coordinates: [[[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]]] },
});

const stadt = (name, lng, lat, extra = null) => ({
  type: 'Feature',
  properties: extra === null
    ? { NAME: name, NAME_EN: name, SCALERANK: 5 }
    : { NAME: name, NAME_EN: name, SCALERANK: 5, iso_3166_2: extra },
  geometry: { type: 'Point', coordinates: [lng, lat] },
});

/// Legt ein temporaeres Geodatenverzeichnis an und liefert seinen Pfad.
function fixture(iso3, cities, regions) {
  const dir = mkdtempSync(join(tmpdir(), 'w2gx-apply-'));
  const schreib = (datei, obj) =>
    writeFileSync(join(dir, datei), serializeLikeSource(obj), 'utf8');
  schreib(`cities_${iso3}.json`, { type: 'FeatureCollection', name: `cities_${iso3}`, features: cities });
  if (regions !== null) {
    schreib(`regions_${iso3}.json`, { type: 'FeatureCollection', name: `regions_${iso3}`, features: regions });
  }
  return dir;
}

const weg = (dir) => rmSync(dir, { recursive: true, force: true });
const lies = (dir, datei) => readFileSync(join(dir, datei), 'utf8');

/// Alle Dateien eines Verzeichnisses als Name -> {inhalt, mtime}.
function schnappschuss(dir) {
  const out = {};
  for (const f of readdirSync(dir)) {
    out[f] = { inhalt: readFileSync(join(dir, f), 'utf8'), mtime: statSync(join(dir, f)).mtimeMs };
  }
  return out;
}

// ── 1. Serialisierer ───────────────────────────────────────────────────────

test('1 — der Serialisierer trifft das Quellformat', () => {
  const s = serializeLikeSource({ a: 1, b: [1, 2], c: { d: 'x' } });
  assert.equal(s, '{"a": 1, "b": [1, 2], "c": {"d": "x"}}');
  assert.ok(!s.includes('\n'), 'einzeilig');
});

test('2 — Rundlauf ueber den gesamten echten Bestand', () => {
  // Der Beweis, auf dem alles andere ruht.
  let n = 0;
  for (const iso3 of cityFilesIn(ECHT)) {
    const raw = readFileSync(join(ECHT, `cities_${iso3}.json`), 'utf8');
    assert.equal(serializeLikeSource(JSON.parse(raw)), raw, `cities_${iso3}.json`);
    n++;
  }
  assert.equal(n, 230);
});

test('3 — Unicode bleibt direkt, kein Escape', () => {
  const s = serializeLikeSource({ NAME: 'München', X: 'Ústí' });
  assert.ok(s.includes('München') && s.includes('Ústí'));
  assert.ok(!s.includes(String.fromCharCode(92) + 'u'), 'keine \\uXXXX-Escapes');
});

test('4 — escaptes Anfuehrungszeichen bleibt korrekt', () => {
  // cities_BOL.json fuehrt "Colcha \"K\"" — der einzige Escape im Bestand.
  const raw = readFileSync(join(ECHT, 'cities_BOL.json'), 'utf8');
  assert.equal(serializeLikeSource(JSON.parse(raw)), raw);
  assert.ok(raw.includes(String.fromCharCode(92) + '"K' + String.fromCharCode(92) + '"'));
});

test('5 — Zahlen und Koordinaten bleiben textuell unveraendert', () => {
  for (const s of ['{"c": [11.573048, 48.131888]}', '{"c": [-0.5, 0]}', '{"c": [1e-7, 180]}']) {
    assert.equal(serializeLikeSource(JSON.parse(s)), s);
  }
  const raw = readFileSync(join(ECHT, 'cities_DEU.json'), 'utf8');
  assert.ok(raw.includes('[11.573048, 48.131888]'));
  assert.ok(serializeLikeSource(JSON.parse(raw)).includes('[11.573048, 48.131888]'));
});

test('6 — keine Zieldatei endet auf einen Zeilenumbruch', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-01')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.ok(!p.content.endsWith('\n'));
    assert.ok(!p.content.includes('\n'));
  } finally { weg(dir); }
});

// ── 2. Zuordnungsregeln ────────────────────────────────────────────────────

test('7 — unique ergaenzt genau einen Code, hinter SCALERANK', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-01')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.added, 1);
    assert.ok(p.changed);
    assert.ok(p.content.includes('"SCALERANK": 5, "iso_3166_2": "XX-01"'),
      'das Feld haengt hinten an, ohne umzuschichten');
    const keys = Object.keys(JSON.parse(p.content).features[0].properties);
    assert.deepEqual(keys, ['NAME', 'NAME_EN', 'SCALERANK', 'iso_3166_2']);
  } finally { weg(dir); }
});

test('8 — unresolved ergaenzt kein Feld', () => {
  const dir = fixture('XXX', [stadt('Draussen', 50, 50)], [quadrat('XX-01')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.added, 0);
    assert.equal(p.changed, false);
    assert.equal(p.counts.unresolved, 1);
    assert.ok(!p.content.includes('iso_3166_2'));
  } finally { weg(dir); }
});

test('9 — boundary ergaenzt kein Feld', () => {
  const dir = fixture('XXX', [stadt('Kante', 5, 0)], [quadrat('XX-01')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.counts.boundary, 1);
    assert.equal(p.added, 0);
    assert.ok(!p.content.includes('iso_3166_2'));
  } finally { weg(dir); }
});

test('10 — ambiguous ergaenzt kein Feld', () => {
  const dir = fixture('XXX', [stadt('Doppelt', 5, 5)], [quadrat('XX-01'), quadrat('XX-02')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.counts.ambiguous, 1);
    assert.equal(p.added, 0);
  } finally { weg(dir); }
});

test('11 — fehlender Regionsdatensatz ergaenzt kein Feld', () => {
  const dir = fixture('XXX', [stadt('Allein', 5, 5)], null);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.counts.missingRegionDataset, 1);
    assert.equal(p.added, 0);
    assert.equal(p.changed, false);
  } finally { weg(dir); }
});

test('12 — unbrauchbare Koordinate ergaenzt kein Feld', () => {
  const s = stadt('Kaputt', 5, 5);
  s.geometry.coordinates = ['x', null];
  const dir = fixture('XXX', [s], [quadrat('XX-01')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.counts.invalidCoordinates, 1);
    assert.equal(p.added, 0);
  } finally { weg(dir); }
});

test('13 — Tilde-Platzhalter ergaenzt kein Feld und wird nicht gekuerzt', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-X01~')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.added, 0);
    assert.ok(!p.content.includes('iso_3166_2'));
    assert.ok(!p.content.includes('XX-X01'), 'nichts abgeschnitten');
  } finally { weg(dir); }
});

test('14 — Unterstrich-Code ergaenzt kein Feld und wird nicht normalisiert', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-ABC_13')]);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.added, 0);
    assert.ok(!p.content.includes('iso_3166_2'));
    assert.ok(!p.content.includes('XX-ABC'), 'kein Abschneiden des Suffixes');
  } finally { weg(dir); }
});

test('15 — fremdes Landespraefix ergaenzt kein Feld', () => {
  // Mehrheitspraefix ist XX; das Gebiet, in dem die Stadt liegt, traegt YY.
  const regionen = [quadrat('YY-99'),
    { ...quadrat('XX-01'), geometry: { type: 'Polygon', coordinates: [[[20, 20], [30, 20], [30, 30], [20, 30], [20, 20]]] } },
    { ...quadrat('XX-02'), geometry: { type: 'Polygon', coordinates: [[[40, 40], [50, 40], [50, 50], [40, 50], [40, 40]]] } }];
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], regionen);
  try {
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.added, 0);
    assert.ok(!p.content.includes('YY-99'));
  } finally { weg(dir); }
});

// ── 3. Bestehende Felder ───────────────────────────────────────────────────

test('16 — ein vorhandenes korrektes Feld bleibt unveraendert', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5, 'XX-01')], [quadrat('XX-01')]);
  try {
    const vorher = lies(dir, 'cities_XXX.json');
    const p = planCityFileUpdate(dir, 'XXX');
    assert.equal(p.changed, false, 'nichts zu tun');
    assert.equal(p.added, 0);
    assert.equal(p.alreadyCorrect, 1);
    assert.equal(p.content, vorher);
    assert.equal((p.content.match(/iso_3166_2/g) ?? []).length, 1, 'kein doppeltes Property');
  } finally { weg(dir); }
});

test('17 — ein vorhandenes falsches Feld bricht ab', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5, 'XX-99')], [quadrat('XX-01')]);
  try {
    assert.throws(() => planCityFileUpdate(dir, 'XXX'), (e) =>
      e instanceof ApplyError && /XX-99/.test(e.message) && /XX-01/.test(e.message));
  } finally { weg(dir); }
});

test('18 — null bricht ab', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5, null)], [quadrat('XX-01')]);
  try {
    // stadt() setzt das Feld nur bei extra !== null, deshalb hier von Hand.
    const datei = join(dir, 'cities_XXX.json');
    const d = JSON.parse(readFileSync(datei, 'utf8'));
    d.features[0].properties.iso_3166_2 = null;
    writeFileSync(datei, serializeLikeSource(d), 'utf8');
    assert.throws(() => planCityFileUpdate(dir, 'XXX'), (e) =>
      e instanceof ApplyError && /null/.test(e.message));
  } finally { weg(dir); }
});

test('19 — ein leerer String bricht ab', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5, '')], [quadrat('XX-01')]);
  try {
    assert.throws(() => planCityFileUpdate(dir, 'XXX'), (e) =>
      e instanceof ApplyError && /leeren/.test(e.message));
  } finally { weg(dir); }
});

test('20 — ein Feld an einem nicht eindeutigen Ort bricht ab', () => {
  const dir = fixture('XXX', [stadt('Draussen', 50, 50, 'XX-01')], [quadrat('XX-01')]);
  try {
    assert.throws(() => planCityFileUpdate(dir, 'XXX'), (e) =>
      e instanceof ApplyError && /nicht eindeutig/.test(e.message));
  } finally { weg(dir); }
});

test('21 — eine nicht formattreu reproduzierbare Datei bricht ab', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w2gx-apply-'));
  try {
    // Eingerueckt geschrieben — der Rundlauf kann das nicht reproduzieren.
    writeFileSync(join(dir, 'cities_XXX.json'),
      JSON.stringify({ type: 'FeatureCollection', name: 'cities_XXX', features: [] }, null, 2), 'utf8');
    assert.throws(() => inspectCityFile(dir, 'XXX'), (e) =>
      e instanceof ApplyError && /formattreu/.test(e.message));
  } finally { weg(dir); }
});

// ── 4. Unversehrtheit ──────────────────────────────────────────────────────

test('22 — Reihenfolge, Geometrie und bestehende Properties bleiben', () => {
  const staedte = [stadt('Eins', 5, 5), stadt('Zwei', 50, 50), stadt('Drei', 6, 6)];
  const dir = fixture('XXX', staedte, [quadrat('XX-01')]);
  try {
    const vorher = JSON.parse(lies(dir, 'cities_XXX.json'));
    const p = planCityFileUpdate(dir, 'XXX');
    const nachher = JSON.parse(p.content);
    assert.equal(nachher.features.length, vorher.features.length);
    for (let i = 0; i < vorher.features.length; i++) {
      const a = vorher.features[i], b = nachher.features[i];
      assert.equal(a.properties.NAME, b.properties.NAME, 'Reihenfolge');
      assert.deepEqual(a.geometry, b.geometry, 'Geometrie');
      for (const k of ['NAME', 'NAME_EN', 'SCALERANK']) {
        assert.equal(a.properties[k], b.properties[k]);
      }
      assert.deepEqual(Object.keys(b.properties).slice(0, 3), ['NAME', 'NAME_EN', 'SCALERANK']);
    }
  } finally { weg(dir); }
});

test('23 — Rueckrechnung: entfernt man das Feld, entsteht das Original', () => {
  const dir = fixture('XXX', [stadt('Eins', 5, 5), stadt('Zwei', 50, 50)], [quadrat('XX-01')]);
  try {
    const original = lies(dir, 'cities_XXX.json');
    const p = planCityFileUpdate(dir, 'XXX');
    const zurueck = p.content.replace(/, "iso_3166_2": "[A-Z]{2}-[A-Z0-9]{1,3}"/g, '');
    assert.equal(zurueck, original, 'byte-identisch');
  } finally { weg(dir); }
});

// ── 5. Modi schreiben nichts ───────────────────────────────────────────────

test('24 — check und dry-run veraendern keine Datei', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-01')]);
  try {
    const vorher = schnappschuss(dir);
    const c = runCheck(dir);
    const d = runDryRun(dir);
    assert.equal(c.ok, false, 'ein fehlendes Feld -> nicht ok');
    assert.ok(d.text.includes('es wird nichts geschrieben'));
    assert.deepEqual(schnappschuss(dir), vorher, 'Inhalt und mtime unveraendert');
  } finally { weg(dir); }
});

test('25 — Argumente ohne Modus, widerspruechlich oder unbekannt', () => {
  assert.equal(parseArgs([]).error, 'kein Modus angegeben');
  assert.match(parseArgs(['--check', '--write']).error, /mehrere Modi/);
  assert.match(parseArgs(['--vernichte-alles']).error, /unbekannte Option/);
  assert.match(parseArgs(['--dry-run', '--limit', '-3']).error, /--limit/);
  // Kein Pfadparameter: ein solcher waere eine unbekannte Option.
  assert.match(parseArgs(['--write', '--geodata', '/etc']).error, /unbekannte Option/);
  assert.deepEqual(parseArgs(['--dry-run', '--limit', '5']), { mode: '--dry-run', limit: 5 });
});

test('26 — dry-run kappt die Pfadliste', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-01')]);
  try {
    assert.ok(runDryRun(dir, 0).text.includes('Pfade (0 von 1)'));
  } finally { weg(dir); }
});

// ── 6. Schreiben ───────────────────────────────────────────────────────────

test('27 — write aendert nur die erwarteten Staedtedateien', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5), stadt('Draussen', 50, 50)], [quadrat('XX-01')]);
  try {
    const regionVorher = schnappschuss(dir)['regions_XXX.json'];
    const r = runWrite(dir);
    assert.deepEqual(r.written, ['cities_XXX.json']);
    assert.equal(r.totals.added, 1);
    const nachher = JSON.parse(lies(dir, 'cities_XXX.json'));
    assert.equal(nachher.features[0].properties.iso_3166_2, 'XX-01');
    assert.equal(nachher.features[1].properties.iso_3166_2, undefined);
    const regionNachher = schnappschuss(dir)['regions_XXX.json'];
    assert.equal(regionNachher.inhalt, regionVorher.inhalt, 'Regionsdatei unberuehrt');
    assert.equal(regionNachher.mtime, regionVorher.mtime, 'nicht einmal angefasst');
  } finally { weg(dir); }
});

test('28 — ein zweiter Lauf ist byte-identisch', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-01')]);
  try {
    runWrite(dir);
    const nachErstem = schnappschuss(dir);
    const zweiter = runWrite(dir);
    assert.deepEqual(zweiter.written, [], 'nichts mehr zu schreiben');
    const nachZweitem = schnappschuss(dir);
    assert.equal(nachZweitem['cities_XXX.json'].inhalt, nachErstem['cities_XXX.json'].inhalt);
    assert.equal(nachZweitem['cities_XXX.json'].mtime, nachErstem['cities_XXX.json'].mtime,
      'die Datei wird nicht einmal neu geschrieben');
    assert.equal(runCheck(dir).ok, true);
  } finally { weg(dir); }
});

test('29 — ein Fehler in der LETZTEN Datei verhindert jede fruehere Aenderung', () => {
  // Das Herzstueck der Zweiphasigkeit.
  const dir = mkdtempSync(join(tmpdir(), 'w2gx-apply-'));
  try {
    const schreib = (n, o) => writeFileSync(join(dir, n), serializeLikeSource(o), 'utf8');
    const fc = (name, features) => ({ type: 'FeatureCollection', name, features });
    for (const iso of ['AAA', 'BBB', 'CCC']) {
      schreib(`regions_${iso}.json`, fc(`regions_${iso}`, [quadrat(iso.slice(0, 2) + '-01')]));
    }
    // AAA und BBB sind sauber, CCC traegt einen falschen Wert.
    schreib('cities_AAA.json', fc('cities_AAA', [stadt('A', 5, 5)]));
    schreib('cities_BBB.json', fc('cities_BBB', [stadt('B', 5, 5)]));
    schreib('cities_CCC.json', fc('cities_CCC', [stadt('C', 5, 5, 'CC-99')]));

    const vorher = schnappschuss(dir);
    assert.throws(() => runWrite(dir), (e) => e instanceof ApplyError && /CCC/.test(e.message));
    assert.deepEqual(schnappschuss(dir), vorher,
      'AAA und BBB duerfen NICHT geschrieben worden sein');
  } finally { weg(dir); }
});

test('30 — keine temporaere Datei bleibt liegen', () => {
  const dir = fixture('XXX', [stadt('Drin', 5, 5)], [quadrat('XX-01')]);
  try {
    runWrite(dir);
    assert.deepEqual(readdirSync(dir).filter((f) => f.endsWith('.tmp')), []);
  } finally { weg(dir); }
});

test('31 — applyPlannedUpdates schreibt nur Staedtedateien', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w2gx-apply-'));
  try {
    assert.throws(() => applyPlannedUpdates([
      { name: 'regions_XXX.json', path: join(dir, 'regions_XXX.json'), changed: true, content: 'x' },
    ]), (e) => e instanceof ApplyError && /kein Staedtedateiname/.test(e.message));
    assert.equal(existsSync(join(dir, 'regions_XXX.json')), false);
  } finally { weg(dir); }
});

// ── 7. Echter Bestand, ausschliesslich lesend ──────────────────────────────

test('32 — Planung ueber den echten Bestand liefert die erwarteten Zahlen', () => {
  const { totals } = planAllCityUpdates(ECHT);
  assert.deepEqual({
    files: totals.files, cities: totals.cities, added: totals.added,
    changedFiles: totals.changedFiles, alreadyCorrect: totals.alreadyCorrect,
    unique: totals.unique, unresolved: totals.unresolved, ambiguous: totals.ambiguous,
    boundary: totals.boundary, invalidCoordinates: totals.invalidCoordinates,
    missingRegionDataset: totals.missingRegionDataset,
  }, {
    files: 230, cities: 7342, added: 7103, changedFiles: 197, alreadyCorrect: 0,
    unique: 7103, unresolved: 173, ambiguous: 0, boundary: 1,
    invalidCoordinates: 0, missingRegionDataset: 65,
  });
});

test('33 — die Summe geht vollstaendig auf', () => {
  const { totals } = planAllCityUpdates(ECHT);
  const summe = totals.unique + totals.unresolved + totals.ambiguous +
                totals.boundary + totals.invalidCoordinates + totals.missingRegionDataset;
  assert.equal(summe, totals.cities);
});

test('34 — Rueckrechnung ueber den gesamten echten Bestand', () => {
  const { plans } = planAllCityUpdates(ECHT);
  for (const p of plans) {
    const original = readFileSync(join(ECHT, p.name), 'utf8');
    const zurueck = p.content.replace(/, "iso_3166_2": "[A-Z]{2}-[A-Z0-9]{1,3}"/g, '');
    assert.equal(zurueck, original, p.name);
  }
});

test('35 — Pflichtfaelle im geplanten Stand', () => {
  const { plans } = planAllCityUpdates(ECHT);
  const feld = (iso3, name) => {
    const p = plans.find((x) => x.iso3 === iso3);
    const t = JSON.parse(p.content).features.filter(
      (f) => f.properties.NAME === name || f.properties.NAME_EN === name);
    assert.equal(t.length, 1, `${name} in ${iso3}`);
    return t[0].properties.iso_3166_2;
  };
  assert.equal(feld('DEU', 'München'), 'DE-BY');
  assert.equal(feld('DEU', 'Nürnberg'), 'DE-BY');
  assert.equal(feld('DEU', 'Berlin'), 'DE-BE');
  assert.equal(feld('DEU', 'Hamburg'), 'DE-HH');
  assert.equal(feld('CZE', 'Brno'), 'CZ-JM');
  assert.notEqual(feld('CZE', 'Brno'), 'CZ-VY');
  assert.equal(feld('PRT', 'Viana do Castelo'), undefined, 'kein Feld');
  assert.equal(feld('ATA', 'Amundsen-Scott-Südpolstation'), undefined, 'kein Feld');
  const esp = plans.find((p) => p.iso3 === 'ESP');
  const mitFeld = JSON.parse(esp.content).features
    .filter((f) => f.properties.iso_3166_2 !== undefined);
  assert.equal(mitFeld.length, 0, 'Spanien bleibt ohne Regionscode');
  assert.equal(esp.changed, false);
});

test('36 — planAllCityUpdates laesst den echten Bestand unberuehrt', () => {
  const vorher = {};
  for (const iso3 of cityFilesIn(ECHT)) {
    const p = join(ECHT, `cities_${iso3}.json`);
    vorher[iso3] = { inhalt: readFileSync(p, 'utf8'), mtime: statSync(p).mtimeMs };
  }
  planAllCityUpdates(ECHT);
  runCheck(ECHT);
  runDryRun(ECHT);
  for (const iso3 of cityFilesIn(ECHT)) {
    const p = join(ECHT, `cities_${iso3}.json`);
    assert.equal(readFileSync(p, 'utf8'), vorher[iso3].inhalt, `${iso3} Inhalt`);
    assert.equal(statSync(p).mtimeMs, vorher[iso3].mtime, `${iso3} mtime`);
  }
});

// ── 8. Abgrenzung ──────────────────────────────────────────────────────────

test('37 — das Auditwerkzeug bleibt frei von Schreiboperationen', () => {
  const quelle = readFileSync('tools/assign-city-regions.mjs', 'utf8');
  for (const v of ['writeFile', 'appendFile', 'renameSync', 'unlink', 'mkdir', 'fetch(']) {
    assert.ok(!quelle.includes(v), `"${v}" darf im Auditwerkzeug nicht stehen`);
  }
});

test('38 — das Schreibwerkzeug rechnet nicht selbst und laedt nichts', () => {
  const quelle = readFileSync('tools/apply-city-region-codes.mjs', 'utf8');
  // Keine zweite Punkt-in-Polygon-Rechnung: die Geometrie kommt aus dem Audit.
  for (const v of ['function pointInRing', 'function pointInPolygon',
                   'function pointInFeature', 'function pointOnSegment']) {
    assert.ok(!quelle.includes(v), `"${v}" gehoert ins Auditwerkzeug, nicht hierher`);
  }
  assert.ok(quelle.includes("from './assign-city-regions.mjs'"), 'nutzt die geprueften Funktionen');
  for (const v of ['fetch(', 'http', 'child_process', 'ADM1NAME', 'nearest', 'haversine']) {
    assert.ok(!quelle.includes(v), `"${v}" darf nicht vorkommen`);
  }
  assert.deepEqual([...new Set(quelle.match(/from '[^']+'/g))].sort(),
    ["from './assign-city-regions.mjs'", "from 'node:fs'", "from 'node:path'"],
    'keine externe Abhaengigkeit');
});

test('39 — das Zielverzeichnis ist fest verdrahtet', () => {
  assert.ok(GEODATA_DIR.endsWith('geodata'));
  const quelle = readFileSync('tools/apply-city-region-codes.mjs', 'utf8');
  assert.ok(!quelle.includes("'--geodata'"), 'kein Pfadparameter in der CLI');
});
