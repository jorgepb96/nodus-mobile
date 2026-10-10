import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {mobileRoot, nodusRepo} from './nodus-repo.mjs';

// Compare the independently maintained server read contract, including routes
// whose special dossier uses a domain name rather than a singular URL segment.
const server=fs.readFileSync(path.join(nodusRepo(),'server/lib/routes/corpus.mjs'),'utf8').split('const COLLECTIONS = {')[1]?.split('\n};')[0];
assert(server,'The Desktop public collection registry must exist');
const swift=fs.readFileSync(path.join(mobileRoot,'ios/Packages/NodusKit/Sources/NodusKit/Core/Collections.swift'),'utf8');
const expected=[...server.matchAll(/^\s*(?:'([^']+)'|([a-z][a-z-]*)):\s*\{ table: '([^']+)', key: '([^']+)', id: '([^']+)' \}/gm)]
  .map(([,quoted,bare,table,key,id])=>[quoted??bare,table,key,id]).sort(([a],[b])=>a.localeCompare(b));
const actual=[...swift.matchAll(/\.init\(path: "([^"]+)", table: "([^"]+)", listKey: "([^"]+)", idField: "([^"]+)"/g)]
  .map(([,route,table,key,id])=>[route,table,key,id]).sort(([a],[b])=>a.localeCompare(b));
assert(expected.length>0,'No empty inventory can pass');
assert.deepEqual(actual,expected,'iOS must retain every public collection, its response key and canonical identity');
console.log(JSON.stringify({suite:'collection-descriptors',executed:1,passed:1,failed:0,skipped:0,collections:expected.length}));
