# Nodus Desktop parity

This document is the implementation contract for the shared iPhone/iPad application. There is
one product and one navigation model: iPad renders the Desktop shell at tablet scale, while an
iPhone keeps the same hierarchy and surfaces with drawer navigation and touch controls in
both portrait and landscape.

## Current acceptance status

The 0.1.0 release is still under validation. `Parity/parity-manifest.json` is the current
operation matrix; implementation and historical passing scenarios do not establish full
parity. The executed results, source receipts, screenshots and remaining work are recorded
under `artifacts/acceptance-0.1.0`. No TestFlight build is approved yet.

The primary connection is Desktop Settings → Mobile connection: a code or QR links the
entire current workspace through direct HTTPS on LAN or VPN. Server and Cloud are advanced
options. Code discovery is Bonjour on LAN; a QR/link supplies the VPN addresses. Actual VPN
and camera scanning acceptance remains pending.

## Historical implementation phases

1. **Auditable contract baseline (phase 0)** — Desktop's 73 routes, 1,595 public actions and 49 mutable
   tables are captured in `Parity/parity-manifest.json`. The check rejects Desktop drift,
   unknown delivery channels and any `implemented` claim with no named test evidence. The
   phase-0 exclusion of generated Deep Research audio is historical; the current operation
   matrix defines the release scope, including consultation of saved narration.
2. **Deterministic visual baseline** — `NodusUITests` opens the bundled public-domain vault at a
   requested route on iPhone and iPad. The Electron and simulator capture tools produce the
   three comparable images under `artifacts/parity/<phase>/` without reading a real vault.
3. **Shared visual system** — compact spacing, restrained radii, neutral opaque surfaces, Desktop
   top bar, persistent iPad sidebar, collapsible icon rail, iPhone drawer, command palette and
   system/light/dark theme preference.
4. **Academic workflow** — answer-first Home dashboard and the seven Desktop Deep Research
   approaches, persisted in requests and applied to planning and section prompts.
5. **Core content surfaces** — Search, Library, generic collections and Workspace use the same
   compact header/search/row vocabulary. Search exposes explicit lexical and semantic modes.
6. **Published feature coverage** — State of Research, Immersion and every collection/mirror-backed
   route have a real destination. Worldbuilding facets map to their published tables. Features
   whose ranked/project data is not published remain hidden rather than opening unrelated views.
7. **Quality and accessibility** — Spanish strings for the new surfaces, 44-point touch targets,
   wrapping menu fields at accessibility sizes, stable fixed-height chrome, light/dark visual QA
   and full package/application regression.
8. **Transport and privacy baseline (phase 1)** — one generated mutation registry drives every
   public surface; typed `SpaceAction` jobs, the account-global Library outbox and the explicitly
   paired, certificate-pinned Desktop Bridge keep cloud, Desktop execution and private domains
   separate. Sync Center exposes the four channels and their retry/cancellation state.
9. **Resident shell and workspace tabs (phase 2)** — the shared `WorkspaceTabs` engine gives
   Ideas, Authors, Argument Map and both Library modes a fixed catalogue plus simultaneous,
   closeable dossiers. Route changes no longer reconstruct resident screens; filter, scroll and
   selection state survive section changes, while Argument Map is deliberately discarded when
   its section is left. iPad uses the persistent Desktop sidebar and 44/36-point chrome; iPhone
   keeps the same actions in the drawer and horizontally scrolling tab strip.
10. **Grounded academic workspaces (phase 3)** — Ideas and Authors now use Desktop-compatible
    projections for filtering, stable pagination, dossiers and author/theme synthesis matrices.
    Both surfaces keep several dossiers resident and open related records in sibling tabs. Saved
    authors retain their Desktop semantics as a device-local preference. Argument Map catalogues
    grounded hubs, applies the same connection/debate quotas in TypeScript and Swift, supports
    several maps, progressive collapse and adjustable type/content width, and submits AI expansion
    only as a typed, auditable Desktop action whose input is the real subgraph.
11. **Account-global Library (phase 4)** — one GRDB catalogue materializes immutable, conflict-
    preserving versions per account and stages SHA-256 objects with complete file protection.
    Desktop and mobile exchange items, nested collections, recursive saved searches and table
    preferences through the account ledger, never through a collaborator's space. The shared
    tab strip keeps multiple readers resident; catalogue CRUD, imports, collections, duplicate
    review, trash/recovery, metadata, notes, relations, history, QuickLook/download, Markdown
    export and fixed typed Mac jobs remain available on both device classes. iOS exposes cloud
    conflicts and cancellable Mac jobs without leaking a filesystem path or provider credential.
