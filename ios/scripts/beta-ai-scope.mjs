// Explicit user scope change, 2026-10-15. Keep implementation and historical
// results; these operations are unavailable in the current beta, never passed.
export const betaAIScope = Object.freeze({
  decidedOn: '2026-11-13', execution: 'desktop-consultation', liveGeneration: false,
  autonomousGeneration: false, audioGeneration: false,
  retainedImplementation: true, offlineReadingAndManualWriting: false, offlineReading: true, manualWriting: false,
});

const deviceOnlyGeneration = new Set([
  'generation.specialisedSourceContext.downloaded',
  'generation.privateSourceContext.downloaded',
  'generation.databaseResearch.deviceWorker',
  'generation.databaseResearch.offlineRequest',
  'generation.databaseChat.chosenOfflineSources',
  'generation.databaseChat.newestChosenCapture',
  'generation.studyChat.chosenOfflineSources',
  'generation.deepResearch.chosenDownloadedSources',
  'sync.generation.modeChangePreservesAuthorizedResult',
]);

export function isDeferredBetaAI(id) {
  return id.split('.').some(part => part.startsWith('autonomous')) || deviceOnlyGeneration.has(id);
}

export function applyBetaAIScope(operation) {
  if (!operation.id.startsWith('generation.') && operation.category !== 'generation' && !isDeferredBetaAI(operation.id)) return operation;
  return {...operation, result: 'deferredByUser', requiredInBeta: false, implementation: 'retained',
    reason: 'Por instrucción del usuario del 13-11-2026, Nodus Link sólo consulta contenidos de Desktop. La generación y edición permanecen conservadas y deshabilitadas.'};
}
