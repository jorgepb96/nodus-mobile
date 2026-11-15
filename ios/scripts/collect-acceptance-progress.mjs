#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mobileRoot,nodusRepo} from './nodus-repo.mjs';
import {acceptanceResultPaths,acceptanceReceiptPath,acceptanceSourceRevision as sourceRevision,userPhysicalValidation} from './acceptance-evidence.mjs';

// Historical attempts remain evidence of their actual result. Inventory and
// successful individual scenarios never automatically approve an operation.
const folder=path.join(mobileRoot,'artifacts/acceptance-0.1.0');
fs.mkdirSync(folder,{recursive:true});
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const manifest=JSON.parse(fs.readFileSync(path.join(mobileRoot,'ios/Parity/parity-manifest.json'),'utf8'));
const appleRecordPath=path.join(folder,'app-store-connect-record.json');
const appleRecord=fs.existsSync(appleRecordPath)?JSON.parse(fs.readFileSync(appleRecordPath,'utf8')):null;
const summaries=path.join(folder,'xctest-summaries');fs.mkdirSync(summaries,{recursive:true});
const attempts=[];
for(const name of acceptanceResultPaths(folder)) {
  const artifact=path.join(folder,name),output=path.join(summaries,name.replace('.xcresult','.json'));
  try {
    const summary=JSON.parse(execFileSync('xcrun',['xcresulttool','get','test-results','summary','--path',artifact],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));
    fs.mkdirSync(path.dirname(output),{recursive:true});
    fs.writeFileSync(output,JSON.stringify(summary,null,2)+'\n');
    attempts.push({artifact:name,result:summary.result,executed:summary.totalTestCount,passed:summary.passedTests,
      failed:summary.failedTests,skipped:summary.skippedTests,expectedFailures:summary.expectedFailures,
      devices:summary.devicesAndConfigurations?.map(row=>row.device),
      summary:{path:path.relative(folder,output),sha256:sha(fs.readFileSync(output))},
      approval:summary.result==='Passed' && summary.totalTestCount>0 && summary.failedTests===0 && summary.skippedTests===0 && summary.expectedFailures===0 ? 'scenarioOnly' : 'notPassed'});
  } catch(error) {attempts.push({artifact:name,result:'unreadable',approval:'notPassed',error:String(error.message).slice(0,200)});}
}
const logs=path.join(folder,'logs');fs.mkdirSync(logs,{recursive:true});
const logEvidence=[];
for(const name of fs.readdirSync('/tmp').filter(name=>/^nodus-010-.*\.log$/.test(name)).sort()) {
  const source=path.join('/tmp',name);if(!fs.statSync(source).isFile())continue;
  const bytes=fs.readFileSync(source);
  // Never collect a file containing a pairing link or bearer/API secret. Those
  // temporary laboratory inputs are intentionally excluded from the evidence.
  if(/nodus:\/\/pair\?|Bearer [A-Za-z0-9_+\/-]{24}|sk-[A-Za-z0-9]{16}/.test(bytes.toString()))continue;
  const output=path.join(logs,name);fs.writeFileSync(output,bytes);
  logEvidence.push({path:path.relative(folder,output),sha256:sha(bytes)});
}
const physicalAttempts=attempts.filter(attempt=>attempt.devices?.some(device=>device.platform==='iOS' && device.deviceId==='00008140-000C052C229B001C'));
const passingPhysical=physicalAttempts.filter(attempt=>attempt.approval==='scenarioOnly');
const physicalHandoff={...userPhysicalValidation,executed:0,skipped:0,failed:0,evidence:[]};
const physicalHistory={attempts:physicalAttempts.map(attempt=>attempt.artifact),passingScenarios:passingPhysical.length};
const physicalText='Por indicación del usuario, él realizará las pruebas en el iPhone físico después de recibir la beta en TestFlight. Esta validación queda pendiente a su cargo; las ejecuciones históricas se conservan por separado y no se atribuyen a la versión actual.';
const coveragePath=path.join(folder,'acceptance-scenario-coverage.json');
const coverage=fs.existsSync(coveragePath)?JSON.parse(fs.readFileSync(coveragePath,'utf8')):{version:1,scenarios:[]};
const operationIds=new Set(manifest.operations.map(operation=>operation.id));
const scenarioIds=new Set();
function evidenceFile(relative) {
  if(typeof relative!=='string'||!relative)throw new Error('A non-empty scenario evidence path is required');
  const absolute=path.resolve(folder,relative);
  if(!absolute.startsWith(folder+path.sep)||!fs.existsSync(absolute)||!fs.statSync(absolute).isFile())throw new Error(`Missing or unsafe scenario evidence: ${relative}`);
  return {path:relative,sha256:sha(fs.readFileSync(absolute))};
}
const scenarios=coverage.scenarios.map(scenario=>{
  if(!scenario.id||scenarioIds.has(scenario.id)||!scenario.operationIds?.length||!scenario.attempts?.length||!scenario.scope||!scenario.remaining)throw new Error('Incomplete or duplicate scenario coverage');
  scenarioIds.add(scenario.id);
  if(scenario.operationIds.some(id=>!operationIds.has(id)))throw new Error(`Unknown operation in scenario ${scenario.id}`);
  const results=scenario.attempts.map(artifact=>{
    const attempt=attempts.find(item=>item.artifact===artifact);
    if(attempt?.approval!=='scenarioOnly')throw new Error(`Scenario ${scenario.id} references an attempt that did not pass: ${artifact}`);
    return attempt;
  });
  const reviewPaths=scenario.reviews ?? [scenario.review];
  if(!Array.isArray(reviewPaths)||!reviewPaths.length)throw new Error(`Missing reviews for scenario ${scenario.id}`);
  const reviews=reviewPaths.map(evidenceFile);
  const receipts=results.map(attempt=>evidenceFile(acceptanceReceiptPath(folder,attempt.artifact)));
  return {...scenario,result:'historicalScenarioPassed',completeOperation:false,releaseApproved:false,
    executed:results.reduce((sum,item)=>sum+item.executed,0),evidence:[...reviews,...receipts,...results.map(item=>item.summary)]};
});
const operations=manifest.operations.map(operation=>{
  const partialScenarios=scenarios.filter(scenario=>scenario.operationIds.includes(operation.id));
  const artifacts=[...new Set(partialScenarios.flatMap(scenario=>scenario.attempts))];
  if(operation.id===userPhysicalValidation.operation)return {id:operation.id,category:operation.category,...physicalHandoff};
  return {id:operation.id,category:operation.category,result:'pending',
    executed:artifacts.reduce((sum,artifact)=>sum+attempts.find(item=>item.artifact===artifact).executed,0),skipped:0,
    evidence:[...new Set(partialScenarios.flatMap(scenario=>[...scenario.attempts,...scenario.evidence.map(item=>item.path)]))],
    partialScenarios:partialScenarios.map(scenario=>({id:scenario.id,scope:scenario.scope,remaining:scenario.remaining})),
    coveragePolicy:'Passed historical scenarios are partial evidence; the complete operation and current release remain pending.'};
});
const report={version:1,updatedAt:new Date().toISOString(),releaseReady:false,
  referenceCommits:manifest.referenceCommits,
  observedSourceRevisions:{desktop:sourceRevision(nodusRepo()),mobile:sourceRevision(mobileRoot)},
  sourceRevisionPolicy:'Current inventory digests are not retroactively attributed to historical test runs.',
  operations,scenarios,
  attempts,logEvidence,appleRecord,userValidation:{physicalIphone:physicalHandoff},physicalHistory,
  blockers:[
    {id:'appStoreConnect',result:'pending',evidence:appleRecord?'app-store-connect-record.json':undefined,reason:appleRecord?.appRecord==='created'?'The Nodus app record was created using the integrated browser. Upload, processing and internal TestFlight availability remain pending full acceptance.':'App record, authenticated Apple session, upload and internal availability remain unverified.'},
    {id:'fullAcceptance',result:'pending',reason:'Every included operation and required Desktop/iPhone/iPad simulator environment must be executed before release. Physical iPhone validation is assigned to the user after TestFlight. Individual passing scenarios do not establish complete parity.'}]};