12. **Deep Research gallery and durable lane (phase 5)** — the seven Desktop approaches, language,
    model, length, section budget, decorative image, genealogy focus and teaching outline share one
    composer contract. Reports receive a stable local UUID immediately; a sequential account-wide
    queue survives relaunch, exposes retry/cancel/clear state and publishes through the outbox only
    with write permission. Desktop now checkpoints its queue atomically and parks other-vault jobs
    instead of deleting them. The merged local/published gallery supports persistent read/view/sort
    preferences, search, selection, bulk deletion and deterministic Markdown/PDF ZIP export. No
    speech synthesis job is created on mobile. Saved Desktop narration is listed in the shared
    reader and downloaded through a scoped, hashed Bridge file before native playback; the
    protected downloaded copy remains available when the Mac is unreachable.
13. **Deep Research reader (phase 6)** — iPad uses the Desktop reader composition while iPhone keeps
    the same toolbar and workspaces in a vertical surface. Outline, current section, reading progress,
    anchor restoration, typography, interactive citations, support/audit matrix, gaps,
    contradictions, works/authors/passages, 18-language translations, highlights, comments,
    bookmarks, image editing, read state, Markdown/listening copy, Notes and Markdown/PDF export are
    present. Saving to Notes is a typed Desktop action; translation and reading state persist locally
    without exposing report content through an unclassified cloud channel.
14. **Worldbuilding authoring system (phase 8)** — the shared world fixture now drives native,
    editable dossiers for encyclopedia entries, characters, places, factions, cultures, dynasties
    and scenes, plus map, timeline, genealogy and social-relations projections. Continuity findings,
    story threads, arcs, rules, open questions, manuscript chapters, scene prose and recoverable
    snapshots use the same published 91-table mutation registry. Canonical entity deletion and prose
    review run as typed Desktop actions; authored world images use only the authenticated object
    channel and never carry a local path. iPad keeps scene list, prose and the authored context rail
    beside each other; iPhone exposes those same controls through its Write/Scene switch.
15. **Pages and typed Databases (phase 9)** — Pages now keeps the Desktop wiki tree, block editor,
    backlinks, comments, mentions, reactions, revision history and ACL inspector in one shared
    workspace. Databases exposes title, text, number, status, select, person, date, checkbox,
    relation, attachment, formula and rollup properties with table, gallery, board, calendar and
    timeline views, row pages, search, sorting, analytics, forms and automations. Both catalogues
    open several closeable tabs without losing their resident state. CSV import and revision
    restoration are bounded, schema-versioned Desktop actions; formulas and queries execute from
    portable Swift recipes validated against the deterministic Desktop fixture.
16. **Study and Teaching (phase 10)** — Courses, subjects, topics, materials, timetable, calendar,
    goals, progress, exams, rubrics and unit design now use native shared SwiftUI surfaces. Course,
    material, exam and recording workspaces retain simultaneous closeable tabs. Roster, student
    identity, grade entries, rubric evaluations, recording metadata and transcripts are never read
    from a Cloudflare snapshot: the production loader requires an explicitly paired HTTPS Desktop
    Bridge with a pinned certificate and vault/domain grants, while UI tests use only synthetic
    fixture names. Grade projections distinguish unassessed, exempt and missing submissions and
    are calculated locally against the versioned plan using the same deterministic rules as Desktop.
17. **Sensitive research records (phase 11)** — Primary Sources now keeps an ISAD-style hierarchy,
    multiple closeable source dossiers, provenance, immutable file lineage, SHA-256 verification,
    literal text versions, stable excerpts, source analysis and audit state. Prosopography adds
    population criteria, simultaneous person dossiers, factoid/statement evidence, authority IDs,
    reproducible analysis runs and an accessible network whose explicit and derived edges retain
    provenance. Testimonies keeps multiple interviews, public attribution separate from working
    identity, versioned access agreements, sessions, immutable media, derived transcripts, codes,
    annotations and contrasts. None of these tables is public: production reads require the exact
    Desktop Bridge vault/domain grant, the offline copy is AES-GCM encrypted with complete file
    protection, and revocation destroys both credential and local cache key.

## Adaptive rules

- At iPad widths the Desktop information architecture is visible at all times. The sidebar may
  collapse to an icon rail without changing routes or content.
