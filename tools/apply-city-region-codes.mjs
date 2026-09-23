// Schreibt die geometrisch ermittelten Regionscodes in die Staedtedateien.
//
// Getrennt von `assign-city-regions.mjs`, und das mit Absicht: das Auditwerkzeug
// bleibt dauerhaft rein lesend. Es gibt hier **keine** zweite
// Punkt-in-Polygon-Rechnung — `assignRegion`, `countryPrefix` und
// `validRegionCode` kommen unveraendert von dort.
//
//   node tools/apply-city-region-codes.mjs --check      # prueft, schreibt nie
//   node tools/apply-city-region-codes.mjs --dry-run    # zeigt, schreibt nie
//   node tools/apply-city-region-codes.mjs --write      # schreibt
//
// Das Verzeichnis ist fest verdrahtet: `geodata/` neben diesem Werkzeug. Es
// gibt bewusst keinen Pfadparameter — ein Werkzeug, das beliebige Verzeichnisse
// ueberschreiben kann, ist ein Werkzeug, mit dem man sich vertut. Tests rufen
// stattdessen die exportierten Funktionen mit einem eigenen Verzeichnis auf.
//
// **Zweiphasig.** Erst wird der gesamte Bestand geplant und geprueft, dann
// wird geschrieben. Ein Fehler in Datei 230 darf die Dateien 1 bis 229 nicht
// schon veraendert haben.

import { readFileSync, writeFileSync, readdirSync, renameSync, unlinkSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

import {
  assignRegion, countryPrefix, validRegionCode,
  REGION_CODE_PROPERTY, STATUS,
} from './assign-city-regions.mjs';

/// Das Datenverzeichnis dieses Repositorys. Fest, nicht ueberschreibbar.
export const GEODATA_DIR = join(dirname(import.meta.dirname), 'geodata');

/// Nur diese Dateien darf das Werkzeug anfassen.
const CITY_FILE = /^cities_([A-Z]{3})\.json$/;

/// Ein fachlicher oder struktureller Abbruch. Traegt die Datei, an der es lag.
export class ApplyError extends Error {
  constructor(file, reason) {
    super(`${file}: ${reason}`);
    this.name = 'ApplyError';
    this.file = file;
    this.reason = reason;
  }
}

// ── Serialisierung ─────────────────────────────────────────────────────────

/// Serialisiert wie die Quelldateien geschrieben sind.
///
/// Die Staedtedateien stammen aus Pythons `json.dump`: alles auf einer Zeile,
/// `", "` zwischen Eintraegen, `": "` hinter Schluesseln, kein abschliessender
/// Zeilenumbruch, Unicode direkt als UTF-8.
///
/// Skalare laufen durch `JSON.stringify` — damit sind Zahlendarstellung und
/// Escaping exakt die von JavaScript. Dass das genuegt, ist keine Annahme: der
/// Rundlauf reproduziert jede der 230 Dateien byteweise, und genau das wird
/// vor jedem Schreibvorgang erneut geprueft.
export function serializeLikeSource(value) {
  if (Array.isArray(value)) {
    return '[' + value.map(serializeLikeSource).join(', ') + ']';
  }
  if (value !== null && typeof value === 'object') {
    return '{' + Object.entries(value)
      .map(([k, v]) => JSON.stringify(k) + ': ' + serializeLikeSource(v))
      .join(', ') + '}';
  }
  return JSON.stringify(value);
}

// ── Lesen und pruefen ──────────────────────────────────────────────────────

/// Liest eine Staedtedatei und stellt sicher, dass sie formattreu
/// reproduzierbar ist.
///
/// Ist sie das nicht, wird sie **nicht** angefasst — dann wuerde ein Schreiben
/// mehr aendern als das eine neue Feld, und das waere unbemerkt.
export function inspectCityFile(geodataDir, iso3) {
  const name = `cities_${iso3}.json`;
  const raw = readFileSync(join(geodataDir, name), 'utf8');
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    throw new ApplyError(name, `kein gueltiges JSON (${e.message})`);
  }
  if (serializeLikeSource(data) !== raw) {
    throw new ApplyError(name,
      'laesst sich nicht formattreu reproduzieren — Schreiben wuerde mehr '
      + 'aendern als das neue Feld');
  }
  return { name, raw, data };
}

