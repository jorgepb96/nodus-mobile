#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { mobileRoot, nodusRepo } from './nodus-repo.mjs';
import { manifestText, PARITY_MANIFEST_VERSION } from './generate-parity-manifest.mjs';

function valuesBetween(source, start, end) {
  const from = source.indexOf(start);
  if (from < 0) throw new Error(`Could not find ${start}`);
  const to = source.indexOf(end, from + start.length);
  if (to < 0) throw new Error(`Could not find ${end}`);
  return source.slice(from + start.length, to);
}

function quoted(source) {
  return [...source.matchAll(/'([^']+)'/g)].map((match) => match[1]);
}

function difference(left, right) {
  const known = new Set(right);
  return [...new Set(left)].filter((value) => !known.has(value)).sort();
}

const desktop = nodusRepo();
const navigation = fs.readFileSync(path.join(desktop, 'src/navigation.ts'), 'utf8');
const swiftNavigation = fs.readFileSync(path.join(mobileRoot, 'ios/Nodus/State/NavigationContract.swift'), 'utf8');
const desktopRoutes = quoted(valuesBetween(navigation, 'export type View = ', ';'));
const classifiedRoutes = [...swiftNavigation.matchAll(/\.init\(\.([A-Za-z0-9_]+),/g)].map((match) => match[1]);

const mutationContract = JSON.parse(fs.readFileSync(path.join(desktop, 'shared/mutableTables.json'), 'utf8'));
const swiftMutations = fs.readFileSync(
  path.join(mobileRoot, 'ios/Packages/NodusKit/Sources/NodusKit/Generated/MutableTable.generated.swift'),
  'utf8',
);
const desktopTables = Object.keys(mutationContract.tables);
const mutableEnum = valuesBetween(swiftMutations, 'public enum MutableTable:', '\n}');
const swiftTables = [...mutableEnum.matchAll(/^\s*case\s+\w+(?:\s*=\s*"([^"]+)")?/gm)].map((match) => {
  if (match[1]) return match[1];
  const whole = match[0].match(/case\s+(\w+)/)?.[1] ?? '';
  return whole;
});

const problems = [];

const manifestPath = path.join(mobileRoot, 'ios/Parity/parity-manifest.json');
if (!fs.existsSync(manifestPath)) {
  problems.push('parity manifest:\n  missing ios/Parity/parity-manifest.json');
} else {
  const committed = fs.readFileSync(manifestPath, 'utf8');
  const expected = manifestText();
  if (committed !== expected) {
    problems.push('parity manifest:\n  Desktop changed; classify the change and regenerate it with generate-parity-manifest.mjs --write');
  } else {
    const manifest = JSON.parse(committed);
    if (manifest.version !== PARITY_MANIFEST_VERSION) {
      problems.push(`parity manifest:\n  expected version ${PARITY_MANIFEST_VERSION}, found ${manifest.version}`);
    }
    const allowed = new Set(manifest.allowedDeliveries);
    const all = [...manifest.routes, ...manifest.apiActions, ...manifest.mutableTables, ...manifest.explicitExclusions];
    const unclassified = all.filter((item) => !allowed.has(item.delivery));
    if (unclassified.length) {
      problems.push(`parity manifest:\n  unclassified: ${unclassified.map((item) => item.id ?? item.name).join(', ')}`);
    }
    const unsupportedClaims = [...manifest.routes, ...manifest.apiActions]
      .filter((item) => item.mobileState === 'implemented' && (!item.evidence || item.evidence.length === 0));
    const implemented = [...manifest.routes, ...manifest.apiActions, ...manifest.mutableTables];
    const incomplete = implemented.filter((item) => item.mobileState !== 'implemented');
    const missingEvidence = implemented.flatMap((item) => item.evidence ?? [])
      .filter((entry, index, entries) => entries.indexOf(entry) === index)
      .filter((entry) => !fs.existsSync(path.resolve(mobileRoot, entry.split('#')[0])));
    if (incomplete.length) {
      problems.push(`parity manifest:\n  incomplete: ${incomplete.map((item) => item.id ?? item.name).join(', ')}`);
    }
    if (unsupportedClaims.length) {
      problems.push(`parity manifest:\n  parity claimed without tests: ${unsupportedClaims.map((item) => item.id).join(', ')}`);
    }
    if (missingEvidence.length) {
      problems.push(`parity manifest:\n  missing evidence: ${missingEvidence.join(', ')}`);
    }
  }
}
for (const [name, expected, actual] of [
  ['desktop routes', desktopRoutes, classifiedRoutes],
  ['mutable tables', desktopTables, swiftTables],
]) {
  const missing = difference(expected, actual);
  const extra = difference(actual, expected);
  if (missing.length || extra.length) {
    problems.push(`${name}:\n  missing in mobile: ${missing.join(', ') || 'none'}\n  absent on desktop: ${extra.join(', ') || 'none'}`);
  }
}

const shell = fs.readFileSync(path.join(mobileRoot, 'ios/Nodus/Screens/SpaceShell.swift'), 'utf8');
const routeSwitch = valuesBetween(shell, 'private func routeView(_ route: NodusRoute)', '\n    private func openIdea');
const unrouted = desktopRoutes.filter((route) => !new RegExp(`\\.${route}\\b`).test(routeSwitch));
if (unrouted.length) problems.push(`executable routes:\n  no native/deep-link destination: ${unrouted.join(', ')}`);
if (/\bdefault\s*:/.test(routeSwitch)) {
  problems.push('executable routes:\n  routeView has a default fallback; keep the switch exhaustive so new routes cannot become placeholders');
}
if (/requiresTypedSurface|case unavailable\s*\(/.test(swiftNavigation)) {
  problems.push('navigation support:\n  unavailable/requiresTypedSurface classification remains in the mobile contract');
}

// The shared shell exposes these labels in every locale. A new Desktop route is not at parity
// if the Spanish app can navigate to it only under an untranslated English label.
const stringCatalog = JSON.parse(
  fs.readFileSync(path.join(mobileRoot, 'ios/Nodus/Localizable.xcstrings'), 'utf8'),
).strings;
const visibleNavigationLabels = [...swiftNavigation.matchAll(
  /^\s*\.init\(\.[^,]+, "([^"]+)".*support: \.(?:native|collection|mirror)/gm,
)].map((match) => match[1]);
const sharedSurfaceLabels = [
  'Explore',
  'Analyze',
  'Write',
  'Tools',
  'Academic vault',
  'Your research workspace',
  'Research approach',
  'General research',
  'Literature review',
  'State of the art',
  'Scholarly debate',
  'Comparative analysis',
  'Chronological analysis',
  'Conceptual or theoretical synthesis',
  'Search every published surface',
  'Semantic',
];
const untranslated = [...new Set([...visibleNavigationLabels, ...sharedSurfaceLabels])].filter(
  (key) => !stringCatalog[key]?.localizations?.es?.stringUnit?.value,
);
if (untranslated.length) {
  problems.push(`Spanish navigation/surface strings:\n  missing: ${untranslated.sort().join(', ')}`);
}

if (problems.length) {
  console.error(`Nodus parity contract drifted.\n${problems.join('\n')}`);
  process.exit(1);
}

const actionCount = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')).apiActions.length : 0;
console.log(`Nodus parity contract is 100% current: ${desktopRoutes.length} routes, ${actionCount} actions and ${desktopTables.length} mutable tables are executable, classified and evidenced.`);
