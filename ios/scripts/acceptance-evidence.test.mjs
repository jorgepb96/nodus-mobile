import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {acceptanceResultPaths, acceptanceReceiptPath} from './acceptance-evidence.mjs';

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