/// Die Regionen eines Landes, oder `null`, wenn es keine Datei gibt.
function regionsOf(geodataDir, iso3) {
  const path = join(geodataDir, `regions_${iso3}.json`);
  if (!existsSync(path)) return null;
  const parsed = JSON.parse(readFileSync(path, 'utf8'));
  return Array.isArray(parsed?.features) ? parsed.features : null;
}

/// Die ISO3-Kuerzel aller Staedtedateien eines Verzeichnisses, sortiert.
export function cityFilesIn(geodataDir) {
  return readdirSync(geodataDir)
    .map((f) => CITY_FILE.exec(f))
    .filter(Boolean)
    .map((m) => m[1])
    .sort();
}

// ── Phase A: planen ────────────────────────────────────────────────────────

/// Plant die Aenderung **einer** Datei, ohne etwas zu schreiben.
///
/// Wirft bei jedem Zustand, den dieses Werkzeug nicht selbst verursacht haben
/// kann. Ein falscher, leerer oder `null`-Wert wird ausdruecklich **nicht**
/// repariert: wer ihn hineingeschrieben hat, muss ihn auch erklaeren.
export function planCityFileUpdate(geodataDir, iso3) {
  const { name, raw, data } = inspectCityFile(geodataDir, iso3);
  const regions = regionsOf(geodataDir, iso3);
  const prefix = regions ? countryPrefix(regions) : null;

  const counts = { unique: 0, unresolved: 0, ambiguous: 0, boundary: 0,
                   invalidCoordinates: 0, missingRegionDataset: 0 };
  let added = 0, alreadyCorrect = 0;

  for (const feature of data.features) {
    const props = feature.properties ?? {};
    const vorhanden = Object.hasOwn(props, REGION_CODE_PROPERTY)
      ? props[REGION_CODE_PROPERTY] : undefined;

    // Was waere der richtige Wert?
    let code = null;
    if (!regions) {
      counts.missingRegionDataset++;
    } else {
      const co = feature.geometry?.coordinates;
      const brauchbar = Array.isArray(co) && co.length >= 2 &&
        typeof co[0] === 'number' && typeof co[1] === 'number' &&
        Number.isFinite(co[0]) && Number.isFinite(co[1]);
      if (!brauchbar) {
        counts.invalidCoordinates++;
      } else {
        const ergebnis = assignRegion(co, regions, prefix);
        counts[ergebnis.status]++;
        if (ergebnis.status === STATUS.unique) {
          // Doppelter Boden: assignRegion filtert bereits, hier wird es
          // nochmals verlangt, bevor irgendetwas in die Daten geht.
          if (!validRegionCode(ergebnis.code, prefix)) {
            throw new ApplyError(name,
              `berechneter Code "${ergebnis.code}" ist ungueltig fuer Praefix "${prefix}"`);
          }
          code = ergebnis.code;
        }
      }
    }

    const ort = props.NAME ?? props.NAME_EN ?? '(ohne Namen)';

    if (vorhanden === undefined) {
      if (code !== null) { props[REGION_CODE_PROPERTY] = code; added++; }
      continue;
    }
    // Ab hier gibt es bereits ein Feld.
    if (vorhanden === null) {
      throw new ApplyError(name, `"${ort}" traegt ${REGION_CODE_PROPERTY}: null`);
    }
    if (vorhanden === '') {
      throw new ApplyError(name, `"${ort}" traegt einen leeren ${REGION_CODE_PROPERTY}`);
    }
    if (code === null) {
      throw new ApplyError(name,
        `"${ort}" traegt ${REGION_CODE_PROPERTY} "${vorhanden}", ist aber nicht eindeutig zuordenbar`);
    }
    if (vorhanden !== code) {
      throw new ApplyError(name,
        `"${ort}" traegt ${REGION_CODE_PROPERTY} "${vorhanden}", berechnet wurde "${code}"`);
    }
    alreadyCorrect++;
  }

  const zielInhalt = serializeLikeSource(data);
  return {
    iso3, name, path: join(geodataDir, name),
    changed: zielInhalt !== raw,
    content: zielInhalt,
    added, alreadyCorrect, counts,
    total: data.features.length,
  };
}

