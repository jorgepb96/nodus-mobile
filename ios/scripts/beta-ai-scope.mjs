// Explicit user scope change, 2026-10-15. Keep implementation and historical
// results; these operations are unavailable in the current beta, never passed.
export const betaAIScope = Object.freeze({
  decidedOn: '2026-10-15', execution: 'desktop-live',
  autonomousGeneration: false, audioGeneration: false,
  retainedImplementation: true, offlineReadingAndManualWriting: true,
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
  if (!isDeferredBetaAI(operation.id)) return operation;
  return {...operation, result: 'deferredByUser', requiredInBeta: false, implementation: 'retained',
    reason: 'Por instrucción del usuario del 15-10-2026, esta beta sólo ejecuta IA en el Mac conectado. La implementación móvil permanece conservada y deshabilitada.'};
}
