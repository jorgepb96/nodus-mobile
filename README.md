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
until implementation is ready; use `[skip ci]` on pushes to the open draft PRs. The privileged CLA
workflow uses the default branch and does not respect that marker, so consolidate remote updates
and cancel any automatic CLA runs for this branch rather than disabling repository Actions.

## Licence

Proprietary. All rights reserved — see [LICENSE](LICENSE), including its note on the revisions that
were published under MIT before the code moved here.
