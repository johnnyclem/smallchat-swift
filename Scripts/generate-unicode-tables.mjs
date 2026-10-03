#!/usr/bin/env node
// Generates SmallChatTruth's Unicode 16.0.0 tables, and the vectors that
// check them against the ICU that stenographer and short-hand compute
// identity keys with.
//
//   node Scripts/generate-unicode-tables.mjs [<directory holding the UCD 16.0.0 files>]
//
// Identity keys (truth format v2, "Identities") are Unicode NFKC, default-
// ignorable code points removed, trimmed, lowercased. Stenographer and
// short-hand compute them with their runtime's ICU: on Node 22, ICU 77.1,
// which is Unicode 16.0. Foundation's normalization on Linux is Unicode
// 15.x, and the Swift runtime's character properties are whatever its
// version (or, on Apple platforms, the OS) ships, so SmallChatTruth carries
// the Unicode 16.0 data it needs:
//
// - Sources/SmallChatTruth/UnicodeTables16.swift, from the Unicode Character
//   Database 16.0.0 (UnicodeData.txt, DerivedNormalizationProps.txt,
//   DerivedCoreProperties.txt, SpecialCasing.txt). The files are read from
//   the directory given, or downloaded from unicode.org, and must match the
//   SHA-256s below.
// - Tests/Fixtures/unicode-16/identity-keys.json, computed by this Node's
//   ICU, which must be Unicode 16.0 (Node 22): stenographer's identityKey of
//   every code point, NFC's primary composites, the canonical combining
//   classes as NFD orders them, the classes toLowerCase's Final_Sigma rule
//   reads, and a set of strings. TruthUnicodeTests holds the tables to them.
//
// Review the diff, then run `swift test --filter TruthUnicode`.
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const tablesPath = join(root, 'Sources/SmallChatTruth/UnicodeTables16.swift');
const vectorsPath = join(root, 'Tests/Fixtures/unicode-16/identity-keys.json');

const UCD_URL = 'https://www.unicode.org/Public/16.0.0/ucd/';
const UCD_FILES = {
  'UnicodeData.txt': 'ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f',
  'DerivedNormalizationProps.txt': '4d4c03892dea9146d674b686e495df2d55a28d071ac474041d73518f887abddc',
  'DerivedCoreProperties.txt': '39d35161f2954497f69e08bdb9e701493f476a3d30222de20028feda36c1dabd',
  'SpecialCasing.txt': '8d5de354eef79f2395a54c9c7dcebbaf3d30fc962d0f85611ea97aa973a0c451',
};

if (process.versions.unicode !== '16.0') {
  console.error(`error: this Node's ICU ${process.versions.icu} is Unicode ${process.versions.unicode}; the vectors need Unicode 16.0 (Node 22)`);
  process.exit(1);
}

// ── The UCD files ─────────────────────────────────────────────

async function ucdFile(name) {
  let text;
  const dir = process.argv[2];
  if (dir) {
    text = readFileSync(join(dir, name));
  } else {
    const response = await fetch(UCD_URL + name);
    if (!response.ok) throw new Error(`GET ${UCD_URL}${name}: ${response.status}`);
    text = Buffer.from(await response.arrayBuffer());
  }
  const sha = createHash('sha256').update(text).digest('hex');
  if (sha !== UCD_FILES[name]) throw new Error(`${name} has SHA-256 ${sha}, not Unicode 16.0.0's ${UCD_FILES[name]}`);
  return text.toString('utf8');
}

