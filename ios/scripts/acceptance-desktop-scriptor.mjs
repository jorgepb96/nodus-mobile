#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { nodusRepo, nodusRequire } from './nodus-repo.mjs';

const lab = fs.realpathSync(process.env.NODUS_MOBILE_ACCEPTANCE_LAB ?? '');
assert(fs.existsSync(path.join(lab, '.nodus-mobile-acceptance-lab')), 'An isolated acceptance laboratory is required');
const registry = JSON.parse(fs.readFileSync(path.join(lab, 'vaults.json'), 'utf8'));
assert.equal(registry.activeVaultId, 'default', 'Desktop editing must start in the copied Principal vault');
for (const vault of registry.vaults) {
  const relative = path.relative(lab, fs.realpathSync(vault.path));
  assert(relative && !relative.startsWith('..') && !path.isAbsolute(relative), 'Every writable vault must belong to the laboratory');
}
const fixture = JSON.parse(fs.readFileSync(path.join(lab, 'scriptor-fixture.json'), 'utf8'));
assert(fixture.noteId && fixture.title === 'Aceptación Scriptor móvil 0.1.0');
const output = path.resolve(process.argv[2] ?? '');
assert(output.includes('/artifacts/acceptance-0.1.0/'), 'Desktop evidence needs a private acceptance folder');
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
  const rendererErrors = []; page.on('pageerror', error => rendererErrors.push(error.message));
  await page.setViewportSize({ width: 1440, height: 1024 });
  await page.waitForFunction(() => Boolean(document.getElementById('root')?.children.length));
  // Fixture-only startup preferences suppress tours; they do not alter documents or providers.
  await page.evaluate(version => {
    localStorage.setItem('nodus.lastSeenVersion', version);
    for (const key of ['nodus.mobileTeaserSeen.3.2.4', 'nodus.platformHighlightsSeen.2026-07',
      'nodus.tutorialVideosAnnouncementSeen.2026-07', 'nodus.toolkitBetaGuideSeen.2.4.0']) localStorage.setItem(key, '1');
  }, version);
  await page.reload();
  for (const testId of ['whats-new-cinematic-modal', 'pdf-presenter-tutorial-announcement', 'startup-update-modal']) {
    const dialog = page.getByTestId(testId);
    if (await dialog.waitFor({ state: 'visible', timeout: 2500 }).then(() => true, () => false)) {
      await dialog.getByRole('button', { name: testId === 'startup-update-modal' ? 'Entendido' : 'Cerrar', exact: false }).click();
      await dialog.waitFor({ state: 'detached' });
    }
  }
  const active = await page.evaluate(() => window.nodus.getActiveVault());
  assert.equal(active.id, 'default', 'The real Desktop renderer must own the same vault as the phone');
  await page.locator('[data-tour="nav-workspace"]').click();
  const search = page.getByPlaceholder('Buscar en notas e ideas…');
  await search.fill(fixture.title);
  await page.getByRole('button', { name: `Abrir ${fixture.title}`, exact: true }).click();
  await page.screenshot({ path: path.join(output, 'desktop-scriptor-opened.png') });
  const before = await page.evaluate(id => window.nodus.getWorkspaceNoteEditorData(id), fixture.noteId);
  fs.writeFileSync(path.join(output, 'desktop-scriptor-before.json'), JSON.stringify(before), { mode: 0o600 });
  const firstParagraph = before.nativeDocument.find(block => block.type === 'paragraph');
  function inlineText(content) {
    return typeof content === 'string' ? content : Array.isArray(content)
      ? content.map(item => typeof item.text === 'string' ? item.text : inlineText(item.content)).join('') : '';
  }
  const paragraphText = inlineText(firstParagraph?.content);
  assert(paragraphText.length > 40, 'An actual editable paragraph is required, including earlier acceptance edits');
  const paragraph = page.getByText(paragraphText, { exact: true });
  await paragraph.waitFor({ state: 'visible' });
  assert(before.nativeDocument.some(block => block.type === 'table'));
  assert(JSON.stringify(before.nativeDocument).includes('E=mc^2'));
  await page.screenshot({ path: path.join(output, 'desktop-scriptor-before-edit.png') });
  const marker = `DesktopQA-${randomUUID()}`;
  await paragraph.click();
  await page.keyboard.press('End');
  await page.keyboard.insertText(` Frase de prueba enviada desde Desktop al movil. ${marker}.`);
  await page.waitForFunction(async ({ id, marker }) => {
    const document = await window.nodus.getWorkspaceNoteEditorData(id);
    return document.contentMarkdown.includes(marker) && JSON.stringify(document.nativeDocument).includes(marker);
  }, { id: fixture.noteId, marker }, { timeout: 30_000 });
  const after = await page.evaluate(id => window.nodus.getWorkspaceNoteEditorData(id), fixture.noteId);
  assert.notEqual(after.revision, before.revision);
  assert(after.versions.length > before.versions.length);
  assert.deepEqual(after.nativeDocument.filter(block => block.type === 'table'), before.nativeDocument.filter(block => block.type === 'table'));
  assert(JSON.stringify(after.nativeDocument).includes('E=mc^2'));
  assert.equal(rendererErrors.length, 0, rendererErrors.join('\n'));
  await page.screenshot({ path: path.join(output, 'desktop-scriptor-after-edit.png') });
  const result = { result: 'passed', desktopVersion: version, noteId: fixture.noteId, marker,
    beforeRevision: before.revision, afterRevision: after.revision, versions: after.versions.length,
    structuredTablePreserved: true, formulaPreserved: true, interaction: 'actual Desktop BlockNote keyboard editing', skipped: 0 };
  fs.writeFileSync(path.join(lab, 'scriptor-desktop-edit-acceptance-result.json'), JSON.stringify(result), { mode: 0o600 });
  fs.writeFileSync(path.join(output, 'desktop-scriptor-result.json'), JSON.stringify(result), { mode: 0o600 });
  console.log(JSON.stringify(result));
} catch (error) {
  if (page) {
    await page.screenshot({ path: path.join(output, 'desktop-scriptor-failure.png') }).catch(() => {});
    fs.writeFileSync(path.join(output, 'desktop-scriptor-failure-text.txt'), await page.locator('body').innerText().catch(() => 'Renderer unavailable'), { mode: 0o600 });
  }
  throw error;
} finally { await application?.close(); }
