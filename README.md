# Nodus Mobile

Mobile clients for [Nodus](https://github.com/Drakonis96/nodus), one directory per platform.

```
ios/          iOS and iPadOS app (SwiftUI), its Swift packages and its tools
```

Android has no directory yet. When it gets one it sits beside `ios/`, and nothing above this line
should have to change for it.

## What is not here

The corpus itself, and everything that reasons about it. These clients talk to a Nodus Server over
HTTPS and hold no authority over a vault: the desktop application publishes, the server serves, and
a phone reads what it is given. The domain model, the report design and the reading-copy rules live
in the Nodus repository and are not vendored here — a copy would drift, and drift is precisely what
`ios/scripts/test-reading-copy-parity.mjs` exists to catch.

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

The desktop and Nodus Server are kept to a single version number by a test in that repository. This
repository is no longer part of that check, so a build states the release it targets in
`ios/project.yml` and the server states its own at `/healthz`. When they disagree, the server is
right.

## Licence

Proprietary. All rights reserved — see [LICENSE](LICENSE), including its note on the revisions that
were published under MIT before the code moved here.
