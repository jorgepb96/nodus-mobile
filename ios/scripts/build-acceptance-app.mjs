#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {mobileRoot} from './nodus-repo.mjs';
import {acceptanceSourceRevision, nativeAcceptanceArtifacts} from './acceptance-evidence.mjs';

const [attempt, device, derivedData, target = 'simulator'] = process.argv.slice(2);
if (!attempt || !/^[a-z0-9-]+$/.test(attempt) || !device || !derivedData || !path.isAbsolute(derivedData) || !['simulator', 'physical'].includes(target))
  throw new Error('Usage: build-acceptance-app.mjs unique-attempt device-ID absolute-derived-data [simulator|physical]');
const result = path.join(mobileRoot, 'artifacts/acceptance-0.1.0/local-' + new Date().toISOString().slice(0, 10), attempt + '.xcresult');
if (fs.existsSync(result)) throw new Error('Build evidence cannot be overwritten.');
fs.mkdirSync(path.dirname(result), {recursive: true});
const app = path.join(derivedData, 'Build/Products', target === 'physical' ? 'Debug-iphoneos' : 'Debug-iphonesimulator', 'Nodus.app');
const receipt = app + '.acceptance-build.json';
fs.rmSync(receipt, {force: true});
const before = acceptanceSourceRevision(mobileRoot);
const code = await new Promise((resolve, reject) => {
  const child = spawn('xcodebuild', ['build-for-testing', '-project', 'ios/Nodus.xcodeproj', '-scheme', 'Nodus',
    '-destination', `platform=${target === 'physical' ? 'iOS' : 'iOS Simulator'},id=${device}`, '-derivedDataPath', derivedData, '-resultBundlePath', result],
    {cwd: mobileRoot, stdio: 'inherit'});
  child.on('error', reject);
  child.on('exit', (code, signal) => signal ? reject(new Error(`Native build terminated: ${signal}`)) : resolve(code));
});
if (code !== 0) process.exit(code ?? 1);
const after = acceptanceSourceRevision(mobileRoot);
if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error('Native sources changed during compilation; no acceptance build receipt was issued.');
const canonicalApp = fs.realpathSync(app);
fs.writeFileSync(canonicalApp + '.acceptance-build.json', JSON.stringify({version: 1, builtApp: canonicalApp,
  completedAt: new Date().toISOString(), revision: before, artifacts: nativeAcceptanceArtifacts(canonicalApp), resultBundle: result}, null, 2) + '\n');
console.log('Successful native build is bound to its exact source revision and signed artifacts.');
