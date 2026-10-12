import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';

// Explicit user instruction on 2026-10-12: the owner tests the physical iPhone
// after TestFlight delivery. This is a pending handoff, never a passing test.
export const requiredAcceptanceEnvironments = Object.freeze(['desktop', 'iphoneSimulator', 'ipadSimulator']);
export const userPhysicalValidation = Object.freeze({operation: 'visual.physicalIphone', environment: 'physicalIphone',
  owner: 'user', delivery: 'TestFlight', result: 'pendingUserValidation', requestedOn: '2026-10-12'});
export function userValidationHandoffIssues(campaign) {
  const issues = [];
  const operation = campaign.operations?.find(item => item.id === userPhysicalValidation.operation);
  const environment = campaign.environments?.[userPhysicalValidation.environment];
  for (const [name, row] of [['operation', operation], ['environment', environment]]) {
    if (!row || row.owner !== 'user' || row.delivery !== 'TestFlight' || row.result !== 'pendingUserValidation' ||
        row.executed !== 0 || row.skipped !== 0 || (row.evidence?.length ?? 0) !== 0 || row.artifact) {
      issues.push(`Physical iPhone ${name} must remain explicitly pending user validation after TestFlight.`);
    }
  }
  return issues;
}

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

export function nativeAcceptanceArtifacts(app) {
  const digest = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const files = {};
  for (const name of ['Nodus', 'Info.plist', 'Nodus.debug.dylib']) {
    const file = path.join(app, name);
    if (fs.existsSync(file)) files[name] = digest(file);
    else if (name !== 'Nodus.debug.dylib') throw new Error(`Missing native build artifact: ${name}`);
  }
  const uiTests = path.join(path.dirname(app), 'NodusUITests-Runner.app/PlugIns/NodusUITests.xctest/NodusUITests');
  if (fs.existsSync(uiTests)) files.uiTests = digest(uiTests);
  return files;
}

export function verifyNativeAcceptanceBuild(root, app) {
  const canonicalApp = fs.realpathSync(app);
  const receipt = JSON.parse(fs.readFileSync(canonicalApp + '.acceptance-build.json', 'utf8'));
  const revision = acceptanceSourceRevision(root);
  if (receipt.version !== 1 || receipt.builtApp !== canonicalApp ||
      receipt.revision?.commit !== revision.commit || receipt.revision?.sourceDigest !== revision.sourceDigest)
    throw new Error('Native sources changed since the successful build. Rebuild before recording acceptance.');
  if (JSON.stringify(nativeAcceptanceArtifacts(canonicalApp)) !== JSON.stringify(receipt.artifacts))
    throw new Error('Native artifacts changed since their successful build receipt.');
  return receipt;
}

export function nativeAcceptanceRunIssues(receipt, revisions, startTime) {
  const issues = [];
  for (const name of ['mobile', 'desktop']) {
    if (!revisions?.[name]?.commit || !revisions?.[name]?.sourceDigest ||
        receipt?.revisions?.[name]?.commit !== revisions[name].commit || receipt?.revisions?.[name]?.sourceDigest !== revisions[name].sourceDigest)
      issues.push(`Native run used another source revision: ${name}`);
  }
  const native = receipt?.nativeBuildReceipt;
  if (native?.version !== 1 || native.revision?.commit !== revisions?.mobile?.commit ||
      native.revision?.sourceDigest !== revisions?.mobile?.sourceDigest) issues.push('Native run lacks its successful compiled-source receipt.');
  const recorded = Date.parse(receipt?.recordedBeforeExecutionAt ?? ''), completed = Date.parse(native?.completedAt ?? '');
  if (!Number.isFinite(startTime) || !Number.isFinite(recorded) || !Number.isFinite(completed) ||
      completed > recorded || recorded > startTime * 1000) issues.push('Native source evidence was not recorded after compilation and before execution.');
  const artifacts = receipt?.nativeBuild ?? {}, compiled = native?.artifacts ?? {};
  const keys = Object.keys(artifacts).sort();
  if (!artifacts.Nodus || !artifacts['Info.plist'] || !artifacts.uiTests ||
      JSON.stringify(keys) !== JSON.stringify(Object.keys(compiled).sort()) || keys.some(key => artifacts[key] !== compiled[key]))
    issues.push('Native run artifacts do not match their compiled-source receipt.');
  if (receipt?.bridgeBuild?.sourceDigest !== revisions?.desktop?.sourceDigest) issues.push('Native run used another laboratory Bridge.');
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
