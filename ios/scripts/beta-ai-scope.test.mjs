import assert from 'node:assert/strict';
import {test} from 'node:test';
import {applyBetaAIScope, betaAIScope, isDeferredBetaAI} from './beta-ai-scope.mjs';

test('only phone AI generation and its deferred resume controls leave beta acceptance', () => {
  for (const id of ['generation.chat.autonomous', 'sync.chat.autonomousPartialRecovery', 'generation.deepResearch.chosenDownloadedSources']) {
    const row = applyBetaAIScope({id, category: 'generation', result: 'pending', evidence: []});
    assert.equal(row.result, 'deferredByUser'); assert.equal(row.requiredInBeta, false); assert.equal(row.implementation, 'retained');
  }
  for (const id of ['generation.chat.live', 'generation.deepResearch.live', 'audio.savedConsultation',
    'sync.studyIdeas.offlineCreationAndReconnection', 'writing.studyIdeas.ideaAndRelationToStructuredNote', 'transport.disconnect']) {
    assert.equal(isDeferredBetaAI(id), false, id);
    const row = {id, result: 'pending'}; assert.equal(applyBetaAIScope(row), row);
  }
  assert.equal(betaAIScope.offlineReadingAndManualWriting, true);
  assert.equal(betaAIScope.autonomousGeneration, false);
  assert.equal(betaAIScope.audioGeneration, false);
});
