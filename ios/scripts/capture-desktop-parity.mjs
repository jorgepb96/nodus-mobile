#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { mobileRoot, nodusRepo, nodusRequire } from './nodus-repo.mjs';

const output = path.resolve(process.argv[2] ?? path.join(mobileRoot, 'artifacts/parity/manual/desktop.png'));
const route = process.argv[3] ?? 'ideas';
const detail = process.argv[4] ?? '';
const desktop = nodusRepo();
const { _electron: electron } = nodusRequire('playwright-core');
const electronPath = nodusRequire('electron');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'nodus-mobile-parity-'));
const recoveryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'nodus-mobile-parity-recovery-'));
const libraryRoot = path.join(userData, 'backups');
const libraryFixtures = [
  path.join(userData, 'Arendt - La condicion humana.md'),
  path.join(userData, 'Koselleck - Futuro pasado.md'),
];
if (route === 'library') {
  fs.writeFileSync(libraryFixtures[0], '# La condición humana\n\nTrabajo, obra y acción en el espacio público.\n');
  fs.writeFileSync(libraryFixtures[1], '# Futuro pasado\n\nEstratos del tiempo y semántica de los conceptos históricos.\n');
}
const env = {
  ...process.env,
  NODUS_USERDATA: userData,
  NODUS_DISABLE_AUTO_UPDATE: '1',
  NODUS_E2E_UPDATE_STATUS: 'not-available',
  NODUS_E2E_DISABLE_STUDY_BACKGROUND_AI: '1',
};
delete env.ELECTRON_RUN_AS_NODE;

