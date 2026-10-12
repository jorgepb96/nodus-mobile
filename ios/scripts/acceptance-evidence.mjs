import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';

export function acceptanceSourceRevision(root) {
  const hash=createHash('sha256');
  const files=execFileSync('git',['ls-files','--cached','--others','--exclude-standard','-z'],{cwd:root,encoding:'utf8'}).split('\0').filter(Boolean).sort();
  for (const file of files) {
    const absolute=path.join(root,file);
    if (!fs.existsSync(absolute)) {hash.update(`deleted:${file}\0`);continue;}
    if (!fs.statSync(absolute).isFile()) continue;
    hash.update(file);hash.update('\0');hash.update(fs.readFileSync(absolute));hash.update('\0');
  }
  return {commit:execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),sourceDigest:hash.digest('hex')};
}

export function acceptanceRevisionIssues(revisions, roots) {
  const issues=[];
  for (const [name,root] of Object.entries(roots)) {
    const tested=revisions?.[name];
    if (!tested || typeof tested.commit!=='string' || !/^[a-f0-9]{40}$/.test(tested.commit) ||
        typeof tested.sourceDigest!=='string' || !/^[a-f0-9]{64}$/.test(tested.sourceDigest)) {
      issues.push(`Missing exact tested code revision: ${name}`);continue;
    }
    const current=acceptanceSourceRevision(root);
    if (tested.commit!==current.commit || tested.sourceDigest!==current.sourceDigest) issues.push(`Code changed since acceptance: ${name}`);
  }
  return issues;
}

// Daily runs keep their logs, captures and result bundles together. Never walk
// inside xcresult bundles or capture folders, and never follow a symlink out
// of the private acceptance folder.
export function acceptanceResultPaths(folder) {
  const results = [];
  function scan(relative = '') {
    for (const entry of fs.readdirSync(path.join(folder, relative), {withFileTypes: true})) {
      if (entry.isSymbolicLink()) continue;
      const name = path.join(relative, entry.name);
      if (entry.name.endsWith('.xcresult')) results.push(name);
      else if (!relative && entry.isDirectory() && /^local-\d{4}-\d{2}-\d{2}$/.test(entry.name)) scan(name);
    }
  }
  scan();
  return results.sort();
}

export function acceptanceReceiptPath(folder, artifact) {
  const root = path.resolve(folder);
  const absolute = path.resolve(root, artifact);
  if (!absolute.startsWith(root + path.sep) || !artifact.endsWith('.xcresult')) {
    throw new Error('An acceptance result must belong to its private evidence folder.');
  }
  const basename = path.basename(artifact, '.xcresult');
  const candidates = [...new Set([
    artifact.replace(/\.xcresult$/, '.source.json'),
    basename + '.source.json',
    basename.replace(/^app-/, '') + '.source.json',
  ])];
  const existing = candidates.filter(relative => {
    try { return fs.lstatSync(path.join(root, relative)).isFile(); }
    catch (error) { if (error.code === 'ENOENT') return false; throw error; }
  });
  if (existing.length !== 1) throw new Error(`Missing or ambiguous pre-execution source receipt: ${artifact}`);
  return existing[0];
}
