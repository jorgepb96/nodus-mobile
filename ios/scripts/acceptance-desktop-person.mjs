#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { nodusRepo, nodusRequire } from './nodus-repo.mjs';

const lab = fs.realpathSync(process.env.NODUS_MOBILE_ACCEPTANCE_LAB ?? '');
assert(fs.existsSync(path.join(lab, '.nodus-mobile-acceptance-lab')));
const registry = JSON.parse(fs.readFileSync(path.join(lab, 'vaults.json'), 'utf8'));
assert.equal(registry.activeVaultId, 'default');
for (const vault of registry.vaults) {
  const relative = path.relative(lab, fs.realpathSync(vault.path));
  assert(relative && !relative.startsWith('..') && !path.isAbsolute(relative));
}
const fixture = JSON.parse(fs.readFileSync(path.join(lab, 'person-dossier-acceptance-input.json'), 'utf8'));
assert.equal(fixture.personId, 'person-acceptance-mobile-010');
assert.equal(fixture.providerCalls, 0);
const target = registry.vaults.find(vault => vault.id === fixture.vaultId);
assert.equal(target?.type, 'prosopography');
const output = path.resolve(process.argv[2] ?? '');
assert(output.includes('/artifacts/acceptance-0.1.0/'));
fs.mkdirSync(output, { recursive: true, mode: 0o700 });
const desktop = nodusRepo(), { _electron } = nodusRequire('playwright-core');
const version = JSON.parse(fs.readFileSync(path.join(desktop, 'package.json'), 'utf8')).version;
const env = { ...process.env, NODUS_USERDATA: lab, NODUS_DISABLE_AUTO_UPDATE: '1',
  NODUS_E2E_UPDATE_STATUS: 'not-available', NODUS_E2E_DISABLE_STUDY_BACKGROUND_AI: '1' };
delete env.ELECTRON_RUN_AS_NODE;
let application, page;
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
  await page.getByTestId('header-vault-badge').click();
  const vaultRow = page.getByTestId('vault-type-icon-prosopography').locator('..');
  assert.equal(await vaultRow.getByText(target.name, { exact: true }).count(), 1);
  await vaultRow.getByTitle('Cargar', { exact: true }).click();
  const deadline = Date.now() + 15_000;
  while ((await page.evaluate(() => window.nodus.getActiveVault())).id !== target.id) {
    assert(Date.now() < deadline, 'The actual Desktop vault switch must finish');
    await page.waitForTimeout(100);
  }
  // Only copied-profile setup flags change. Models and research data remain the
  // same; a newly copied workspace has not necessarily completed its UI tour.
  await page.evaluate(() => window.nodus.updateSettings({ onboardingComplete: true,
    basicsTutorialVersion: 1, tourComplete: true, advancedTourComplete: true }));
  await page.locator('[data-tour="nav-prosopPersons"]').click();
  const view = page.getByTestId('prosop-persons-view');
  const name = fixture.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  await view.getByRole('button', { name: new RegExp('^' + name) }).click();
  await view.getByRole('heading', { name: fixture.name, exact: true }).waitFor({ state: 'visible' });
  await view.getByText(fixture.authorityScheme + ': ' + fixture.authorityId, { exact: true }).waitFor({ state: 'visible' });
  await page.screenshot({ path: path.join(output, 'desktop-person-documented-identity-and-authority.png') });
  const result = { result: 'passed', desktopVersion: version, samePhonePerson: true,
    identityAndCompleteAuthorityVisible: true, skipped: 0 };
  fs.writeFileSync(path.join(output, 'desktop-person-result.json'), JSON.stringify(result), { mode: 0o600 });
  console.log(JSON.stringify(result));
} catch (error) {
  if (page) {
    await page.screenshot({ path: path.join(output, 'desktop-person-failed.png') }).catch(() => {});
    fs.writeFileSync(path.join(output, 'desktop-person-failed.txt'), await page.locator('body').innerText().catch(() => ''), { mode: 0o600 });
  }
  throw error;
} finally {
  if (page) await page.evaluate(() => window.nodus.switchVault('default')).catch(() => {});
  await application?.close();
}
