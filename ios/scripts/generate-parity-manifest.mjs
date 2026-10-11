#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { mobileRoot, nodusRepo } from './nodus-repo.mjs';

export const PARITY_MANIFEST_VERSION = 2;

// These Desktop routes are intentionally absent from the mobile product. Keep them in the
// generated inventory so a removal is auditable without leaving a dead enum case, deep link or
// placeholder screen in the app.
const EXCLUDED_ROUTES = new Map();
const COMING_SOON = new Set(['browser', 'radar', 'compass', 'studyFocus', 'toolkit']);

const ROUTE_DELIVERY = {
  accountSync: new Set(['library', 'radar']),
  portableAlgorithm: new Set(['graph', 'argument', 'hypothesis', 'reading', 'dbAnalysis', 'studyGraph']),
  typedDesktopCommand: new Set(['continuity', 'manuscript', 'writing', 'projects', 'teachingUnits']),
  privateBridge: new Set([
    'archive', 'prosopSearch', 'prosopPopulation', 'prosopSources', 'prosopAnalysis', 'prosopNetworks',
    'testimonyInterviews', 'testimonyParticipants', 'testimonyContrasts', 'studyRecordings',
    'teachingGroups', 'teachingGrades',
  ]),
  platformEquivalent: new Set(['browser', 'toolkit']),
};

const DELIVERY_EVIDENCE = {
  nativeShared: [
    'ios/NodusUITests/NodusParityUITests.swift#testEveryVisibleDestinationUsesTheSharedShell',
  ],
  portableAlgorithm: [
    'ios/Packages/NodusKit/Tests/NodusKitTests/AcademicParityTests.swift',
    'ios/Packages/NodusKit/Tests/NodusKitTests/ArgumentMapTests.swift',
  ],
  cloudMutation: [
    'ios/Packages/NodusKit/Tests/NodusKitTests/ParityTransportTests.swift#generatedRegistry',
    'ios/Packages/NodusKit/Tests/NodusKitTests/OutboxTests.swift',
    '../nodus/scripts/test-cloudflare-contract.mjs',
  ],
  typedDesktopCommand: [
    'ios/Packages/NodusKit/Tests/NodusKitTests/ParityTransportTests.swift#remoteWork',
    '../nodus/scripts/test-mobile-parity-transport.mjs',
  ],
  privateBridge: [
    'ios/Packages/NodusKit/Tests/NodusKitTests/SensitiveRecordsParityTests.swift',
    'ios/Packages/NodusKit/Tests/NodusKitTests/ParityTransportTests.swift#bridgePairing',
    '../nodus/scripts/test-testimony-privacy.mjs',
  ],
  accountSync: [
    'ios/Packages/NodusKit/Tests/NodusKitTests/AccountLibraryCatalogTests.swift',
    'ios/Packages/NodusKit/Tests/NodusKitTests/AccountLibraryOutboxTests.swift',
    'ios/Packages/NodusKit/Tests/NodusKitTests/PlatformToolsParityTests.swift#radar',
  ],
  platformEquivalent: [
    'ios/NodusUITests/NodusParityUITests.swift#testBrowserRadarToolkitAndSettingsMatchDesktopTools',
    'ios/Packages/NodusKit/Tests/NodusKitTests/PlatformToolsParityTests.swift',
    '../nodus/scripts/test-browser-security.mjs',
    '../nodus/scripts/test-toolkit-ui.mjs',
  ],
};