fs.mkdirSync(path.dirname(output), { recursive: true });
let app;
try {
  app = await electron.launch({ executablePath: electronPath, args: [desktop], env, timeout: 60_000 });
  const page = await app.firstWindow();
  page.on('pageerror', (error) => console.error(`[desktop renderer] ${error.stack ?? error.message}`));
  page.setDefaultTimeout(30_000);
  await page.setViewportSize({ width: 1440, height: 1024 });
  await page.waitForFunction(() => Boolean(document.getElementById('root')?.children.length));
  await page.evaluate(async ({ version, libraryRoot, libraryFixtures, route, recoveryRoot, recoveryPassword }) => {
    localStorage.setItem('nodus.lastSeenVersion', version);
    localStorage.setItem('nodus.mobileTeaserSeen.3.2.4', '1');
    localStorage.setItem('nodus.platformHighlightsSeen.2026-07', '1');
    localStorage.setItem('nodus.tutorialVideosAnnouncementSeen.2026-07', '1');
    localStorage.setItem('nodus.toolkitBetaGuideSeen.2.4.0', '1');
    await window.nodus.updateSettings({
      onboardingComplete: true,
      basicsTutorialVersion: 999,
      tourComplete: true,
      advancedTourComplete: true,
      uiLanguage: 'es',
      mascotEnabled: false,
      reduceMotion: true,
      ...(route === 'library' ? { autoBackupFolder: libraryRoot } : {}),
    });
    await window.nodus.seedDemoData();
    if ((await window.nodus.getRecoveryStatus()).needsSetup) {
      const result = await window.nodus.initializeRecoveryFolder(recoveryRoot, recoveryPassword, 'es');
      if (!result.ok) throw new Error(`Isolated Desktop recovery setup failed: ${result.message}`);
    }
    if (route === 'library') {
      await window.nodus.getGlobalLibraryStatus();
      await window.nodus.importDroppedGlobalLibraryFiles(libraryFixtures, null);
    }
  }, { version: nodusRequire(path.join(desktop, 'package.json')).version, libraryRoot, libraryFixtures, route, recoveryRoot, recoveryPassword: randomBytes(32).toString('base64url') });
  await page.reload();
  await page.waitForFunction(() => Boolean(document.getElementById('root')?.children.length));
  const dismissUpdate = async (timeout = 5_000) => {
    const update = page.getByTestId('startup-update-modal');
    const visible = await update.waitFor({ state: 'visible', timeout }).then(() => true, () => false);
    if (!visible) return;
    await page.waitForFunction(() => document.querySelector('[data-testid="startup-update-modal"]')?.getAttribute('data-update-status') === 'not-available');
    await update.getByRole('button', { name: 'Entendido', exact: false }).click();
    await update.waitFor({ state: 'detached' });
  };
  await dismissUpdate();
  const whatsNew = page.getByTestId('whats-new-cinematic-modal');
  const hasWhatsNew = await whatsNew.waitFor({ state: 'visible', timeout: 2_000 }).then(() => true, () => false);
  if (hasWhatsNew) {
    await whatsNew.getByRole('button', { name: 'Cerrar', exact: true }).click();
    await whatsNew.waitFor({ state: 'detached' });
  }
  const presenterAnnouncement = page.getByTestId('pdf-presenter-tutorial-announcement');
  if (await presenterAnnouncement.waitFor({ state: 'visible', timeout: 4_000 }).then(() => true, () => false)) {
    await presenterAnnouncement.getByRole('button', { name: 'Cerrar', exact: true }).click();
    await presenterAnnouncement.waitFor({ state: 'detached' });
  }
  // Startup surfaces are serialised. Closing What's New may be what allows the update
  // status modal to mount, so drain it once more before touching the workspace.
  await dismissUpdate(8_000);
  await page.locator(`[data-tour="nav-${route}"]`).click();
  if (route === 'ideas' && detail === 'tabs') {
    const rows = page.locator('[data-testid^="idea-row-"]');
    await rows.first().waitFor({ state: 'visible' });
    await rows.nth(0).click();
    await page.getByTestId('idea-detail-tab').waitFor({ state: 'visible' });
    await page.getByTestId('ideas-tab-catalog').click();
    await rows.nth(1).click();
    await page.locator('[data-testid="ideas-tab-idea"]').nth(1).waitFor({ state: 'visible' });
  }
  if (route === 'library' && detail === 'tabs') {
    await page.getByTestId('library-scope-global').click();
    await page.getByTestId('global-library-view').waitFor({ state: 'visible' });
    const rows = page.locator('[data-testid^="global-library-item-"]');
    await rows.first().waitFor({ state: 'visible' });
    await rows.nth(0).dblclick();
    await page.getByTestId('library-workspace-tabs').waitFor({ state: 'visible' });
    await page.getByTestId('library-workspace-tab-library').click();
    await rows.nth(1).dblclick();
    await page.locator('[data-testid^="library-workspace-tab-document-"]').nth(1).waitFor({ state: 'visible' });
  }
  if (route === 'settings' && detail === 'server') {
    await page.getByRole('button', { name: 'Servidor', exact: true }).click();
    await page.getByTestId('nodus-server-mode-switch').waitFor({ state: 'visible' });
  }
  if (route === 'settings' && detail === 'mobile') {
    await page.getByRole('button', { name: 'Conexión móvil', exact: true }).click();
    const pairing = page.getByRole('region', { name: 'Vincular móvil', exact: true });
    await pairing.getByRole('button', { name: 'Generar código y QR', exact: true }).click();
    await pairing.getByRole('img', { name: 'Código QR para vincular Nodus', exact: true }).waitFor({ state: 'visible' });
    await pairing.getByRole('link', { name: 'Abrir enlace de vinculación', exact: true }).waitFor({ state: 'visible' });
  }
  if (route === 'deepResearch') {
    const demoTitle = 'Informe profundo · ciencia del aprendizaje';
    await page.getByRole('heading', { name: 'Deep Research', exact: true }).waitFor({ state: 'visible' });
    await page.getByRole('button', { name: demoTitle, exact: true }).waitFor({ state: 'visible' });
    if (detail === 'reader') {
      const demoCard = page.locator('[data-anchor-id="demo-deep-research-draft"]');
      await demoCard.getByRole('button', { name: 'Leer', exact: true }).click();
      await page.getByRole('heading', { name: demoTitle, exact: true }).waitFor({ state: 'visible' });
    }
  }
  await page.waitForTimeout(350);
  await page.screenshot({ path: output });
  console.log(output);
} catch (error) {
  const page = app && (await app.windows())[0];
  if (page) await page.screenshot({ path: output.replace(/\.png$/, '-failed.png') }).catch(() => {});
  throw error;
} finally {
  if (app) await app.close();
  fs.rmSync(recoveryRoot, { recursive: true, force: true });
  fs.rmSync(userData, { recursive: true, force: true });
}
