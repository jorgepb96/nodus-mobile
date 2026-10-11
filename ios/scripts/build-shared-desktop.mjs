#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const mobile = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const desktop = path.resolve(process.argv.slice(2).find(argument => !argument.startsWith('--')) ?? path.join(mobile, '../nodus'));
const output = path.join(mobile, 'ios/Nodus/Resources/SharedDesktop');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function sourceDigest() {
  const files = [];
  const walk = relative => {
    const absolute = path.join(desktop, relative);
    for (const entry of fs.readdirSync(absolute, { withFileTypes: true })) {
      const name = path.join(relative, entry.name);
      if (entry.isDirectory()) walk(name);
      else if (entry.isFile()) files.push(name);
    }
  };
  walk('src'); walk('shared');
  walk('server/lib/core'); walk('skill-capabilities');
  // These provider-free cores are imported by the renderer and therefore belong
  // to the exact source revision represented by this bundle.
  files.push('electron/ai/deepResearchCore.ts', 'electron/ai/immersionCore.ts');
  files.push('package.json', 'package-lock.json', 'vite.mobile-web.config.ts', 'tailwind.config.js', 'postcss.config.js');
  const digest = createHash('sha256');
  for (const file of files.sort()) { digest.update(file); digest.update('\0'); digest.update(fs.readFileSync(path.join(desktop, file))); digest.update('\0'); }
  return digest.digest('hex');
}
const digest = sourceDigest();
if (process.argv.includes('--verify')) {
  const metadata = JSON.parse(fs.readFileSync(path.join(output, 'build.json'), 'utf8'));
  if (metadata.sourceDigest !== digest) throw new Error('Shared Desktop sources changed. Rebuild the mobile surfaces before release.');
  for (const [file, sha] of Object.entries(metadata.files)) if (hash(fs.readFileSync(path.join(output, file))) !== sha) throw new Error(`Shared bundle changed: ${file}`);
  console.log('Shared Desktop bundle matches its recorded source and output digests.');
} else {
  execFileSync(process.execPath, [path.join(desktop, 'node_modules/vite/bin/vite.js'), 'build', '--config', 'vite.mobile-web.config.ts'],
    { cwd: desktop, env: { ...process.env, NODUS_MOBILE_SURFACE_OUT: output }, stdio: 'inherit' });
  execFileSync(path.join(desktop, 'node_modules/esbuild/bin/esbuild'), [path.join(desktop, 'shared/deepResearchReport.ts'),
    '--bundle', '--platform=browser', '--format=iife', '--global-name=NodusReport', '--target=es2020',
    '--outfile='+path.join(output,'report-renderer.js')], {cwd:desktop,stdio:'inherit'});
  execFileSync(path.join(desktop, 'node_modules/esbuild/bin/esbuild'), [path.join(desktop,'shared/companionChatContext.ts'),
    '--bundle','--platform=browser','--format=iife','--global-name=NodusCompanionChat','--target=es2020',
    '--outfile='+path.join(output,'companion-chat.js')],{cwd:desktop,stdio:'inherit'});
  if (sourceDigest() !== digest) throw new Error('Shared sources changed during the build. Repeat the build before accepting it.');
  const files = Object.fromEntries(fs.readdirSync(output).filter(file => file !== 'build.json' && fs.statSync(path.join(output, file)).isFile()).map(file => [file, hash(fs.readFileSync(path.join(output, file)))]));
  fs.writeFileSync(path.join(output, 'build.json'), JSON.stringify({ version: 1, desktopCommit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: desktop, encoding: 'utf8' }).trim(), sourceDigest: digest, files }, null, 2) + '\n');
}