const ROUTE_PHASE_EVIDENCE = [
  [new Set(['ideas', 'authors', 'argument']), 'ios/NodusUITests/NodusParityUITests.swift#testAcademicWorkspacesOpenMultipleTabsAndCloseToTheirNeighbour'],
  [new Set(['library']), 'ios/NodusUITests/NodusParityUITests.swift#testAccountLibraryKeepsMultipleReadersAndClosesToItsNeighbour'],
  [new Set(['deepResearch']), 'ios/NodusUITests/NodusParityUITests.swift#testDeepResearchGalleryQueueAndReaderToolsMatchDesktopWorkflow'],
  [new Set(['graph', 'hypothesis', 'reading', 'writing', 'projects', 'research', 'gaps', 'debate', 'immersion', 'workspace', 'notes']), 'ios/NodusUITests/NodusParityUITests.swift#testAcademicGraphReadingHypothesisWritingAndProjectsAreNativeRoutes'],
  [new Set(['encyclopedia', 'characters', 'places', 'factions', 'cultures', 'dynasties', 'scenes', 'timeline', 'tree', 'relations', 'map', 'rules', 'conflicts', 'arcs', 'questions', 'worldChat', 'continuity', 'manuscript', 'persons']), 'ios/NodusUITests/NodusParityUITests.swift#testWorldbuildingWorkspacesContinuityAndManuscriptAreNative'],
  [new Set(['pages', 'databases', 'dbSearch', 'dbAnalysis', 'dbChat']), 'ios/NodusUITests/NodusParityUITests.swift#testPagesAndDatabasesKeepDesktopWorkspacesAndTypedViews'],
  [new Set(['studyCourses', 'studySchedule', 'studyCalendar', 'studySearch', 'studyLibrary', 'studyRecordings', 'studyChat', 'studyIdeas', 'studyGraph', 'studyQuestions', 'studyReview', 'studyDeepResearch', 'teachingGroups', 'teachingGrades', 'teachingExams', 'teachingRubrics', 'teachingUnits']), 'ios/NodusUITests/NodusParityUITests.swift#testStudyTeachingParityKeepsTabsGradesAndPrivateRecordings'],
  [new Set(['archive', 'prosopSearch', 'prosopPopulation', 'prosopPersons', 'prosopSources', 'prosopAnalysis', 'prosopNetworks', 'testimonyInterviews', 'testimonyParticipants', 'testimonyContrasts']), 'ios/NodusUITests/NodusParityUITests.swift#testSensitiveRecordsStayPrivateAndKeepDesktopDossierTabs'],
  [new Set(['browser', 'radar', 'toolkit', 'settings']), 'ios/NodusUITests/NodusParityUITests.swift#testBrowserRadarToolkitAndSettingsMatchDesktopTools'],
];

const API_SOURCES = [
  ['AcademicApi', 'shared/api/academic.ts', 'typedDesktopCommand'],
  ['ProsopographyApi', 'shared/api/prosopography.ts', 'privateBridge'],
  ['ArchiveApi', 'shared/api/archive.ts', 'privateBridge'],
  ['PrimarySourcesApi', 'shared/api/primarySources.ts', 'privateBridge'],
  ['RecordsApi', 'shared/api/records.ts', 'cloudMutation'],
  ['LibraryApi', 'shared/api/library.ts', 'accountSync'],
  ['PlatformApi', 'shared/api/platform.ts', 'platformEquivalent'],
  ['RadarApi', 'shared/api/radar.ts', 'accountSync'],
  ['PagesApi', 'shared/api/pages.ts', 'cloudMutation'],
  ['WorldbuildingApi', 'shared/api/worldbuilding.ts', 'cloudMutation'],
  ['DatabasesApi', 'shared/api/databases.ts', 'cloudMutation'],
  ['ToolkitApi', 'shared/api/toolkit.ts', 'platformEquivalent'],
  ['TeachingApi', 'shared/api/teaching.ts', 'privateBridge'],
  ['TestimoniesApi', 'shared/api/testimonies.ts', 'privateBridge'],
  ['BrowserApi', 'shared/types.ts', 'platformEquivalent'],
  ['NodusApi', 'shared/types.ts', 'typedDesktopCommand'],
];

function valuesBetween(source, start, end) {
  const from = source.indexOf(start);
  if (from < 0) throw new Error(`Could not find ${start}`);
  const to = source.indexOf(end, from + start.length);
  if (to < 0) throw new Error(`Could not find ${end}`);
  return source.slice(from + start.length, to);
}

function quoted(source) {
  return [...source.matchAll(/'([^']+)'/g)].map((match) => match[1]);
}

function evidenceExists(entry) {
  const relative = entry.split('#')[0];
  if (relative.startsWith('../nodus/')) {
    return fs.existsSync(path.join(nodusRepo(), relative.slice('../nodus/'.length)));
  }
  return fs.existsSync(path.resolve(mobileRoot, relative));
}

function interfaceBody(source, name) {
  const marker = `export interface ${name}`;
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`Could not find ${name}`);
  const open = source.indexOf('{', start + marker.length);
  if (open < 0) throw new Error(`Could not find body for ${name}`);
  let depth = 0;
  for (let index = open; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') depth -= 1;
    if (depth === 0) return source.slice(open + 1, index);
  }
  throw new Error(`Unterminated interface ${name}`);
}

