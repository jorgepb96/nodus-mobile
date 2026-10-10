import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {mobileRoot,nodusRepo} from './nodus-repo.mjs';

const {connectAcceptanceBridge}=await import(pathToFileURL(path.join(nodusRepo(),'scripts/lib/mobileAcceptanceClient.mjs')));
const folder=path.join(mobileRoot,'artifacts/acceptance-0.1.0');
const lab=process.env.NODUS_MOBILE_ACCEPTANCE_LAB;
assert(lab && fs.existsSync(path.join(lab,'.nodus-mobile-acceptance-lab')),'An isolated laboratory is required');
const snapshotBytes=fs.readFileSync(path.join(lab,'dictionary-snapshot.json'));
const snapshot=JSON.parse(snapshotBytes);
assert(Array.isArray(snapshot.assets) && snapshot.assets.length,'Actual saved research illustrations are required');
const output=path.join(folder,'downloaded-published-images');fs.mkdirSync(output,{recursive:true});
const client=await connectAcceptanceBridge('Published image consultation acceptance');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const files=new Map();
try {
  for(const ref of snapshot.assets) for(const [hash,bytes,mime] of [[ref.hash,ref.bytes,ref.mime],[ref.thumbHash,ref.thumbBytes,ref.thumbMime]]) {
    if(!hash)continue;
    assert(/^[a-f0-9]{64}$/.test(hash));
    if(files.has(hash)){if(bytes)assert.equal(files.get(hash).bytes,bytes);continue;}
    const data=await client.binary(`${client.root}/corpus/assets/${hash}`);
    assert.equal(sha(data),hash,'Bridge bytes must match the published image');
    if(bytes)assert.equal(data.length,bytes);
    fs.writeFileSync(path.join(output,hash),data,{mode:0o600});
    files.set(hash,{hash,bytes:data.length,mime});
  }
  const report=snapshot.tables.writing_saved_drafts.find(row=>row.title.includes('La mirada extranjera sobre la España franquista'));
  assert(report);
  const image=snapshot.assets.find(ref=>ref.table==='decorative_images' && ref.key?.[0]==='deep_research' && ref.key?.[1]===report.id);assert(image);
  const result={passed:true,transport:'production pinned HTTPS',snapshotSha256:sha(snapshotBytes),vaultId:client.vault.id,
    reportId:report.id,reportTitle:report.title,reportImageHash:image.hash,assets:[...files.values()],recordedAt:new Date().toISOString()};
  fs.writeFileSync(path.join(folder,'downloaded-published-images.json'),JSON.stringify(result,null,2)+'\n');
  console.log(JSON.stringify({passed:true,images:files.size,bytes:[...files.values()].reduce((sum,file)=>sum+file.bytes,0),reportImageHash:image.hash}));
} finally {await client.close();}
