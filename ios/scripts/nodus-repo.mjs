// Where the Nodus desktop repository is checked out.
//
// The app lives in this repository. The things it is a client of do not: the mark its icon is
// drawn from, the TypeScript its reading copy is a port of, and the snapshot builder the lab
// publishes with all live in github.com/Drakonis96/nodus. None of it is vendored here, and that
// is deliberate — a copy would drift, and drift is the exact failure the parity check exists to
// catch. A tool that needs the other side asks for it here and says so plainly when it is absent.
//
// Keep the two repositories side by side, or point NODUS_REPO at your checkout.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

/** This repository's root. `ios/scripts/` is two levels down from it. */
export const mobileRoot = path.resolve(here, '../..');

/** A file that exists in the Nodus repository and nowhere else, used to recognise it. */
const MARKER = 'shared/readingCopy.ts';

let cached = null;

export function nodusRepo() {
  if (cached) return cached;
  const candidates = [
    process.env.NODUS_REPO,
    path.resolve(mobileRoot, '../nodus'),
    path.resolve(mobileRoot, '..', path.basename(mobileRoot).replace(/-mobile$/, '')),
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, MARKER))) {
      cached = candidate;
      return cached;
    }
  }
  throw new Error(
    'Could not find the Nodus repository.\n'
    + '  Clone https://github.com/Drakonis96/nodus beside this one, or set NODUS_REPO to your checkout.\n'
    + `  Looked in: ${candidates.join(', ')}`
  );
}

/**
 * Load a package from the Nodus repository's node_modules.
 *
 * These tools deliberately carry no dependency tree of their own: the build tools they need are
 * already installed next door, pinned to the versions the desktop actually ships with, and a
 * second copy here could disagree with them without anybody noticing.
 */
export function nodusRequire(name) {
  return createRequire(path.join(nodusRepo(), 'package.json'))(name);
}
