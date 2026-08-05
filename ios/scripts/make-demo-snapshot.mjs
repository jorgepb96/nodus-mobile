// Build the snapshot the app ships inside its binary.
//
// The first screen of this app asks for a server address. Somebody who installs it without a
// Nodus Server running — which includes whoever reviews it for the App Store — sees nothing at
// all, so the app carries corpora of its own: `ios/Nodus/Resources/demo-space.<lang>.json.gz`,
// one per interface language, each a published snapshot in exactly the format
// `NodusClient.snapshot(in:)` reads off the wire.
//
// It is generated *from a vault*, not hand-written as JSON. A fresh SQLite database is created
// here, the desktop's own migrations are run over it, `ios/scripts/demo-corpus.mjs` fills it,
// and the desktop's own `buildServerSnapshot` publishes it. That is the whole point: the shape
// of the file cannot drift away from the shape the app reads, because the same code produces
// both, and a column a later migration renames breaks this script rather than the demo.
//
// The vault is built rather than borrowed. `ios-lab-publish.mjs` copies a real vault because
// its job is to exercise the app against real shape; this file's output is compiled into a
// binary that is distributed, and nothing private can ever be taken back out of one. So the
// registry is never read here, and the corpus is public-domain works and text written for the
// purpose.
//
// Usage:
//   node ios/scripts/make-demo-snapshot.mjs
//   node ios/scripts/make-demo-snapshot.mjs --force     # rewrite even if the corpus is unchanged
//   node ios/scripts/make-demo-snapshot.mjs --keep      # leave the built vault on disk to inspect
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { gzipSync, gunzipSync } from 'node:zlib';
import { mobileRoot, nodusRepo } from './nodus-repo.mjs';

const require = createRequire(import.meta.url);
const args = process.argv.slice(2);
const has = (name) => args.includes(`--${name}`);

// better-sqlite3 next door is built against Electron's ABI, not the system Node's, so reading
// or writing a vault from plain `node` fails with a NODE_MODULE_VERSION mismatch. The same
// re-exec `ios-lab-publish.mjs` does, forwarding the flags so `--force` survives it.
if (!process.argv.includes('--electron-child')) {
  const { execFileSync } = require('node:child_process');
  execFileSync(
    path.join(nodusRepo(), 'node_modules/.bin/electron'),
    [path.join(mobileRoot, 'ios/scripts/make-demo-snapshot.mjs'), '--electron-child', ...args],
    { cwd: mobileRoot, env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: 'inherit' },
  );
  process.exit(0);
}

const RESOURCES = path.join(mobileRoot, 'ios/Nodus/Resources');

/// One file per interface language. The app opens the one that matches the phone, so a Spanish
/// reader gets a Spanish corpus rather than a Spanish app wrapped around English prose.
const output = (locale) => path.join(RESOURCES, `demo-space.${locale}.json.gz`);

/** What this build of the app will accept. Kept beside `SnapshotFormat` in NodusKit. */
const FORMAT = 'nodus.server-snapshot';
const SUPPORTED_VERSIONS = new Set([1, 2]);

/**
 * The tables Home reads to draw its sections. A snapshot that lost one of these would still
 * import cleanly and would open on an empty board, which is the failure this catches.
 */
const REQUIRED_TABLES = ['works', 'ideas', 'themes', 'authors', 'passages', 'gaps', 'edges', 'notes'];

// ── Loading the desktop's own code ───────────────────────────────────────────
//
// esbuild rather than a TypeScript loader hook, which is how `test-reading-copy-parity.mjs`
// already reaches into the other repository. CJS rather than ESM output because the graph
// pulls in `electron` and `better-sqlite3`, and a named import from a CommonJS module fails at
// link time; `require` interoperates with both. Both are resolved to absolute paths so the
// bundle can sit in a temporary directory and still find them.
async function loadDesktopModules(scratch) {
  const desktopRequire = createRequire(path.join(nodusRepo(), 'package.json'));
  const { build } = desktopRequire('esbuild');
  const absolutise = {
    name: 'absolutise-native-modules',
    setup(bundler) {
      bundler.onResolve({ filter: /^(better-sqlite3|electron)$/ }, (entry) => ({
        path: desktopRequire.resolve(entry.path),
        external: true,
      }));
    },
  };

  const compile = async (entry, name) => {
    const outfile = path.join(scratch, name);
    // The asynchronous API, not `buildSync`: esbuild refuses plugins in a synchronous call.
    await build({
      entryPoints: [path.join(nodusRepo(), entry)],
      outfile,
      bundle: true,
      format: 'cjs',
      platform: 'node',
      plugins: [absolutise],
      logLevel: 'silent',
    });
    return require(outfile);
  };

  return {
    migrations: await compile('electron/db/migrations.ts', 'migrations.cjs'),
    snapshot: await compile('electron/serverSync/serverSnapshot.ts', 'snapshot.cjs'),
    Database: desktopRequire('better-sqlite3'),
  };
}

