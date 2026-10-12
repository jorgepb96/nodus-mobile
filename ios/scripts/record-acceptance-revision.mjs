#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mobileRoot,nodusRepo} from './nodus-repo.mjs';
import {acceptanceSourceRevision as revision, verifyNativeAcceptanceBuild} from './acceptance-evidence.mjs';

const name=process.argv[2];
if(!name || !/^[a-z0-9-]+$/.test(name))throw new Error('A unique, safe acceptance attempt name is required.');
const folder=path.join(mobileRoot,'artifacts/acceptance-0.1.0');fs.mkdirSync(folder,{recursive:true});
const output=path.join(folder,name+'.source.json');
if(fs.existsSync(output))throw new Error('An acceptance source receipt cannot be overwritten. Use a new attempt name.');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const manifest=JSON.parse(fs.readFileSync(path.join(mobileRoot,'ios/Parity/parity-manifest.json'),'utf8'));
const bundle=path.join(mobileRoot,'ios/Nodus/Resources/SharedDesktop');
execFileSync(process.execPath,[path.join(mobileRoot,'ios/scripts/build-shared-desktop.mjs'),'--verify'],{stdio:'pipe'});
const builtApp=process.env.NODUS_ACCEPTANCE_BUILT_APP;
const buildFiles={};
const nativeBuild={};
const nativeBuildReceipt = builtApp ? verifyNativeAcceptanceBuild(mobileRoot, builtApp) : null;
if(builtApp) {
  for(const file of ['Nodus','Nodus.debug.dylib','Info.plist']) {
    const absolute=path.join(builtApp,file);
    if(fs.existsSync(absolute))nativeBuild[file]=sha(fs.readFileSync(absolute));
  }
  const tests=path.join(path.dirname(builtApp),'NodusUITests-Runner.app/PlugIns/NodusUITests.xctest/NodusUITests');
  if(fs.existsSync(tests))nativeBuild.uiTests=sha(fs.readFileSync(tests));
}
const desktopRevision=revision(nodusRepo());
const bridgeBundle=path.join(nodusRepo(),'node_modules/.cache/nodus-mobile-acceptance/lab-bridge.cjs');
const bridgeBuild=JSON.parse(fs.readFileSync(path.join(path.dirname(bridgeBundle),'lab-bridge.build.json'),'utf8'));
if(bridgeBuild.sourceDigest !== desktopRevision.sourceDigest || bridgeBuild.bundleSha256 !== sha(fs.readFileSync(bridgeBundle)))throw new Error('The laboratory Bridge is stale. Rebuild it before recording this attempt.');
const bundledFiles=[...Object.keys(JSON.parse(fs.readFileSync(path.join(bundle,'build.json'),'utf8')).files),'build.json'];
for(const file of bundledFiles) {
  const bytes=fs.readFileSync(path.join(bundle,file));
  if(builtApp && sha(fs.readFileSync(path.join(builtApp,'SharedDesktop',file)))!==sha(bytes))throw new Error(`The built app contains a stale shared resource: ${file}`);
  buildFiles[file]=sha(bytes);
}
fs.writeFileSync(output,JSON.stringify({version:1,attempt:name,recordedBeforeExecutionAt:new Date().toISOString(),
  referenceCommits:manifest.referenceCommits,revisions:{desktop:desktopRevision,mobile:revision(mobileRoot)},
  bridgeBuild,sharedBundle:buildFiles,nativeBuild,nativeBuildReceipt,builtApp:builtApp??null},null,2)+'\n');
console.log(JSON.stringify({attempt:name,sourceReceipt:output,sharedBundleVerified:Boolean(builtApp)}));
