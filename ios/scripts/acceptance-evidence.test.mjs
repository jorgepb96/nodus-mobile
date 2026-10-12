import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {acceptanceResultPaths, acceptanceReceiptPath, acceptanceSourceRevision, acceptanceRevisionIssues, nativeAcceptanceArtifacts, verifyNativeAcceptanceBuild} from './acceptance-evidence.mjs';

function laboratory(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nodus-evidence-index-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  return root;
}

test('retains distinct root and daily runs without scanning inside result bundles or captures', t => {
  const root = laboratory(t);
  for (const relative of ['same.xcresult/inside.xcresult', 'local-2026-10-12/same.xcresult',
    'local-2026-10-11/phone.xcresult', 'local-2026-10-12/captures/fake.xcresult', 'unrelated/fake.xcresult']) {
    fs.mkdirSync(path.join(root, relative), {recursive: true});
  }
  fs.symlinkSync(path.join(root, 'same.xcresult'), path.join(root, 'external.xcresult'));
  assert.deepEqual(acceptanceResultPaths(root), ['local-2026-10-11/phone.xcresult', 'local-2026-10-12/same.xcresult', 'same.xcresult']);
});

test('finds immutable source receipts for legacy and daily app runs', t => {
  const root = laboratory(t);
  fs.mkdirSync(path.join(root, 'local-2026-10-12'));
  fs.writeFileSync(path.join(root, 'legacy.source.json'), '{}');
  fs.writeFileSync(path.join(root, 'phone-01.source.json'), '{}');
  assert.equal(acceptanceReceiptPath(root, 'legacy.xcresult'), 'legacy.source.json');
  assert.equal(acceptanceReceiptPath(root, 'local-2026-10-12/app-phone-01.xcresult'), 'phone-01.source.json');
});

test('missing, ambiguous, external and symlink receipts cannot be attributed to a run', t => {
  const root = laboratory(t);
  assert.throws(() => acceptanceReceiptPath(root, 'app-phone.xcresult'), /Missing/);
  assert.throws(() => acceptanceReceiptPath(root, '../outside.xcresult'), /private evidence folder/);
  fs.writeFileSync(path.join(root, 'phone.source.json'), '{}');
  fs.writeFileSync(path.join(root, 'app-phone.source.json'), '{}');
  assert.throws(() => acceptanceReceiptPath(root, 'app-phone.xcresult'), /ambiguous/);
  fs.symlinkSync(path.join(root, 'phone.source.json'), path.join(root, 'linked.source.json'));
  assert.throws(() => acceptanceReceiptPath(root, 'linked.xcresult'), /Missing/);
});

test('release evidence cannot approve a different current checkout, including uncommitted changes', t => {
  const root=laboratory(t);
  const git=(...args)=>execFileSync('git',args,{cwd:root,stdio:'pipe'});
  git('init','-q');
  fs.writeFileSync(path.join(root,'.gitignore'),'artifacts/\n');
  fs.writeFileSync(path.join(root,'source.swift'),'let value = 1\n');
  git('add','.');git('-c','user.name=Acceptance fixture','-c','user.email=acceptance@example.test','commit','-qm','Initial isolated source');
  const tested=acceptanceSourceRevision(root),roots={mobile:root};
  assert.deepEqual(acceptanceRevisionIssues({mobile:tested},roots),[]);
  fs.mkdirSync(path.join(root,'artifacts'));fs.writeFileSync(path.join(root,'artifacts','results.json'),'{}');
  assert.deepEqual(acceptanceRevisionIssues({mobile:tested},roots),[],'ignored evidence does not change the candidate');
  fs.writeFileSync(path.join(root,'source.swift'),'let value = 2\n');
  assert.deepEqual(acceptanceRevisionIssues({mobile:tested},roots),['Code changed since acceptance: mobile']);
  fs.writeFileSync(path.join(root,'source.swift'),'let value = 1\n');
  fs.writeFileSync(path.join(root,'new.swift'),'let added = true\n');
  assert.deepEqual(acceptanceRevisionIssues({mobile:tested},roots),['Code changed since acceptance: mobile']);
  fs.unlinkSync(path.join(root,'new.swift'));fs.unlinkSync(path.join(root,'source.swift'));
  assert.deepEqual(acceptanceRevisionIssues({mobile:tested},roots),['Code changed since acceptance: mobile']);
  assert.deepEqual(acceptanceRevisionIssues({mobile:'unverified-hash'},roots),['Missing exact tested code revision: mobile']);
});

test('native evidence rejects stale sources, changed binaries and another application receipt', t => {
  const root = laboratory(t);
  const git = (...args) => execFileSync('git', args, {cwd: root, stdio: 'pipe'});
  git('init', '-q');
  fs.writeFileSync(path.join(root, '.gitignore'), 'artifacts/\n');
  const source = path.join(root, 'source.swift');
  fs.writeFileSync(source, 'let value = 1\n');
  git('add', '.'); git('-c', 'user.name=Acceptance fixture', '-c', 'user.email=acceptance@example.test', 'commit', '-qm', 'Isolated native source');
  const app = path.join(root, 'artifacts/Nodus.app');
  fs.mkdirSync(app, {recursive: true});
  fs.writeFileSync(path.join(app, 'Nodus'), 'native artifact fixture');
  fs.writeFileSync(path.join(app, 'Info.plist'), 'plist artifact fixture');
  const uiTests = path.join(path.dirname(app), 'NodusUITests-Runner.app/PlugIns/NodusUITests.xctest/NodusUITests');
  fs.mkdirSync(path.dirname(uiTests), {recursive: true}); fs.writeFileSync(uiTests, 'test artifact fixture');
  const receipt = {version: 1, builtApp: fs.realpathSync(app), revision: acceptanceSourceRevision(root), artifacts: nativeAcceptanceArtifacts(app)};
  const file = app + '.acceptance-build.json';
  fs.writeFileSync(file, JSON.stringify(receipt));
  assert.deepEqual(verifyNativeAcceptanceBuild(root, app), receipt);
  fs.writeFileSync(source, 'let value = 2\n');
  assert.throws(() => verifyNativeAcceptanceBuild(root, app), /Native sources changed/);
  fs.writeFileSync(source, 'let value = 1\n');
  fs.writeFileSync(uiTests, 'older or changed test runner');
  assert.throws(() => verifyNativeAcceptanceBuild(root, app), /Native artifacts changed/);
  fs.writeFileSync(uiTests, 'test artifact fixture');
  fs.writeFileSync(file, JSON.stringify({...receipt, builtApp: path.join(root, 'another.app')}));
  assert.throws(() => verifyNativeAcceptanceBuild(root, app), /Native sources changed/);
  fs.unlinkSync(file);
  assert.throws(() => verifyNativeAcceptanceBuild(root, app), /ENOENT/);
});