- On iPhone the same sidebar becomes a drawer and secondary top-bar actions move into one menu.
- Content components are shared across both size classes; no separate iPadOS feature fork exists.
- Page content honours the full Dynamic Type range. Only the fixed 44-point Desktop top bar caps
  its text size so controls cannot overlap; its buttons keep accessible labels and 44-point targets.
- Hidden routes are a capability decision, not a device decision.
- A UI rotation test asserts the resulting window geometry, not only the requested device
  orientation, on both iPhone and iPad.

## Phase 2 visual evidence

- Desktop: `artifacts/parity/phase-2/ideas-tabs-desktop-dark.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-2/ideas-tabs-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-2/ideas-tabs-iphone-dark.png`

The fixture opens two idea dossiers at once. The UI suite additionally types a catalogue filter,
visits Authors and returns to Ideas before asserting that the filter and both tabs still exist.

## Phase 3 visual evidence

- Desktop: `artifacts/parity/phase-3/ideas-tabs-desktop-dark.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-3/ideas-tabs-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-3/ideas-tabs-iphone-dark.png`

The three captures open the same tabbed Ideas workflow. The academic UI suite additionally closes
the active dossier and checks neighbour selection, opens simultaneous Authors and grounded
Argument Maps, and verifies that saved authors remain local after a section round trip. The pure
projection suite runs the same deterministic fixture in JavaScript and Swift.

## Phase 4 visual evidence

- Desktop: `artifacts/parity/phase-4/library-readers-desktop-dark.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-4/library-readers-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-4/library-readers-iphone-dark.png`

Each capture keeps the fixed Library catalogue beside two closeable reader tabs. Targeted UI
tests run on both iPhone 17 Pro and iPad Pro 13-inch, close the active reader, assert selection of
its neighbour and return to the unchanged catalogue. The full phase gate includes 157 NodusKit,
72 NodusAI and 5 NodusUI tests, Desktop typecheck, 12 Cloudflare contracts, 14 privacy checks and
the account-library transport suite.

## Phase 5 visual evidence

- Desktop: `artifacts/parity/phase-5/deep-research-gallery-desktop-dark.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-5/deep-research-gallery-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-5/deep-research-gallery-iphone-dark.png`

The fixture shows the unified gallery and a completed queue job. The UI test opens the same seeded
report on iPhone and iPad after checking the queue, gallery and toolbar. Queue tests additionally
interrupt a running Desktop job, reopen it as queued, keep it isolated while another vault is
active and resume it exactly once when its own vault returns.

## Phase 6 visual evidence

- Desktop: `artifacts/parity/phase-6/deep-research-reader-desktop-dark.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-6/deep-research-reader-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-6/deep-research-reader-iphone-dark.png`

The reader capture checks the outline/progress chrome, shared document surface and responsive
toolbar. The UI test also opens the outline and verifies the evidence section; unit suites cover
translation persistence, stable queue/report identity, deterministic archives and legacy local
report migration.

## Phase 7 visual evidence

- Desktop: `artifacts/parity/phase-7/academic-graph-desktop-dark.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-7/academic-graph-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-7/academic-graph-iphone-dark.png`

The shared academic snapshot now drives native Graph, Hypothesis Lab, Reading Path, Writing
Workshop and Projects routes. Graph simulation uses deterministic Barnes–Hut force and radial
layouts in a background actor, rendered by Metal with a parallel accessible node list. Golden
tests cover rejected-edge semantics, stable positions, grounded hypothesis references, reading
ranking and canonical project sections. Writing and project mutations are schema-checked,
idempotent Desktop actions; no IPC name, SQL or arbitrary method crosses the transport.

## Phase 8 visual evidence

- Desktop: `artifacts/parity/phase-8/world-manuscript-desktop-dark.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-8/world-manuscript-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-8/world-manuscript-iphone-dark.png`
- iPhone authored context rail: `artifacts/parity/phase-8/world-manuscript-inspector-iphone-dark.png`

The Desktop reference and iPad capture show the same three-column manuscript composition: ordered
scenes, serif prose editor and the contextual rail for conflicts, arcs, rules, snapshots and the
typed Desktop prose review. The iPhone captures demonstrate that neither editor nor rail is removed;
the segmented presentation only adapts them vertically. The targeted UI scenario also opens two
scene dossiers, closes the active one, checks neighbour selection and visits Continuity before
asserting every authored manuscript section. Golden Swift tests cover chronology, genealogy,
relations, continuity fingerprints and stable projections; the transport gate covers 73 routes,
1,595 Desktop actions and 91 mutable tables.

## Phase 9 visual evidence

