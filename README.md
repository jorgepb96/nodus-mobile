# Nodus Mobile

iPhone and iPad companion for [Nodus](https://github.com/jorgepb96/nodus), one directory per platform.

```
ios/          iOS and iPadOS app (SwiftUI), its Swift packages and its tools
```

Android has no directory yet. When it gets one it sits beside `ios/`, and nothing above this line
should have to change for it.

## Companion connection

Open Desktop Settings → Mobile connection and link the complete workspace with a temporary QR,
code or link. Direct HTTPS on the same LAN or local VPN is the enabled connection in 0.1.0.
Server/Cloud onboarding and iCloud content synchronization are hidden in this beta.

Live mode uses the Mac's effective models and providers; their credentials remain on the Mac.
Autonomous mode uses providers explicitly configured on the device. The app never switches modes
automatically. Extraction, indexing and derived-idea pipelines stay on Desktop.

SwiftUI navigation hosts shared Nodus graph, argument-map, research, dictionary and BlockNote
surfaces. Selected Scriptor documents use encrypted temporary downloads with a shared 250 MiB
read budget per Mac. Pending structured edits and new authored notes/ideas survive app restart
and temporary-copy cleanup. Reconnection sends immutable saves; revision conflicts require an
explicit choice.

The current implementation extends selected downloads to research reports, dictionary entries
and immersions, with saved translations, annotations, decorative images and citation previews.
Dictionary copies include local filters, complete paginated evidence and versions. Independent
selections are combined. Originals, attachments and recordings can be retained separately for
7 or 30 days and reopened from device storage. These additions await the final build and
acceptance campaign; other-domain catalogues and the complete release gate remain pending.
Open file previews also share a bounded transient budget and release their temporary plaintext
files when the last reader closes. Pending Mac requests reuse their original identities after
reconnection; portable result saves synchronize in either mode, while queued Mac generation
requires live to remain selected. Failed or interrupted generations are not restarted automatically.
Completed dictionary definitions, translations, immersions and writing assistance retain an
encrypted result together with their immutable publication request. They remain consultable in
Settings → Jobs and results while awaiting the Mac. Transport loss preserves the saved state;
source conflicts and provider failures remain explicit errors. Reconnection reconciles the
original checkpoint with the Mac acknowledgement without regenerating the response. This new
recovery path also awaits compilation and the deferred acceptance campaign.
Companion-authored ideas retain their owning note and remain visible in Desktop's automatic
academic catalogue and graph. A linked corpus revision refreshes mounted graph, dictionary,
research and Scriptor catalogues without replacing the web view or editor. Graph source and
background caches are invalidated together; saved camera, tabs and exploration are retained.
These freshness and visibility changes also await the consolidated build and acceptance run.
Selected academic ideas now have a dedicated download picker. Copies retain complete dossiers,
evidence and paginated direct graph neighbourhoods, with search, ordering and native-reader
fallback. A source revision change rejects the download instead of committing inconsistent
records. Independent selections combine without resurrecting relations removed from a newer
copy. Neighbour summaries never impersonate a downloaded full dossier or neighbourhood. This
path is implemented locally and awaits compilation, contracts and the final visual campaign.
Native source-link readers preserve the actual failure and offer a retry; a cancelled navigation
does not become a failed record. Compact chips keep their intrinsic size, and a tag wider than
the available reading column receives a bounded proposal rather than forcing horizontal overflow.
The iPhone/iPad visual acceptance of these refinements remains pending.
New offline-authored ideas also project into the native Ideas catalogue and shared graph while
their stable identities await acknowledgement. These genuine user drafts carry a pending state,
zero derived evidence and no invented relations. Removing temporary downloads keeps them.
Only an actual pending authored identity can answer a Mac 404; deleted downloaded corpus
records, permission failures and certificate errors remain failures. This new route awaits
the deferred contracts and end-to-end campaign.

Selected Scriptor notes and research/immersion readers now retain a portable autonomous source.
The phone can prepare a new writing selection/style or translation language from that chosen
copy, with its own provider, without first repeating the request on the Mac. Canonical versioned
revision inputs survive native JSON key ordering; reconnect still rejects changed sources or
styles. Older context/save contracts remain supported, and transcript sources retain their
separate recordings permission. Downloads reject an editor/source change before committing.
These contracts and their prepared regression scenarios await the final local build and tests.
The selected-topic immersion download keeps real ideas, passages, sources and graph material.
New autonomous immersions can change duration, quizzes and phone model against that retained
topic/language. Scope estimates are rebuilt from the chosen duration, and both scope and
generation now receive the form's chosen language. A changed Mac evidence revision rejects
publication; a permission failure never opens the offline fallback. Research selections also
check a stable corpus revision before and after copying. This path awaits final local validation.
The generic public read registry now retains all 49 Desktop collection contracts, including
worldbuilding, archival, testimony and aggregate-only prosopography dossiers, with their actual
primary and response keys. A separate native picker downloads only chosen dossiers and reads
catalogue pages on demand. Selected databases traverse every row page and retain its cells,
relations and attachment metadata; a truncated or changing database cannot commit. Independent
copies combine with the newest complete dossier owning removals, and offline searches retain
the server's per-column substring semantics. Study-document copies also retain autonomous
writing/translation sources. Native collection catalogues identify device content, and source
IDs with slash, hash or percent characters remain one exact path segment. Integration into
specialised mirror-based surfaces, binary assets and final visual/contract acceptance remain
part of the unfinished parity campaign.

Shared domain models, report layout and reading-copy rules live in the Nodus repository.
`ios/scripts/build-shared-desktop.mjs --verify` checks the bundled shared-source/output digests;
`ios/scripts/test-reading-copy-parity.mjs` checks the reading contract.

## Getting it running

You need Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and a checkout of the
Nodus repository beside this one (or `NODUS_REPO` pointing at yours).

```
cd ios && xcodegen generate && open Nodus.xcodeproj
```

The Xcode project is generated from `ios/project.yml` and is not committed: a `.pbxproj` in version
control buys nothing but merge conflicts.

## Tools

All of them read the Nodus repository through `ios/scripts/nodus-repo.mjs`, which finds it beside
this one or at `NODUS_REPO` and says so plainly when it cannot.

| | |
|---|---|
| `node ios/scripts/ios-app-icon.mjs` | Draws the app icon from `shared/nodusMark.json`, so it cannot drift from the mark the desktop rasterises its own icon from. |
| `node ios/scripts/ios-lab-publish.mjs --list` | Publishes a **copy** of a real vault to a local Nodus Server, so the app can be driven against something with actual shape. Never opens the original, never names its profile `nodus`. |
| `node ios/scripts/test-reading-copy-parity.mjs` | Compiles `NodusAI` and runs it against the desktop's TypeScript over the same inputs, failing on a differing byte. The listening copy a reader hears on a phone has to be the one they would have heard on the desktop. |

## Versions

Public native dossier readers now retain their nested sections, including source
text versions, study question history, testimony fragments, world manuscripts
and page blocks. Related records open in native navigation using explicit domain
links; annotation and aggregate ids never become private identity links. Long
evidence and relation lists offer more items instead of silently truncating at
40 or 60. These changes and their prepared contract regressions still await the
consolidated local build, test and visual acceptance campaign.

The shared dictionary, Scriptor, research reader and immersion surfaces expose
their completed phone results through a native results sheet. It reads the local
encrypted ledger without contacting the Mac, retains rejected results for review
and shows pending versus acknowledged synchronization. Generation status uses a
reserved strip above the surface so it does not cover the chat/editor composer.
This implementation is not yet an executed acceptance result.

Opening a theme now reads that theme's enriched dossier rather than requiring a
whole-vault download. Study Ideas uses the study catalogue. Local relation joins
retain all matching rows by default, and large sets of linked identities avoid
SQLite's bound-variable limit while preserving publication order. Prepared local
regressions include 1,201 memberships, distinct themes with identical labels and
a 35,001-id lookup; they have not yet been executed.

Completed result writes notify the native results catalogue independently of Mac
acknowledgements. A restored result therefore appears even when its generation
status text did not change. Error and generation notices reserve layout space
above shared surfaces, and stored-result read failures stay explicit and retryable.

The specialised native idea, work, person and author readers now decode their
known models from the same complete dossier response and retain all remaining
sections beside the existing domain components. This includes document profiles,
literal work evidence and character context. Document profiles keep their
orientation-only status; they do not become quotation evidence. A linked work
offers the granted on-device source reader directly. Contract regressions are
prepared and remain pending execution.

Selected Deep Research downloads now also retain the exact native report dossier,
translations, annotations, printable HTML and hash-checked illustration. This closes
the transport gap when switching to the native autonomous gallery: its pages are rebuilt
from selected reports, including pages beyond 200, rather than an unrelated cached full
catalogue. Native readers disclose device provenance. Linked-Mac illustrations stay in
the bounded encrypted Bridge store instead of the permanent public-image store.
Prepared regressions cover pagination, provenance changes, removals, reserved identities,
image integrity, exports, unselected reports, permission/certificate/format failures and
removal of the read pack. Execution and visual acceptance remain pending.

Specialised native workspaces now offer a separate native stack for their chosen
downloaded public dossiers, available without requesting a full snapshot or opening a
Mac connection. This includes world entities, archive dossiers, public prosopography,
testimonies, study/teaching records and database pages. Related records open only if their
own dossier was downloaded; contextual summaries do not become independent copies.
Entity-kind filters run before paging, and downloaded databases use the native grid
with all stored row pages and each page's cells, relations and attachments. Committed
downloads and deletion notify the visible access controls. This is consultation of selected
public dossiers, not a substitute for private-domain permissions or full specialised offline
editing. Native contracts are prepared; compilation and acceptance remain pending.

Native autonomous research and chat can retrieve new questions from chosen academic
source dossiers when the Mac is unreachable. This provider-free lexical source includes
actual selected ideas, passages, themes, gaps and work rows; graph neighbours and linked
summaries never become independent citable sources. Literal passages enter prompts in
full, and an oversized passage is omitted with a truncation flag instead of silently
shortened. Semantic requests still require the Mac and fail promptly before lexical
retrieval; a local copy is never presented as a vector index. Permission, certificate,
format and cancellation failures do not trigger offline fallback. Research checkpoints,
reports and Markdown retain the downloaded/mixed material scope. Native source contracts
and persistence regressions are prepared and remain pending execution. Selected specialised
Specialised study/world content still requires its own autonomous source contracts. The native
writing workshop now supports all six formats, Desktop languages and seven source categories,
with paged source selection, selected-source downloads, structured device results and idempotent
provider-free publication. Its new contract and native tests are prepared, not executed.
Completed autonomous writing assistance opens its durable native result directly from Scriptor
while publication is pending; it does not fabricate a Mac log ID or replace the original document.

Mobile and its extension target **0.1.0**, with configured Apple build **1001**, in
`ios/project.yml`. QA iteration numbers in local logs are not Apple build numbers. Desktop and
Server retain their own version contract. Native acceptance records the actual Desktop/mobile
commits, compiled binaries, shared resources and test inputs for each run.

The release gate requires every operation in `ios/Parity/parity-manifest.json` to have executed
acceptance and reviewed evidence. Historical scoped passes and skipped tests do not approve full
parity or TestFlight. Private fixtures, screenshots, logs and `.xcresult` bundles remain in ignored
`artifacts/acceptance-0.1.0`, outside GitHub.

GitHub Actions remains enabled in both repositories. At the user's request, implementation
continues without running workflows or an intermediate test campaign. Defer the complete checks
until implementation is ready. Changes are committed locally without pushing or editing the
draft PRs: the privileged CLA workflow also runs on PR updates and ignores `[skip ci]`.

## Licence

Proprietary. All rights reserved — see [LICENSE](LICENSE), including its note on the revisions that
were published under MIT before the code moved here.
