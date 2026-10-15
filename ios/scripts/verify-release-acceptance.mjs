#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mobileRoot, nodusRepo } from './nodus-repo.mjs';
import {acceptanceRevisionIssues, nativeAcceptanceRunIssues, requiredAcceptanceEnvironments, userPhysicalValidation, userValidationHandoffIssues, nativeAcceptanceDeviceIssues} from './acceptance-evidence.mjs';
import {isDeferredBetaAI, betaAIScope} from './beta-ai-scope.mjs';

const manifest = JSON.parse(fs.readFileSync(path.join(mobileRoot, 'ios/Parity/parity-manifest.json'), 'utf8'));
const input = process.argv[2];
if (!input || !fs.existsSync(input)) {
  console.error('Release blocked: an executed acceptance campaign is required. No missing configuration or omitted operation can count as a pass.');
  process.exit(1);
}
const campaign = JSON.parse(fs.readFileSync(input, 'utf8'));
const issues = [];
if (JSON.stringify(manifest.betaAIScope) !== JSON.stringify(betaAIScope)) issues.push('The beta AI scope does not match the explicit user decision.');
for (const [repo, commit] of Object.entries(manifest.referenceCommits)) {
  if (campaign.referenceCommits?.[repo] !== commit) issues.push(`Missing reference commit: ${repo}`);
}
issues.push(...acceptanceRevisionIssues(campaign.revisionDigests,{desktop:nodusRepo(),mobile:mobileRoot}));
issues.push(...userValidationHandoffIssues(campaign));
for (const operation of manifest.operations.filter(operation => operation.category !== 'desktopExclusive' && operation.id !== userPhysicalValidation.operation)) {
  const result = campaign.operations?.find(item => item.id === operation.id);
  const deferred = !operation.id.endsWith('.betaGate') && isDeferredBetaAI(operation.id);
  if (deferred) {
    if (operation.result !== 'deferredByUser' || operation.requiredInBeta !== false || operation.implementation !== 'retained' ||
        !result || result.result !== 'deferredByUser' || result.executed !== 0 || result.skipped !== 0 || (result.evidence?.length ?? 0) !== 0)
      issues.push(`Deferred AI must remain unavailable, retained and untested in this campaign: ${operation.id}`);
    continue;
  }
  if (operation.requiredInBeta === false || operation.result === 'deferredByUser') issues.push(`No user deferral exists for: ${operation.id}`);
  if (!result || result.result !== 'passed' || result.executed < 1 || result.skipped !== 0) {
    issues.push(`Not verified: ${operation.id}`); continue;
  }
  if (!result.evidence?.length) { issues.push(`No evidence: ${operation.id}`); continue; }
  for (const evidence of result.evidence) {
    const file = path.resolve(path.dirname(input), evidence.path);
    if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) { issues.push(`Missing evidence: ${evidence.path}`); continue; }
    const digest = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    if (digest !== evidence.sha256) issues.push(`Evidence changed: ${evidence.path}`);
  }
}
for (const required of requiredAcceptanceEnvironments) {
  const run = campaign.environments?.[required];
  if (!run?.executed || run.failed !== 0 || run.skipped !== 0 || !run.artifact) issues.push(`Unverified environment: ${required}`);
  if (run?.artifact) {
    const artifact = path.resolve(path.dirname(input), run.artifact);
    if (!fs.existsSync(artifact)) { issues.push(`Missing environment artifact: ${required}`); continue; }
    if (required !== 'desktop') {
      try {
        const result = JSON.parse(execFileSync('xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', artifact], { encoding: 'utf8' }));
        if (!run.sourceReceipt) issues.push(`Missing native compiled-source evidence: ${required}`);
        else {
          const receipt = JSON.parse(fs.readFileSync(path.resolve(path.dirname(input), run.sourceReceipt), 'utf8'));
          issues.push(...nativeAcceptanceRunIssues(receipt, campaign.revisionDigests, result.startTime).map(issue => `${required}: ${issue}`));
        }
        if (result.result !== 'Passed' || result.totalTestCount < 1 || result.failedTests !== 0 || result.skippedTests !== 0 || result.expectedFailures !== 0 || result.passedTests !== run.executed) issues.push(`Actual XCTest result does not pass: ${required}`);
        issues.push(...nativeAcceptanceDeviceIssues(required, result));
      } catch { issues.push(`Unreadable XCTest evidence: ${required}`); }
    } else if (!run.sha256 || fs.statSync(artifact).isDirectory() || createHash('sha256').update(fs.readFileSync(artifact)).digest('hex') !== run.sha256) issues.push('Desktop evidence digest is missing or changed.');
  }
}
if (issues.length) { console.error(`Release blocked (${issues.length} checks):\n${issues.join('\n')}`); process.exit(1); }
console.log('Executed acceptance campaign passed. This permits archiving; Apple processing and TestFlight availability still need verification.');