function interfaceMethods(source, name) {
  const body = interfaceBody(source, name);
  return [...body.matchAll(/^\s{2}([A-Za-z_$][A-Za-z0-9_$]*)\??(?:<[^\n(]+>)?\s*\(/gm)]
    .map((match) => match[1])
    .filter((value, index, list) => list.indexOf(value) === index)
    .sort();
}

function routeDelivery(route) {
  if (EXCLUDED_ROUTES.has(route)) return 'explicitExclusion';
  for (const [delivery, routes] of Object.entries(ROUTE_DELIVERY)) {
    if (routes.has(route)) return delivery;
  }
  return 'nativeShared';
}

function mobileRouteState(swift, route) {
  if (EXCLUDED_ROUTES.has(route)) return 'excluded';
  const escaped = route.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const line = swift.match(new RegExp(`\\.init\\(\\.${escaped},[^\\n]+`))?.[0] ?? '';
  if (COMING_SOON.has(route)) return 'comingSoon';
  if (/support: \.(?:native|collection|mirror|nested)/.test(line)) return 'available';
  return 'planned';
}

function routeEvidence(route, delivery) {
  if (delivery === 'explicitExclusion') return ['ios/DESIGN_PARITY.md#phase-13-visual-evidence-and-closure'];
  const specific = ROUTE_PHASE_EVIDENCE.find(([routes]) => routes.has(route))?.[1];
  return [...new Set([...(specific ? [specific] : []), ...(DELIVERY_EVIDENCE[delivery] ?? [])])];
}

function navMetadata(navigation, route) {
  const escaped = route.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const literal = navigation.match(new RegExp(`\\{ id: '${escaped}', label: '([^']+)', icon: '([^']+)'(?:, group: '([^']+)')? \\}`));
  return literal ? { label: literal[1], icon: literal[2], group: literal[3] ?? null } : { label: route, icon: null, group: null };
}

function operationMatrix(routes) {
  const consultations = [
    'deepResearch.catalogue', 'deepResearch.pagination', 'deepResearch.detail', 'deepResearch.document',
    'deepResearch.images', 'deepResearch.citations', 'deepResearch.translations', 'deepResearch.annotations', 'deepResearch.export', 'audio.savedConsultation',
    'dictionary.search', 'dictionary.filters', 'dictionary.entries', 'dictionary.versions', 'dictionary.evidence', 'dictionary.relations',
    'graph.filters', 'graph.themes', 'graph.selection', 'graph.evidence', 'argumentMap.structural', 'argumentMap.expansion',
    'scriptor.blocks', 'scriptor.tables', 'scriptor.images', 'scriptor.formulas', 'scriptor.references', 'scriptor.bibliography',
    'scriptor.history', 'scriptor.roundTrip', 'scriptor.conflict', 'scriptor.draftRecovery',
    'companion.downloadSelection', 'companion.downloadExpiry', 'companion.storageBudget',
    'companion.offlineConsultation', 'companion.offlineEditing', 'companion.offlineCreation',
    'companion.reconnect', 'companion.conflictResolution', 'queries.semantic', 'queries.context',
    'catalogues.pagination', 'documents.long', 'files.download',
    'pairing.qr', 'pairing.code', 'pairing.link', 'pairing.expiry', 'pairing.renew', 'pairing.revoke', 'pairing.permissions',
    'transport.lan', 'transport.vpn', 'transport.serverRelay', 'transport.cloudRelay', 'transport.disconnect', 'transport.relaunch',
    'jobs.progress', 'jobs.cancel', 'jobs.retry', 'jobs.persistence', 'jobs.noDuplicates',
    'visual.iphone', 'visual.ipad', 'visual.physicalIphone', 'visual.lightDark', 'visual.rotation', 'visual.accessibility',
  ];
  return [
    ...routes.map(route => ({ id: `consultation.${route.id}`, route: route.id,
      category: COMING_SOON.has(route.id) ? 'comingSoon' : 'consultation', result: 'pending', evidence: [] })),
    ...consultations.map(id => ({ id,
      category: ['transport.serverRelay', 'transport.cloudRelay'].includes(id) ? 'comingSoon' : 'consultation',
      ...(['transport.serverRelay', 'transport.cloudRelay'].includes(id) ? { reason: 'Esta beta sólo habilita la conexión directa al Mac por red local o VPN. Las rutas avanzadas permanecen ocultas en el móvil.' } : {}),
      result: 'pending', evidence: [] })),
    ...['deepResearch', 'immersion', 'dictionary', 'chat', 'translation', 'synthesis', 'argumentMap', 'writingAssistant']
      .flatMap(id => ['live', 'autonomous'].map(mode => ({ id: `generation.${id}.${mode}`, category: 'generation', result: 'pending', evidence: [] }))),
    ...['extractDocuments', 'indexDocuments', 'deriveIdeas'].map(id => ({ id, category: 'desktopExclusive', result: 'notApplicable', evidence: [] })),
    ...[
      ['generation.writingWorkshop.live', 'generation'], ['generation.writingWorkshop.autonomous', 'generation'],
      ['consultation.writingWorkshop.sourcePagination', 'consultation'], ['consultation.writingWorkshop.structuredReading', 'consultation'],
      ['consultation.privateSource.citations', 'consultation'], ['consultation.privateSource.downloads', 'consultation'],
      ['consultation.studyRecordings.citationTimestamp', 'consultation'], ['consultation.privateSource.catalogue', 'consultation'],
      ['generation.specialisedSourceContext.linked', 'generation'], ['generation.specialisedSourceContext.downloaded', 'generation'],
      ['sync.selectedWorkshopSources', 'sync'],
      ['consultation.testimonyPrivateDossiers', 'consultation'], ['consultation.testimonyCitationLocators', 'consultation'],
      ['consultation.testimonyPrivateDownloads', 'consultation'],
      ['consultation.immersion.privateProgress', 'consultation'], ['consultation.immersion.quizPersistence', 'consultation'],
      ['consultation.immersion.restart', 'consultation'], ['sync.immersion.answers', 'sync'],
      ['sync.immersion.conflicts', 'sync'], ['sync.immersion.pendingGenerationProgress', 'sync'],
      ['sync.immersion.sharedPlayerProgress', 'sync'], ['consultation.immersion.progressGrant', 'consultation'],
      ['consultation.immersion.completeCatalogue', 'consultation'],
      ['generation.privateSourceContext.linked', 'generation'], ['generation.privateSourceContext.downloaded', 'generation'],
      ['consultation.privateSourceContext.domainRevocation', 'consultation'],
      ['writing.scriptor.embeddedImageRoundtrip', 'writing'], ['sync.scriptor.attachmentEnvelope', 'sync'],
      ['consultation.internalImages.scopedRendering', 'consultation'], ['sync.selectedInternalImages', 'sync'],
      ['consultation.internalImages.privateGrant', 'consultation'],
      ['consultation.databaseResearch.completeCatalogue', 'consultation'], ['consultation.databaseResearch.structuredReport', 'consultation'],
      ['consultation.databaseResearch.annotations', 'consultation'], ['consultation.databaseResearch.export', 'consultation'],
      ['generation.databaseResearch.live', 'generation'], ['generation.databaseResearch.autonomous', 'generation'],
      ['sync.selectedDatabaseResearch', 'sync'],
      ['consultation.chat.specialisedHistory', 'consultation'], ['consultation.chat.specialisedNotebooks', 'consultation'],
      ['consultation.chat.studyCitationLocators', 'consultation'], ['consultation.chat.recordingsGrant', 'consultation'],
      ['generation.worldChat.live', 'generation'], ['generation.studyChat.live', 'generation'], ['generation.databaseChat.live', 'generation'],
      ['generation.specialisedChat.cancellation', 'generation'], ['consultation.study.desktopOnlyIndex', 'consultation'],
    ].map(([id, category]) => ({ id, category, result: 'pending', evidence: [] })),
  ];
}

export function buildParityManifest() {
  const desktop = nodusRepo();
  const navigation = fs.readFileSync(path.join(desktop, 'src/navigation.ts'), 'utf8');
  const swiftNavigation = fs.readFileSync(path.join(mobileRoot, 'ios/Nodus/State/NavigationContract.swift'), 'utf8');
  const routes = quoted(valuesBetween(navigation, 'export type View = ', ';')).map((id) => {
    const delivery = routeDelivery(id);
    return {
      id,
      ...navMetadata(navigation, id),
      delivery,
      mobileState: mobileRouteState(swiftNavigation, id),
      ...(EXCLUDED_ROUTES.has(id) ? { reason: EXCLUDED_ROUTES.get(id) } : {}),
      evidence: routeEvidence(id, delivery),
    };
  });

  const apiActions = API_SOURCES.flatMap(([interfaceName, relativePath, delivery]) => {
    const source = fs.readFileSync(path.join(desktop, relativePath), 'utf8');
    return interfaceMethods(source, interfaceName).map((method) => ({
      id: `${interfaceName}.${method}`,
      interface: interfaceName,
      method,
      source: relativePath,
      delivery,
      mobileState: 'catalogued',
      evidence: DELIVERY_EVIDENCE[delivery] ?? [],
    }));
  }).sort((left, right) => left.id.localeCompare(right.id));

  const mutationContract = JSON.parse(fs.readFileSync(path.join(desktop, 'shared/mutableTables.json'), 'utf8'));
  const mutableTables = Object.keys(mutationContract.tables)
    .map((name) => ({
      name,
      delivery: 'cloudMutation',
      mobileState: 'catalogued',
      evidence: DELIVERY_EVIDENCE.cloudMutation,
    }));

  return {
    version: PARITY_MANIFEST_VERSION,
    referenceCommits: { desktop: '0a173fd9c698a7cb2d5989aa64b59cddd329bcf9', mobile: 'ad6e3069bcea67b48de76de561fc27c3db417563' },
    validationPolicy: 'Availability and source files are inventory only. Release requires executed operation evidence with no omissions.',
    operations: operationMatrix(routes),
    sourceOfTruth: {
      repository: 'nodus',
      navigation: 'src/navigation.ts',
      api: API_SOURCES.map(([, source]) => source).filter((value, index, values) => values.indexOf(value) === index),
      mutations: 'shared/mutableTables.json',
    },
    allowedDeliveries: [
      'nativeShared', 'portableAlgorithm', 'cloudMutation', 'typedDesktopCommand',
      'privateBridge', 'accountSync', 'platformEquivalent', 'explicitExclusion',
    ],
    explicitExclusions: [{
      id: 'deepResearch.audioGeneration',
      delivery: 'explicitExclusion',
      mobileState: 'excluded',
      reason: 'Desktop speech synthesis runtimes are not included on iOS. Consultation and playback of saved narration are covered separately by audio.savedConsultation.',
      evidence: ['ios/DESIGN_PARITY.md#phase-5-visual-evidence'],
    }],
    fixture: {
      id: 'academic-parity-v1',
      contract: 'ios/Parity/fixtures/academic-parity-v1.json',
      desktopSeeder: 'window.nodus.seedDemoData()',
      mobileSeeder: 'DemoSpace.prepare()',
    },
    routes,
    apiActions,
    mutableTables,
  };
}

export function manifestText() {
  return `${JSON.stringify(buildParityManifest(), null, 2)}\n`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const target = path.join(mobileRoot, 'ios/Parity/parity-manifest.json');
  const next = manifestText();
  if (process.argv.includes('--write')) {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, next);
    console.log(`Wrote ${path.relative(mobileRoot, target)}`);
  } else {
    if (!fs.existsSync(target)) throw new Error(`Missing ${path.relative(mobileRoot, target)}; run with --write`);
    const current = fs.readFileSync(target, 'utf8');
    if (current !== next) {
      throw new Error('Desktop parity inventory changed. Classify the change and regenerate ios/Parity/parity-manifest.json.');
    }
    const manifest = JSON.parse(current);
    const deliveries = new Set(manifest.allowedDeliveries);
    const all = [...manifest.routes, ...manifest.apiActions, ...manifest.mutableTables, ...manifest.explicitExclusions];
    const unknown = all.filter((item) => !deliveries.has(item.delivery));
    const implemented = [...manifest.routes, ...manifest.apiActions, ...manifest.mutableTables];
    const unsupportedClaims = implemented
      .filter((item) => item.mobileState === 'implemented')
      .filter((item) => !item.evidence || item.evidence.length === 0);
    const invalidStates = implemented
      .filter((item) => !['available', 'catalogued', 'comingSoon', 'excluded', 'planned'].includes(item.mobileState));
    const missingEvidence = implemented.flatMap((item) => item.evidence ?? [])
      .filter((entry, index, entries) => entries.indexOf(entry) === index)
      .filter((entry) => !evidenceExists(entry));
    if (unknown.length) throw new Error(`Unclassified parity entries: ${unknown.map((item) => item.id ?? item.name).join(', ')}`);
    if (invalidStates.length) throw new Error(`Incomplete parity entries: ${invalidStates.map((item) => item.id ?? item.name).join(', ')}`);
    if (unsupportedClaims.length) throw new Error(`Parity claimed without evidence: ${unsupportedClaims.map((item) => item.id).join(', ')}`);
    if (missingEvidence.length) throw new Error(`Parity evidence does not exist: ${missingEvidence.join(', ')}`);
    console.log(`Inventory is current: ${manifest.routes.length} routes, ${manifest.apiActions.length} actions, ${manifest.mutableTables.length} mutable tables. This check does not certify functional parity.`);
  }
}