- Desktop: `artifacts/parity/phase-9/databases-desktop-light.jpg`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-9/databases-ipad-dark.png`
- iPhone portrait: `artifacts/parity/phase-9/databases-iphone-dark.png`
- iPhone Pages editor: `artifacts/parity/phase-9/pages-autopen-iphone.png`

The captures use the same evidence-pipeline fixture and keep two database tabs resident. The UI
gate opens two Pages, returns to the fixed catalogue, closes the active document and checks its
neighbour; it repeats the sequence for Databases, verifies the computed property and switches the
same rows to the grouped review board. Pure tests cover cyclic page ancestry, stable backlinks,
typed cells, query order and Desktop-compatible arithmetic formulas. Cloudflare and privacy gates
also prove that CSV payloads are bounded structured data and contain neither a local path nor a
private-domain row.

## Phase 10 visual evidence

- Desktop: `artifacts/parity/phase-10/gradebook-desktop.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-10/gradebook-ipad.png`
- iPhone portrait: `artifacts/parity/phase-10/gradebook-iphone.png`
- iPhone private recording catalogue: `artifacts/parity/phase-10/recordings-iphone.png`

The iPad capture keeps the Desktop sidebar, dense metric strip and complete grade grid visible at
once. iPhone keeps the same columns in a two-axis scroll surface rather than replacing the
gradebook with a reduced card view. The shared UI scenario opens two courses, closes the active
tab and checks its neighbour, then validates Ada Lovelace's weighted 8.60 result and opens a private
recording transcript. It passes on both iPhone 17 Pro and iPad Pro 13-inch. The portable suite now
contains 173 tests, including deterministic hierarchy/mastery, grade status semantics and weighted
rubric descriptors; Bridge contract tests prove that roster, grades and recordings remain absent
from the public mutation registry and Cloudflare routing.

## Phase 11 visual evidence

- Desktop: `artifacts/parity/phase-11/testimonies-desktop.png`
- iPad Pro 13-inch: `artifacts/parity/phase-11/testimonies-ipad.png`
- iPhone portrait: `artifacts/parity/phase-11/testimonies-iphone.png`

Desktop shows the complete parallel-contrast workspace over five synthetic interviews. The shared
iPad/iPhone fixture condenses the same invariant into a traced contrast card while preserving the
Desktop shell on iPad and the full action/state vocabulary on iPhone. One targeted UI scenario runs
on both devices: Primary Sources opens two dossiers and closes to the adjacent tab, Prosopography
keeps two person dossiers and exposes explicit/derived edge provenance, and Testimonies keeps two
interviews governed by the current versioned access agreement before opening its contrast surface.
The portable suite contains 176 tests, including hierarchy-cycle safety, integrity counts, evidence
and authority projections, network provenance and agreement/transcript lineage. Desktop's real E2E
also traverses participant creation, versioned consent, immutable media, derived transcripts, notes
with timecoded deep links, reproducible contrasts and the local-analysis permission gate.

## Phase 12 visual evidence

- Desktop: `artifacts/parity/phase-12/toolkit-desktop.png`
- iPad Pro 13-inch landscape: `artifacts/parity/phase-12/toolkit-ipad.png`
- iPhone portrait: `artifacts/parity/phase-12/toolkit-iphone.png`
- Browser and Radar companions: `artifacts/parity/phase-12/{browser,radar}-{ipad,iphone}.png`

Browser keeps isolated closeable tabs, history, bookmarks, downloads, find-in-page and account
Library capture behind a public-URL policy. Radar persists account-global follows and read/saved
state, and restricts source checks to public HTTPS resources. Toolkit provides native Convert,
Protect, Translate, Presenter and Vision OCR surfaces; its Mac-only conversions send a fixed typed
operation plus encrypted Library object hashes, never a client path, process name or arbitrary
command. The same targeted UI scenario passes on iPad Pro 13-inch and iPhone 17 Pro, opening two
Browser tabs and traversing Radar and every Toolkit card. The portable suite contains 179 tests;
Desktop transport/security tests cover the allowlist, hash validation and private output handling.

## Phase 13 visual evidence and closure

- Current Desktop sidebar reference supplied during review:
  `artifacts/parity/phase-13/sidebar-desktop-reference-dark.png`
- iPad Pro 13-inch landscape, light and dark:
  `artifacts/parity/phase-13/sidebar-ipad-{light,dark}.png`
- iPhone 17 Pro portrait drawer, dark:
  `artifacts/parity/phase-13/sidebar-iphone-dark.png`

The academic hierarchy is intentionally the current product hierarchy rather than an earlier
roadmap menu. Home and the account-global Library are pinned. Explore contains Search, Ideas,
Authors and Argument map; Analyze contains only State of the art, Immersion and Deep
Research; Write contains Workspace; Tools contains Nodus Browser, Nodus Radar and Nodus Tools;
Settings is pinned last. Group headers collapse independently. iPad keeps Desktop's persistent,
pointer-draggable 176–360 point width, keyboard/VoiceOver adjustable action and saved order,
visibility and width. iPhone opens the same hierarchy as a vertical drawer.

Dedicated vault modes are guarded by the same closed allow-lists as Desktop, so academic routes
cannot leak into Prosopography, Primary Sources, Study, Teaching, Databases, Testimonies or
Worldbuilding. Hidden routes remain executable through typed deep links and Commands. The
0.1.0 implementation restores Graph and Study Graph through shared Desktop components;
their complete functional and visual acceptance remains pending in the operation matrix.
Saved narration consultation is included; Desktop speech synthesis is an explicit exclusion.
CI regenerates
this manifest against a fresh Desktop checkout and rejects any unclassified route, action, table,
fallback destination or missing evidence file.

The final local gate passed 185 app tests and 15 shared UI scenarios on both iPad Pro 13-inch and
iPhone 17 Pro. The portable packages passed 179 NodusKit, 72 NodusAI and 5 NodusUI tests. The UI
fixture resets only its own sidebar state so a previous visual run cannot contaminate the next;
production customisation remains durable and synchronized. Both simulators were run serially and
shut down after capture.

## Verification

Run from the repository root:

```sh
node ios/scripts/test-desktop-parity.mjs
node ios/scripts/generate-parity-manifest.mjs
swift test --package-path ios/Packages/NodusKit
swift test --package-path ios/Packages/NodusAI
swift test --package-path ios/Packages/NodusUI
xcodebuild -project ios/Nodus.xcodeproj -scheme Nodus \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Debug simulator launches may set `NODUS_START_ROUTE` to open a route directly. Visual QA may also
set `NODUS_VAULT_TYPE_OVERRIDE`; it changes navigation presentation only and never fabricates or
mutates vault data.