/** Each data line's fields, comments and blank lines dropped. */
function records(text) {
  return text
    .split('\n')
    .map((line) => line.replace(/#.*/, '').trim())
    .filter((line) => line.length > 0)
    .map((line) => line.split(';').map((field) => field.trim()));
}

/** `XXXX` or `XXXX..YYYY` as [first, last]. */
function range(field) {
  const [a, b] = field.split('..');
  return [parseInt(a, 16), parseInt(b ?? a, 16)];
}

/** The code points a derived property file lists for `property`, as sorted, merged ranges. */
function propertyRanges(text, property) {
  const ranges = records(text)
    .filter((f) => f[1] === property)
    .map((f) => range(f[0]))
    .sort((x, y) => x[0] - y[0]);
  return mergeRanges(ranges);
}

function mergeRanges(ranges) {
  const merged = [];
  for (const [a, b] of ranges) {
    const last = merged[merged.length - 1];
    if (last && a <= last[1] + 1) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  }
  return merged;
}

/** Sorted code points as merged ranges. */
function rangesOf(codePoints) {
  return mergeRanges(codePoints.map((c) => [c, c]));
}

const unicodeData = records(await ucdFile('UnicodeData.txt'));
const normalizationProps = await ucdFile('DerivedNormalizationProps.txt');
const coreProps = await ucdFile('DerivedCoreProperties.txt');
const specialCasing = records(await ucdFile('SpecialCasing.txt'));

// ── Tables from the UCD ───────────────────────────────────────

const ccc = new Map(); // code point → nonzero canonical combining class
const mapping = new Map(); // code point → { compat, to } (one level)
const lowercase = new Map(); // code point → full lowercase mapping, where it isn't the code point
for (const f of unicodeData) {
  const cp = parseInt(f[0], 16);
  // A `<…, First>`/`<…, Last>` range (CJK ideographs, Hangul syllables, Tangut, …) has class 0,
  // no decomposition mapping (Hangul syllables decompose by algorithm) and no case mapping
  if (Number(f[3]) !== 0) ccc.set(cp, Number(f[3]));
  if (f[5]) {
    const compat = f[5].startsWith('<');
    const to = f[5].replace(/^<[^>]*>\s*/, '').split(' ').map((h) => parseInt(h, 16));
    mapping.set(cp, { compat, to });
  }
  if (f[13]) lowercase.set(cp, [parseInt(f[13], 16)]);
}
// SpecialCasing's unconditional, language-independent mappings override the simple ones
// (U+0130 lowercases to i + U+0307). Final_Sigma, the one conditional mapping that isn't
// language-specific, is the code's; the language-specific ones (lt, tr, az) don't apply.
for (const f of specialCasing) {
  if (f.length > 5 && f[4] !== '') continue;
  const cp = parseInt(f[0], 16);
  const lower = f[1].split(' ').map((h) => parseInt(h, 16));
  if (lower.length === 1 && lower[0] === cp) lowercase.delete(cp);
  else lowercase.set(cp, lower);
}

function fullDecomposition(cp, compat) {
  const m = mapping.get(cp);
  if (!m || (m.compat && !compat)) return [cp];
  return m.to.flatMap((c) => fullDecomposition(c, compat));
}

const canonical = []; // [cp, full canonical decomposition]
const compatibility = []; // [cp, full compatibility decomposition], where it differs from the canonical one
for (const cp of [...mapping.keys()].sort((a, b) => a - b)) {
  const nfd = fullDecomposition(cp, false);
  const nfkd = fullDecomposition(cp, true);
  if (nfd.length !== 1 || nfd[0] !== cp) canonical.push([cp, nfd]);
  if (nfkd.join() !== nfd.join()) compatibility.push([cp, nfkd]);
}

// Primary composites: a canonical mapping to two code points, not excluded from composition
const excluded = new Set();
for (const [a, b] of propertyRanges(normalizationProps, 'Full_Composition_Exclusion')) {
  for (let c = a; c <= b; c++) excluded.add(c);
}
const compositions = []; // [first, second, composite]
for (const [cp, m] of [...mapping.entries()].sort((x, y) => x[0] - y[0])) {
  if (m.compat || m.to.length !== 2 || excluded.has(cp)) continue;
  compositions.push([m.to[0], m.to[1], cp]);
}

const defaultIgnorable = propertyRanges(coreProps, 'Default_Ignorable_Code_Point');
const cased = propertyRanges(coreProps, 'Cased');
const caseIgnorable = propertyRanges(coreProps, 'Case_Ignorable');

// ── UnicodeTables16.swift ─────────────────────────────────────

const hex = (n) => n.toString(16).toUpperCase();

/** Space-separated entries, wrapped into the lines of a Swift multi-line string literal. */
function literal(entries) {
  const lines = [];
  let line = '';
  for (const entry of entries) {
    if (line.length > 0 && line.length + 1 + entry.length > 104) {
      lines.push(line);
      line = '';
    }
    line += (line.length > 0 ? ' ' : '') + entry;
  }
  if (line.length > 0) lines.push(line);
  return `"""\n${lines.map((l) => `        ${l}`).join('\n')}\n        """`;
}

const rangeEntry = ([a, b]) => (a === b ? hex(a) : `${hex(a)}-${hex(b)}`);

/** Runs of consecutive code points with the same class: `first-last:class`. */
function classEntries() {
  const runs = [];
  for (const cp of [...ccc.keys()].sort((a, b) => a - b)) {
    const last = runs[runs.length - 1];
    if (last && last[1] === cp - 1 && last[2] === ccc.get(cp)) last[1] = cp;
    else runs.push([cp, cp, ccc.get(cp)]);
  }
  return runs.map(([a, b, k]) => `${rangeEntry([a, b])}:${k}`);
}

/**
 * `cp:t1,t2,…` for each [cp, [t1, t2, …]], sorted by code point. Three or more code points in a
 * row, or every other one, that each map to one code point the same distance away are one entry:
 * `A-B:T` maps A+i to T+i, and `A-B/2:T` maps A+2i to T+2i.
 */
function mappingEntries(list) {
  const out = [];
  for (let i = 0; i < list.length; ) {
    const [cp, to] = list[i];
    let run = null;
    for (const step of [1, 2]) {
      let j = i;
      while (
        j + 1 < list.length &&
        to.length === 1 &&
        list[j + 1][1].length === 1 &&
        list[j + 1][0] === list[j][0] + step &&
        list[j + 1][1][0] - list[j + 1][0] === to[0] - cp
      ) {
        j++;
      }
      if (j - i >= 2 && (!run || j > run.last)) run = { last: j, step };
    }
    if (run) {
      out.push(`${hex(cp)}-${hex(list[run.last][0])}${run.step === 2 ? '/2' : ''}:${hex(to[0])}`);
      i = run.last + 1;
    } else {
      out.push(`${hex(cp)}:${to.map(hex).join(',')}`);
      i++;
    }
  }
  return out;
}

const swift = `// Generated by Scripts/generate-unicode-tables.mjs from the Unicode Character
// Database 16.0.0 (${UCD_URL}):
// ${Object.keys(UCD_FILES).join(', ')}.
// Do not edit: re-run the script.
//
// Every table is a list of space-separated entries, code points in hex.
// \`A-B\` is the range A through B. In the three mapping tables, \`A-B:T\`
// maps A+i to T+i, and \`A-B/2:T\` maps every other code point, A+2i, to
// T+2i. Read by Unicode16 (Unicode16.swift).

extension Unicode16 {
    /// The Unicode version of these tables.
    static let version = "16.0.0"

    /// \`cp:d1,d2,…\`: the full canonical decomposition of every code point
    /// that has one (Hangul syllables decompose by algorithm instead).
    static let canonicalDecompositionTable = ${literal(mappingEntries(canonical))}

    /// \`cp:d1,d2,…\`: the full compatibility decomposition of every code point
    /// whose compatibility decomposition isn't its canonical one.
    static let compatibilityDecompositionTable = ${literal(mappingEntries(compatibility))}

    /// \`A-B:class\`: every code point whose canonical combining class isn't 0.
    static let combiningClassTable = ${literal(classEntries())}

    /// \`first,second:composite\`: the primary composites, by the pair NFC composes.
    static let compositionTable = ${literal(compositions.map(([a, b, p]) => `${hex(a)},${hex(b)}:${hex(p)}`))}

    /// \`cp:l1,l2,…\`: the full lowercase mapping of every code point whose
    /// mapping isn't itself, Final_Sigma aside (UnicodeData.txt, overridden by
    /// SpecialCasing.txt's unconditional mappings).
    static let lowercaseTable = ${literal(mappingEntries([...lowercase.entries()].sort((a, b) => a[0] - b[0])))}

    /// Default_Ignorable_Code_Point.
    static let defaultIgnorableTable = ${literal(defaultIgnorable.map(rangeEntry))}

    /// Cased.
    static let casedTable = ${literal(cased.map(rangeEntry))}

    /// Case_Ignorable.
    static let caseIgnorableTable = ${literal(caseIgnorable.map(rangeEntry))}
}
`;
writeFileSync(tablesPath, swift);

// ── identity-keys.json, from this Node's ICU ──────────────────

/** Stenographer's identityKey (src/truth/types.ts), verbatim. */
function identityKey(identity) {
  return identity
    .normalize('NFKC')
    .replace(/\p{Default_Ignorable_Code_Point}/gu, '')
    .trim()
    .toLowerCase();
}

const scalars = (s) => [...s].map((c) => c.codePointAt(0));
const hexes = (s) => scalars(s).map(hex).join(' ');
const codePoints = function* () {
  for (let cp = 0; cp <= 0x10ffff; cp++) if (cp < 0xd800 || cp > 0xdfff) yield cp;
};

const keys = [];
const removed = [];
for (const cp of codePoints()) {
  const s = String.fromCodePoint(cp);
  const key = identityKey(s);
  if (key === '') removed.push(cp);
  else if (key !== s) keys.push([cp, scalars(key)]);
}

// NFC's primary composites: code points with a canonical decomposition that NFC composes back.
// Hangul syllables are left out: they compose by algorithm, and the strings below cover them.
const composites = [];
for (const cp of codePoints()) {
  if (cp >= 0xac00 && cp <= 0xd7a3) continue;
  const s = String.fromCodePoint(cp);
  const nfd = s.normalize('NFD');
  if (nfd !== s && nfd.normalize('NFC') === s) composites.push(cp);
}

// Canonical combining classes as NFD orders marks: for two code points NFD leaves alone, NFD
// swaps x y exactly when class(x) > class(y) > 0. U+0345 has class 240, the highest, and U+0334
// class 1, the lowest, so a code point's class is nonzero exactly when NFD swaps it after U+0345
// or before U+0334. Each nonzero class is named by its lowest code point, found by comparison.
const swaps = (x, y) => (x + y).normalize('NFD') === y + x;
const marks = [];
for (const cp of codePoints()) {
  const s = String.fromCodePoint(cp);
  if (s.normalize('NFD') !== s) continue;
  if (swaps('ͅ', s) || swaps(s, '̴')) marks.push(cp);
}
const classNames = [];
const classes = []; // [first, last, the lowest code point of the class]
for (const cp of marks) {
  const s = String.fromCodePoint(cp);
  let name = classNames.find((n) => !swaps(s, String.fromCodePoint(n)) && !swaps(String.fromCodePoint(n), s));
  if (name === undefined) {
    name = cp;
    classNames.push(cp);
  }
  const last = classes[classes.length - 1];
  if (last && last[1] === cp - 1 && last[2] === name) last[1] = cp;
  else classes.push([cp, cp, name]);
}

// The classes toLowerCase's Final_Sigma rule reads: Σ is ς after a cased letter, when no cased
// letter follows, case-ignorable code points skipped both ways. So in AΣx, Σ is σ exactly when x
// is cased and not case-ignorable; in AΣxA, exactly when x is either.
// Read backwards (xΣ and AxΣ, Σ last) the classes must be the same.
const sigmaFollowed = (x, tail) => ('AΣ' + x + tail).toLowerCase()[1] === 'σ';
const sigmaPreceded = (head, x) => (head + x + 'Σ').toLowerCase().endsWith('ς');
const ignorable = [];
const casedOnly = [];
for (const cp of codePoints()) {
  const s = String.fromCodePoint(cp);
  const isCasedOnly = sigmaFollowed(s, '');
  const isIgnorable = !isCasedOnly && sigmaFollowed(s, 'A');
  if (sigmaPreceded('', s) !== isCasedOnly || sigmaPreceded('A', s) !== (isCasedOnly || isIgnorable)) {
    throw new Error(`U+${hex(cp)}: toLowerCase reads its case class differently before and after a sigma`);
  }
  if (isCasedOnly) casedOnly.push(cp);
  else if (isIgnorable) ignorable.push(cp);
}

// Strings: compositions, reordering, Hangul, Final_Sigma and the default-ignorables in context
const strings = [
  'agent:\u{113C2}\u{113C2}',
  'agent:\u{105D2}\u{0307}',
  'agent:\u{16D63}\u{16D67}\u{16D67}',
  'agent:\u{1611E}\u{1611E}\u{1611F}',
  'agent:a\u{0897}\u{0316}',
  'agent:a\u{1E5EE}\u{1E5EF}',
  'agent:a\u{0316}\u{034F}\u{0301}',
  'agent:\u{00E1}\u{0316}',
  'agent:A\u{0323}\u{0302}\u{0301}',
  'agent:\u{1E9B}\u{0323}',
  'agent:\u{0344}',
  'agent:\u{0F73}\u{0F71}',
  'agent:\u{1100}\u{1161}\u{11A8}',
  'agent:\u{AC00}\u{11A8}',
  'agent:\u{1100}\u{200B}\u{1161}',
  'agent:\u{3131}\u{314F}',
  'Agent:\u{A7CB}\u{A7CC}\u{A7DA}\u{A7DC}\u{1C89}',
  'agent:\u{10D50}\u{10D65}',
  'agent:\u{0295}\u{03A3}',
  'agent:\u{A7CE}\u{A7CF}\u{A7F1}',
  'agent:\u{1CCD8}\u{1CCE4}\u{1CCD9}\u{1CCDA}\u{1CCED}',
  '\u{1CCD6}\u{1CCDE}',
  'ΟΔΥΣΣΕΥΣ',
  'agent:ΑΣ\u{0301}',
  'agent:ΑΣ\u{0301}Α',
  'agent:\u{0345}Σ',
  'agent:Σ\u{1E5EE}',
  'agent:\u{10D4E}Σ',
  'agent:\u{0130}',
  'agent:\u{FB01}\u{FB03}',
  '\u{FEFF} Agent:Claude-Code\u{3000}',
  '\u{180E}agent:x\u{2065}',
  'agent:\u{FF21}\u{FF29}',
  'ＡＩ',
  'agent:\u{2163}Σ',
  'agent:\u{1F82}\u{0345}',
  'agent:\u{0958}\u{095C}',
  'agent:\u{2ADC}',
  'agent:\u{0CCB}\u{0CC2}\u{0CD5}',
  'agent:\u{0DD9}\u{0DCF}\u{0DCA}',
  'agent:\u{1D15E}\u{1D165}',
];
const stringVectors = strings.map((s) => [hexes(s), hexes(identityKey(s))]);
const nfcVectors = strings.map((s) => [hexes(s), hexes(s.normalize('NFC'))]);

const vectors = {
  generatedBy: 'Scripts/generate-unicode-tables.mjs',
  node: process.version,
  icu: process.versions.icu,
  unicode: process.versions.unicode,
  identityKey: "s.normalize('NFKC').replace(/\\p{Default_Ignorable_Code_Point}/gu, '').trim().toLowerCase()",
  note:
    'Code points and strings in hex. keys: identityKey of every code point whose key is neither itself nor empty ' +
    '(cp:k1,k2,…; A-B:T maps A+i to T+i, and A-B/2:T maps A+2i to T+2i). ' +
    'removed: the code points whose key is empty. composites: the code points NFC composes from their NFD, Hangul ' +
    'syllables aside. combiningClasses: [first, last, c]: the code points NFD leaves alone whose canonical combining ' +
    'class is nonzero and the same as c\'s. caseIgnorable and casedNotIgnorable: the classes toLowerCase\'s ' +
    'Final_Sigma rule reads. strings: [input, identityKey]. nfc: [input, NFC].',
  keys: mappingEntries(keys),
  removed: rangesOf(removed).map(rangeEntry),
  composites: rangesOf(composites).map(rangeEntry),
  combiningClasses: classes.map(([a, b, c]) => `${rangeEntry([a, b])}:${hex(c)}`),
  caseIgnorable: rangesOf(ignorable).map(rangeEntry),
  casedNotIgnorable: rangesOf(casedOnly).map(rangeEntry),
  strings: stringVectors,
  nfc: nfcVectors,
};
mkdirSync(dirname(vectorsPath), { recursive: true });
writeFileSync(vectorsPath, JSON.stringify(vectors, null, 1) + '\n');

console.log(`Wrote ${tablesPath}`);
console.log(
  `  ${canonical.length} canonical and ${compatibility.length} compatibility decompositions, ${ccc.size} combining marks, ` +
    `${compositions.length} compositions, ${lowercase.size} lowercase mappings`,
);
console.log(`Wrote ${vectorsPath} (node ${process.version}, ICU ${process.versions.icu}, Unicode ${process.versions.unicode})`);
console.log(`  ${keys.length} keys, ${removed.length} removed, ${composites.length} composites, ${marks.length} marks`);