/// Phase A ueber den gesamten Bestand.
///
/// Erst wenn **alle** Dateien fehlerfrei geplant sind, darf Phase B laufen.
export function planAllCityUpdates(geodataDir) {
  const plans = cityFilesIn(geodataDir).map((iso3) => planCityFileUpdate(geodataDir, iso3));
  const totals = { files: plans.length, changedFiles: 0, added: 0, alreadyCorrect: 0,
                   cities: 0, unique: 0, unresolved: 0, ambiguous: 0, boundary: 0,
                   invalidCoordinates: 0, missingRegionDataset: 0 };
  for (const p of plans) {
    if (p.changed) totals.changedFiles++;
    totals.added += p.added;
    totals.alreadyCorrect += p.alreadyCorrect;
    totals.cities += p.total;
    for (const k of Object.keys(p.counts)) totals[k] += p.counts[k];
  }
  return { plans, totals };
}

// ── Phase B: schreiben ─────────────────────────────────────────────────────

/// Schreibt die in Phase A festgelegten Inhalte. Rechnet nichts mehr nach.
///
/// Je Datei: temporaere Schwesterdatei, zurueckgelesen und verglichen, dann
/// atomar umbenannt. Schlaegt etwas fehl, wird die temporaere Datei entfernt.
export function applyPlannedUpdates(plans) {
  const geschrieben = [];
  for (const plan of plans) {
    if (!plan.changed) continue;
    if (!CITY_FILE.test(plan.name)) {
      throw new ApplyError(plan.name, 'kein Staedtedateiname — wird nicht geschrieben');
    }
    const tmp = plan.path + '.tmp';
    try {
      writeFileSync(tmp, plan.content, 'utf8');
      if (readFileSync(tmp, 'utf8') !== plan.content) {
        throw new ApplyError(plan.name, 'temporaere Datei stimmt nicht mit dem geplanten Inhalt ueberein');
      }
      renameSync(tmp, plan.path);
      geschrieben.push(plan.name);
    } catch (e) {
      try { if (existsSync(tmp)) unlinkSync(tmp); } catch { /* Aufraeumen darf nicht maskieren */ }
      throw new Error(
        `Schreiben abgebrochen bei ${plan.name}: ${e.message}\n`
        + `ACHTUNG: ${geschrieben.length} Datei(en) wurden bereits geschrieben. `
        + `Die fachliche Pruefung war vollstaendig; dies ist ein Datei- oder `
        + `Datentraegerfehler. Stand pruefen mit: git status, git diff --stat`);
    }
  }
  return geschrieben;
}

// ── Modi ───────────────────────────────────────────────────────────────────

const z = (v, n) => String(v).padStart(n);

function statusZeilen(t) {
  return [
    `  Staedte                   ${z(t.cities, 6)}`,
    `  unique                    ${z(t.unique, 6)}`,
    `  unresolved                ${z(t.unresolved, 6)}`,
    `  ambiguous                 ${z(t.ambiguous, 6)}`,
    `  boundary                  ${z(t.boundary, 6)}`,
    `  invalid coordinates       ${z(t.invalidCoordinates, 6)}`,
    `  missing region dataset    ${z(t.missingRegionDataset, 6)}`,
  ];
}

/// Prueft, ob die Daten bereits vollstaendig und richtig sind. Schreibt nie.
export function runCheck(geodataDir) {
  const { plans, totals } = planAllCityUpdates(geodataDir);
  const fehlend = plans.filter((p) => p.changed);
  const out = ['PRUEFUNG', ''];
  out.push(`  Staedtedateien            ${z(totals.files, 6)}`);
  out.push(`  bereits korrekt gesetzt   ${z(totals.alreadyCorrect, 6)}`);
  out.push(`  fehlende Felder           ${z(totals.added, 6)}`);
  out.push(`  betroffene Dateien        ${z(fehlend.length, 6)}`);
  out.push('', ...statusZeilen(totals), '');
  out.push(fehlend.length === 0
    ? '  Ergebnis: alle erwarteten Felder sind gesetzt.'
    : `  Ergebnis: ${totals.added} Feld(er) in ${fehlend.length} Datei(en) fehlen.`);
  return { ok: fehlend.length === 0, text: out.join('\n'), totals };
}