### Pages: documento completo y dependencias

El editor compartido mantiene BlockNote, metadatos académicos y bloques anteriores. El borrador íntegro se cifra y sincroniza con dos revisiones, recibos idempotentes y resolución explícita de conflictos. Las descargas seleccionadas incluyen bloques sincronizados, páginas originales, vistas enlazadas paginadas y dossiers de sus bases de datos, dentro del presupuesto temporal. La lectura explícita de una descarga no consulta el Mac. Los archivos mantienen su permiso y verificación de integridad. Los contratos de Pages están preparados; compilación, ejecución y pruebas de iPhone/iPad pendientes de la campaña local final.

### Bases de datos: escritura canónica y reapertura

Las creaciones de base, propiedad y fila conservan sus identidades móviles y pasan por las funciones reales de Desktop. Las celdas comprueban revisión y valor anterior; los rechazos se conservan y se muestran. La proyección de la cola permite reabrir cambios pendientes y da paso a revisiones canónicas confirmadas. Contratos preparados; ejecución y aceptación visual pendientes.

### Vistas guardadas y fuentes enlazadas

El workspace nativo consulta el filtro y la ordenación reales de Desktop, con todos los cursores y fuentes enlazadas. Las filas ajenas conservan su base de datos original al abrirse. Las descargas incluyen las consultas completas y dossiers de las fuentes necesarias; un cambio de revisión cancela la copia, y las dependencias repetidas se combinan sin duplicar registros. La consulta paginada sin red evita repetir un timeout por cada página. Contratos preparados: `DatabaseContainerPresentationTests`, `CompanionDatabaseViewSourceTests` y filtros/ordenación en el contrato real de Pages. Ejecución y aceptación pendientes de la campaña local.

### Campaña local y prueba física del usuario

Por indicación expresa del usuario el 12 de octubre de 2026, la validación previa a TestFlight se ejecuta en Desktop, simulador de iPhone y simulador de iPad. El usuario probará el iPhone físico cuando reciba la beta. La matriz conserva `visual.physicalIphone` y el entorno físico como `pendingUserValidation`, con cero pruebas ejecutadas y responsable `user`; no se presentan como aprobados ni como pruebas omitidas satisfactorias. El resto de las operaciones mantiene el requisito de ejecución y evidencia actual. Los simuladores conservan su firma ad hoc para que las pruebas usen Keychain real.