fs.writeFileSync(path.join(folder,'acceptance-progress.json'),JSON.stringify(report,null,2)+'\n');
const passed=attempts.filter(item=>item.approval==='scenarioOnly').length;
fs.writeFileSync(path.join(folder,'acceptance-progress.md'),`# Nodus Mobile 0.1.0 · validación en curso\n\nEstado: **no apta todavía para TestFlight**.\n\nReferencias: Desktop \`${manifest.referenceCommits.desktop}\`; móvil \`${manifest.referenceCommits.mobile}\`.\n\n${passed} ejecuciones XCTest con resultado satisfactorio; ${attempts.length-passed} intentos fallidos o no legibles. Cada ejecución conserva su resultado real en los resúmenes y archivos .xcresult. Las operaciones completas siguen pendientes hasta terminar su cobertura.\n\n| Operación | Categoría | Resultado | Casos documentados |\n|---|---|---|---|\n${report.operations.map(item=>`| ${item.id} | ${item.category} | ${item.result==='pendingUserValidation'?'Pendiente del usuario en TestFlight':'Pendiente'} | ${item.executed} |`).join('\n')}\n\n${scenarios.map(scenario=>`- **${scenario.id}**: ${scenario.scope} Evidencia: ${(scenario.reviews??[scenario.review]).map((review,index)=>`[revisión ${index+1}](${review})`).join(', ')}. Pendiente: ${Array.isArray(scenario.remaining)?scenario.remaining.join('; '):scenario.remaining}`).join('\n')}\n\n${physicalText} ${appleRecord?.appRecord==='created'?'La ficha de Nodus está creada en App Store Connect desde el navegador integrado; todavía no hay compilación disponible en TestFlight.':'La ficha y la entrega en TestFlight siguen pendientes.'}\n`);
console.log(JSON.stringify({operations:report.operations.length,xctestAttempts:attempts.length,passingScenarios:passed,logs:logEvidence.length,releaseReady:false}));
