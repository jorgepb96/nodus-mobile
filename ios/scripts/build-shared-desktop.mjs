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
function outputFiles(relative='') {
  return fs.readdirSync(path.join(output,relative),{withFileTypes:true}).flatMap(entry=>{
    const file=path.join(relative,entry.name);
    return entry.isDirectory()?outputFiles(file):entry.isFile()&&file!=='build.json'?[file]:[];
  }).sort();
}
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
  walk('src'); walk('shared'); walk('packages/capability-api/src');
  walk('server/lib/core'); walk('skill-capabilities');
  // These provider-free cores are imported by the renderer and therefore belong
  // to the exact source revision represented by this bundle.
  files.push('electron/ai/deepResearchCore.ts', 'electron/ai/immersionCore.ts');
  files.push('electron/ai/completeGuide/core.ts', 'electron/ai/completeGuide/prompts.ts');
  files.push('package.json', 'package-lock.json', 'vite.mobile-web.config.ts', 'tailwind.config.js', 'postcss.config.js');
  const digest = createHash('sha256');
  digest.update('mobile-build-script\0');digest.update(fs.readFileSync(fileURLToPath(import.meta.url)));digest.update('\0');
  for (const file of files.sort()) { digest.update(file); digest.update('\0'); digest.update(fs.readFileSync(path.join(desktop, file))); digest.update('\0'); }
  return digest.digest('hex');
}
const digest = sourceDigest();
if (process.argv.includes('--verify')) {
  const metadata = JSON.parse(fs.readFileSync(path.join(output, 'build.json'), 'utf8'));
  if (metadata.sourceDigest !== digest) throw new Error('Shared Desktop sources changed. Rebuild the mobile surfaces before release.');
  if(JSON.stringify(outputFiles())!==JSON.stringify(Object.keys(metadata.files).sort()))throw new Error('Shared bundle file inventory changed. Rebuild before release.');
  for (const [file, sha] of Object.entries(metadata.files)) if (hash(fs.readFileSync(path.join(output, file))) !== sha) throw new Error(`Shared bundle changed: ${file}`);
  console.log('Shared Desktop bundle matches its recorded source and output digests.');
} else {
  execFileSync(process.execPath, [path.join(desktop, 'node_modules/vite/bin/vite.js'), 'build', '--config', 'vite.mobile-web.config.ts'],
    { cwd: desktop, env: { ...process.env, NODUS_MOBILE_SURFACE_OUT: output, NODUS_MOBILE_CHAT_READ:'0', NODUS_MOBILE_PROSE_READ:'0', NODUS_MOBILE_MAP_READ:'0' }, stdio: 'inherit' });
  execFileSync(process.execPath,[path.join(desktop,'node_modules/vite/bin/vite.js'),'build','--config','vite.mobile-web.config.ts'],
    {cwd:desktop,env:{...process.env,NODUS_MOBILE_SURFACE_OUT:output,NODUS_MOBILE_CHAT_READ:'1',NODUS_MOBILE_PROSE_READ:'0',NODUS_MOBILE_MAP_READ:'0'},stdio:'inherit'});
  execFileSync(process.execPath,[path.join(desktop,'node_modules/vite/bin/vite.js'),'build','--config','vite.mobile-web.config.ts'],
    {cwd:desktop,env:{...process.env,NODUS_MOBILE_SURFACE_OUT:output,NODUS_MOBILE_CHAT_READ:'0',NODUS_MOBILE_PROSE_READ:'1',NODUS_MOBILE_MAP_READ:'0'},stdio:'inherit'});
  execFileSync(process.execPath,[path.join(desktop,'node_modules/vite/bin/vite.js'),'build','--config','vite.mobile-web.config.ts'],
    {cwd:desktop,env:{...process.env,NODUS_MOBILE_SURFACE_OUT:output,NODUS_MOBILE_CHAT_READ:'0',NODUS_MOBILE_PROSE_READ:'0',NODUS_MOBILE_MAP_READ:'1'},stdio:'inherit'});
  execFileSync(path.join(desktop, 'node_modules/esbuild/bin/esbuild'), [path.join(desktop, 'shared/deepResearchReport.ts'),
    '--bundle', '--platform=browser', '--format=iife', '--global-name=NodusReport', '--target=es2020',
    '--outfile='+path.join(output,'report-renderer.js')], {cwd:desktop,stdio:'inherit'});
  execFileSync(path.join(desktop, 'node_modules/esbuild/bin/esbuild'), [path.join(desktop,'shared/companionChatContext.ts'),
    '--bundle','--platform=browser','--format=iife','--global-name=NodusCompanionChat','--target=es2020',
    '--outfile='+path.join(output,'companion-chat.js')],{cwd:desktop,stdio:'inherit'});
  execFileSync(path.join(desktop,'node_modules/esbuild/bin/esbuild'),[path.join(desktop,'shared/companionDatabaseContainer.ts'),
    '--bundle','--platform=browser','--format=iife','--global-name=NodusDatabaseQuery','--target=es2020',
    '--outfile='+path.join(output,'database-query.js')],{cwd:desktop,stdio:'inherit'});
  fs.writeFileSync(path.join(output,'database-query.html'),"<!doctype html><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\"><script src='./database-query.js'></script>");
  if (sourceDigest() !== digest) throw new Error('Shared sources changed during the build. Repeat the build before accepting it.');
  const files = Object.fromEntries(outputFiles().map(file => [file, hash(fs.readFileSync(path.join(output, file)))]));
  fs.writeFileSync(path.join(output, 'build.json'), JSON.stringify({ version: 1, desktopCommit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: desktop, encoding: 'utf8' }).trim(), sourceDigest: digest, files }, null, 2) + '\n');
}