// ── Building the vault ───────────────────────────────────────────────────────

function buildVault(directory, { migrations, Database }) {
  fs.mkdirSync(directory, { recursive: true });
  const file = path.join(directory, 'nodus.sqlite');
  const db = new Database(file);
  migrations.runMigrations(db);
  return { db, file, schemaVersion: migrations.SCHEMA_VERSION };
}

/**
 * The document the app will read, checked against what it will accept.
 *
 * Every one of these is a failure that produces a demo which opens and shows nothing, which
 * is worse than one that does not build: the app would report an empty publication and there
 * would be nothing on screen to say why.
 */
function validate(document) {
  const problems = [];
  if (document.format !== FORMAT) problems.push(`format is "${document.format}", not "${FORMAT}"`);
  if (!SUPPORTED_VERSIONS.has(Number(document.formatVersion))) {
    problems.push(`formatVersion ${document.formatVersion} is not one this build reads (${[...SUPPORTED_VERSIONS].join(', ')})`);
  }
  if (!document.revision) problems.push('no revision, so the mirror would import it as revision ""');
  if (!document.vault?.type) problems.push('no vault type, so the app cannot pick an accent or a menu');
  for (const table of REQUIRED_TABLES) {
    const rows = document.tables?.[table];
    if (!Array.isArray(rows) || rows.length === 0) problems.push(`table "${table}" is empty`);
  }
  if (problems.length) {
    throw new Error(`The snapshot this produced is not one the app can show:\n  - ${problems.join('\n  - ')}`);
  }
}

/** The revision of the file already committed, so an unchanged corpus is not rewritten. */
function committedRevision(locale) {
  const file = output(locale);
  if (!fs.existsSync(file)) return null;
  try {
    return JSON.parse(gunzipSync(fs.readFileSync(file)).toString('utf8')).revision ?? null;
  } catch {
    return null;
  }
}

/**
 * One vault, one language, one file.
 *
 * A fresh database per language rather than one vault re-seeded: the corpora differ in every
 * translatable column, and re-running the seed over a used database would have to know how to
 * undo itself. A migration run costs a fraction of a second.
 */
function buildLocale(scratch, desktop, corpus, locale, schemaVersion) {
  const { db } = buildVault(path.join(scratch, locale), desktop);
  let built;
  let counted;
  try {
    counted = corpus.seedDemoVault(db, locale);
    built = desktop.snapshot.buildServerSnapshot(
      corpus.demoVault(locale),
      // Both on. The notes are half of what the demo is showing — a corpus you can read *and*
      // write about — and passages are what a citation resolves against.
      { nodusServerIncludeUserContent: true, nodusServerIncludePassages: true },
      db,
    );
  } finally {
    db.close();
  }

  // `buildServerSnapshot` returns the revision beside the document rather than inside it,
  // because on the wire it travels as `x-nodus-revision`. There is no wire here, and
  // `SnapshotDownload` already falls back to `document.revision` — so it is written in, and
  // that is the only edit made to what the desktop produced.
  const document = { ...JSON.parse(built.buffer.toString('utf8')), revision: built.revision };
  validate(document);
  const gzipped = gzipSync(Buffer.from(JSON.stringify(document)), { level: 9 });
  const populated = Object.entries(document.tables).filter(([, rows]) => rows.length > 0);

  console.log(`\n▸ ${locale}  ${document.vault.name}`);
  console.log(`  corpus    ${counted.works} works · ${counted.ideas} ideas · ${counted.passages} passages · ${counted.edges} edges (${counted.debates} of them debates)`);
  console.log(`  snapshot  format ${document.format} v${document.formatVersion} · schema ${schemaVersion} · ${populated.length} populated tables · revision ${document.revision.slice(0, 12)}`);
  console.log(`  size      ${(built.buffer.length / 1024).toFixed(0)} kB raw → ${(gzipped.length / 1024).toFixed(0)} kB gzipped`);

  if (committedRevision(locale) === document.revision && !has('force')) {
    // `generatedAt` is a fresh timestamp on every run and is deliberately outside the revision
    // hash, so rewriting an unchanged corpus would put a different file in every diff that
    // happened to touch this script. The revision is the identity; if it matches, nothing is
    // written.
    console.log('  unchanged, nothing written (--force to rewrite)');
    return;
  }
  fs.mkdirSync(RESOURCES, { recursive: true });
  fs.writeFileSync(output(locale), gzipped);
  console.log(`  wrote     ${path.relative(mobileRoot, output(locale))}`);
}

async function main() {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'nodus-demo-snapshot-'));
  const desktop = await loadDesktopModules(scratch);
  const corpus = await import('./demo-corpus.mjs');

  for (const locale of corpus.LOCALES) {
    buildLocale(scratch, desktop, corpus, locale, desktop.migrations.SCHEMA_VERSION);
  }

  if (has('keep')) {
    console.log(`\nVaults kept at ${scratch}`);
  } else {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