/// Zeigt, was `--write` taete. Schreibt nie.
export function runDryRun(geodataDir, limit = 20) {
  const { plans, totals } = planAllCityUpdates(geodataDir);
  const zuAendern = plans.filter((p) => p.changed);
  const out = ['PROBELAUF — es wird nichts geschrieben', ''];
  out.push(`  zu aendernde Dateien      ${z(zuAendern.length, 6)}`);
  out.push(`  unveraenderte Dateien     ${z(totals.files - zuAendern.length, 6)}`);
  out.push(`  neue Felder               ${z(totals.added, 6)}`);
  out.push(`  bereits korrekt           ${z(totals.alreadyCorrect, 6)}`);
  out.push('', ...statusZeilen(totals), '');
  out.push(`  Pfade (${Math.min(limit, zuAendern.length)} von ${zuAendern.length}):`);
  for (const p of zuAendern.slice(0, limit)) {
    out.push(`    geodata/${p.name}  +${p.added}`);
  }
  if (zuAendern.length > limit) {
    out.push(`    ... ${zuAendern.length - limit} weitere (--limit erhoeht die Liste)`);
  }
  return { text: out.join('\n'), totals, files: zuAendern.map((p) => p.name) };
}

/// Zweiphasig: erst den gesamten Bestand planen, dann schreiben.
export function runWrite(geodataDir) {
  const { plans, totals } = planAllCityUpdates(geodataDir);   // Phase A
  const geschrieben = applyPlannedUpdates(plans);             // Phase B
  const out = ['GESCHRIEBEN', ''];
  out.push(`  geaenderte Dateien        ${z(geschrieben.length, 6)}`);
  out.push(`  neue Felder               ${z(totals.added, 6)}`);
  out.push('', ...statusZeilen(totals));
  return { text: out.join('\n'), written: geschrieben, totals };
}

// ── CLI ────────────────────────────────────────────────────────────────────

const HILFE = [
  'Schreibt die geometrisch ermittelten Regionscodes in geodata/cities_*.json.',
  '',
  '  --check      prueft den Bestand, schreibt nichts',
  '  --dry-run    zeigt die geplanten Aenderungen, schreibt nichts',
  '  --write      fuehrt die Aenderungen aus',
  '  --limit N    nur fuer --dry-run: Laenge der Pfadliste (Standard 20)',
  '',
  'Genau ein Modus muss angegeben werden.',
].join('\n');

export function parseArgs(argv) {
  const modi = [];
  let limit = 20;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--check' || a === '--dry-run' || a === '--write') modi.push(a);
    else if (a === '--limit') {
      const n = Number(argv[++i]);
      if (!Number.isInteger(n) || n < 0) return { error: '--limit erwartet eine nicht negative ganze Zahl' };
      limit = n;
    } else return { error: `unbekannte Option: ${a}` };
  }
  if (modi.length === 0) return { error: 'kein Modus angegeben' };
  if (modi.length > 1) return { error: `mehrere Modi angegeben: ${modi.join(' ')}` };
  return { mode: modi[0], limit };
}

function main(argv) {
  const args = parseArgs(argv);
  if (args.error) {
    process.stderr.write(args.error + '\n\n' + HILFE + '\n');
    process.exitCode = 2;
    return;
  }
  try {
    if (args.mode === '--check') {
      const r = runCheck(GEODATA_DIR);
      process.stdout.write(r.text + '\n');
      process.exitCode = r.ok ? 0 : 1;
      return;
    }
    if (args.mode === '--dry-run') {
      process.stdout.write(runDryRun(GEODATA_DIR, args.limit).text + '\n');
      return;
    }
    process.stdout.write(runWrite(GEODATA_DIR).text + '\n');
  } catch (e) {
    process.stderr.write('ABBRUCH — es wurde nichts geaendert, sofern nicht anders vermerkt.\n'
      + e.message + '\n');
    process.exitCode = 3;
  }
}

if (import.meta.filename === process.argv[1]) main(process.argv.slice(2));
