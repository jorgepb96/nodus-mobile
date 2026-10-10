#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {mobileRoot,nodusRepo} from './nodus-repo.mjs';

// Compare the same isolated real report with the production Desktop printer.
// No providers, production vaults or normal Desktop profile are opened.
const lab=process.env.NODUS_MOBILE_ACCEPTANCE_LAB;
if(!lab || !fs.existsSync(path.join(lab,'.nodus-mobile-acceptance-lab')))throw new Error('A marked isolated acceptance laboratory is required.');
const attempt=process.argv[2];
if(!attempt || !/^[a-z0-9-]+$/.test(attempt))throw new Error('A unique acceptance attempt name is required.');
const output=path.join(mobileRoot,'artifacts/acceptance-0.1.0',attempt+'.pdf');
if(fs.existsSync(output))throw new Error('Existing PDF evidence must not be overwritten.');
const root=nodusRepo(),cache=path.join(root,'node_modules/.cache/nodus-mobile-pdf-acceptance');
fs.mkdirSync(cache,{recursive:true});
fs.writeFileSync(path.join(cache,'package.json'),JSON.stringify({name:'nodus-mobile-pdf-acceptance',version:'0.1.0',main:'print.cjs'})+'\n');
const entry=path.join(cache,'print.ts'),bundle=path.join(cache,'print.cjs');
fs.writeFileSync(entry,`
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {app} from 'electron';
import {deepResearchReportInput} from ${JSON.stringify(path.join(root,'shared/deepResearchReport.ts'))};
import {professionalReportPdf} from ${JSON.stringify(path.join(root,'electron/export/professionalReportPdf.ts'))};
const lab=process.env.NODUS_MOBILE_ACCEPTANCE_LAB!;
console.log('Starting the isolated production Desktop PDF printer.');
fs.writeFileSync(path.join(lab,'pdf-printer-started.json'),JSON.stringify({pid:process.pid,startedAt:new Date().toISOString()}));
app.setPath('userData',path.join(lab,'pdf-print-host'));
// The production app retains its main window while pdf-lib stamps the result.
// This headless printer must likewise stay alive after its print window closes.
app.on('window-all-closed',()=>{});
app.whenReady().then(async()=>{
 try {
  const snapshot=JSON.parse(fs.readFileSync(path.join(lab,'dictionary-snapshot.json'),'utf8'));
  const row=snapshot.tables.writing_saved_drafts.find((row:any)=>row.id==='6c566fc2-c2c9-4415-88f6-90bc161769a2');
  if(!row)throw new Error('The real report fixture is missing.');
  const hash='9413600ed444d9524b49319801b1b7c453accbb6874de99eab8d175d346f4470';
  const bytes=fs.readFileSync(${JSON.stringify(path.join(mobileRoot,'artifacts/acceptance-0.1.0/downloaded-published-images'))}+'/'+hash);
  if(createHash('sha256').update(bytes).digest('hex')!==hash)throw new Error('Cover image hash mismatch.');
  const asset=snapshot.assets.find((asset:any)=>asset.hash===hash);
  if(!asset)throw new Error('The image is not referenced in this publication.');
  const input=deepResearchReportInput(JSON.parse(row.draft_json),{dataUrl:'data:'+asset.mime+';base64,'+bytes.toString('base64'),credit:null});
  const pdf=await professionalReportPdf(input);
  fs.writeFileSync(process.env.NODUS_ACCEPTANCE_PDF_OUTPUT!,pdf);
  console.log(JSON.stringify({reportId:row.id,bytes:pdf.length,sha256:createHash('sha256').update(pdf).digest('hex'),printer:'production Desktop professionalReportPdf'}));
  app.quit();
 }catch(error){console.error(error);app.exit(1);}
});
`);
execFileSync(path.join(root,'node_modules/esbuild/bin/esbuild'),[entry,'--bundle','--platform=node','--format=cjs','--packages=external','--tsconfig='+path.join(root,'tsconfig.json'),'--outfile='+bundle],{cwd:root,stdio:'inherit'});
execFileSync(path.join(root,'node_modules/electron/dist/Electron.app/Contents/MacOS/Electron'),[cache],{
 cwd:root,env:{...process.env,NODUS_ACCEPTANCE_PDF_OUTPUT:output},stdio:'inherit'});
if(!fs.existsSync(output) || fs.statSync(output).size===0)throw new Error('The production Desktop printer did not create the requested PDF.');
