#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { nodusRepo, nodusRequire } from './nodus-repo.mjs';

const lab = fs.realpathSync(process.env.NODUS_MOBILE_ACCEPTANCE_LAB ?? '');
assert(fs.existsSync(path.join(lab, '.nodus-mobile-acceptance-lab')));
const registry = JSON.parse(fs.readFileSync(path.join(lab, 'vaults.json'), 'utf8'));
assert.equal(registry.activeVaultId, 'default');
for (const vault of registry.vaults) {
  const relative = path.relative(lab, fs.realpathSync(vault.path));
  assert(relative && !relative.startsWith('..') && !path.isAbsolute(relative));
}
const output = path.resolve(process.argv[2] ?? '');
assert(output.includes('/artifacts/acceptance-0.1.0/'));
fs.mkdirSync(output, { recursive: true, mode: 0o700 });
// Use the exact saved definition and evidence expectations given to the phone.
const input = JSON.parse(execFileSync('python3', ['-c',
  'import json,plistlib,sys; v=plistlib.load(open(sys.argv[1],"rb"))["NodusUITests"]["EnvironmentVariables"]; print(json.dumps({k:v[k] for k in v if k.startswith("NODUS_ACCEPTANCE_DICTIONARY_")}))',
  process.argv[3]], { encoding: 'utf8' }));
const expected = suffix => {
  const value = input['NODUS_ACCEPTANCE_DICTIONARY_' + suffix];
  assert(typeof value === 'string' && value.length > 0, 'Actual saved dictionary inputs are required');
  return value;
};
const name = expected('NAME'), related = expected('RELATED_NAME'), body = expected('BODY_SNIPPET');
const author = expected('AUTHOR_NAME'), work = expected('WORK_TITLE');
const desktop = nodusRepo(), { _electron } = nodusRequire('playwright-core');
const version = JSON.parse(fs.readFileSync(path.join(desktop, 'package.json'), 'utf8')).version;
const env = { ...process.env, NODUS_USERDATA: lab, NODUS_DISABLE_AUTO_UPDATE: '1',
  NODUS_E2E_UPDATE_STATUS: 'not-available', NODUS_E2E_DISABLE_STUDY_BACKGROUND_AI: '1' };
delete env.ELECTRON_RUN_AS_NODE;
let application, page;
const sections = [];
try {
  application = await _electron.launch({ executablePath: nodusRequire('electron'), args: [desktop], env, timeout: 60_000 });
  assert.equal(await application.evaluate(({ app }) => app.getPath('userData')), lab);
  assert.equal(await application.evaluate(({ app }) => app.getVersion()), version);
  page = await application.firstWindow(); page.setDefaultTimeout(30_000);
  await page.setViewportSize({ width: 1440, height: 1024 });
  await page.waitForFunction(() => Boolean(document.getElementById('root')?.children.length));
  await page.evaluate(version => {
    localStorage.setItem('nodus.lastSeenVersion', version);
    for (const key of ['nodus.mobileTeaserSeen.3.2.4', 'nodus.platformHighlightsSeen.2026-07',
      'nodus.tutorialVideosAnnouncementSeen.2026-07', 'nodus.toolkitBetaGuideSeen.2.4.0']) localStorage.setItem(key, '1');
  }, version);
  await page.reload();
  for (const id of ['whats-new-cinematic-modal', 'pdf-presenter-tutorial-announcement', 'startup-update-modal']) {
    const dialog = page.getByTestId(id);
    if (await dialog.waitFor({ state: 'visible', timeout: 2500 }).then(() => true, () => false)) {
      await dialog.getByRole('button', { name: id === 'startup-update-modal' ? 'Entendido' : 'Cerrar', exact: false }).click();
      await dialog.waitFor({ state: 'detached' });
    }
  }
  assert.equal((await page.evaluate(() => window.nodus.getActiveVault())).id, 'default');
  await page.locator('[data-tour="nav-dictionary"]').click();
  const catalogue = page.getByTestId('dictionary-workspace');
  await catalogue.getByRole('textbox').first().fill(name);
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  await catalogue.getByRole('button', { name: new RegExp('^' + escaped) }).first().click();
  const detail = page.getByTestId('dictionary-entry-detail');
  await detail.waitFor({ state: 'visible' });
  for (const section of ['overview', 'evidence', 'authors', 'works', 'versions', 'relations']) {
    await detail.getByTestId('dictionary-detail-tab-' + section).click();
    if (section === 'overview') await detail.getByText(body, { exact: false }).first().waitFor({ state: 'visible' });
    if (section === 'evidence') await detail.getByPlaceholder('Buscar en la evidencia…').waitFor({ state: 'visible' });
    if (section === 'authors') await detail.getByRole('button', { name: new RegExp('^' + author.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')) }).first().waitFor({ state: 'visible' });
    if (section === 'works') await detail.getByText(work, { exact: true }).first().waitFor({ state: 'visible' });
    if (section === 'versions') {
      await detail.getByRole('button', { name: /^Versión ·/ }).first().click();
      await detail.getByText(body, { exact: false }).first().waitFor({ state: 'visible' });
    }
    if (section === 'relations') await detail.getByRole('button', { name: 'Abrir entrada relacionada: ' + related, exact: true }).waitFor({ state: 'visible' });
    await page.screenshot({ path: path.join(output, 'desktop-dictionary-' + section + '.png') });
    sections.push(section);
  }
  await detail.getByRole('button', { name: 'Abrir entrada relacionada: ' + related, exact: true }).click();
  await detail.getByText(related, { exact: true }).first().waitFor({ state: 'visible' });
  await page.screenshot({ path: path.join(output, 'desktop-dictionary-related-entry.png') });
  const result = { result: 'passed', desktopVersion: version, sections, samePhoneExpectations: true, skipped: 0 };
  fs.writeFileSync(path.join(output, 'desktop-dictionary-result.json'), JSON.stringify(result), { mode: 0o600 });
  console.log(JSON.stringify(result));
} catch (error) {
  if (page) {
    await page.screenshot({ path: path.join(output, 'desktop-dictionary-failed.png') }).catch(() => {});
    fs.writeFileSync(path.join(output, 'desktop-dictionary-failed.txt'), await page.locator('body').innerText().catch(() => ''), { mode: 0o600 });
    fs.writeFileSync(path.join(output, 'desktop-dictionary-inputs.json'), JSON.stringify(await page.locator('input').evaluateAll(inputs => inputs.map(input => ({ type: input.type, placeholder: input.placeholder }))).catch(() => [])), { mode: 0o600 });
  }
  throw error;
} finally { await application?.close(); }
