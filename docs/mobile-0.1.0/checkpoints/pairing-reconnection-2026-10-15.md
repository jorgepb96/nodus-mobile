# Pairing and reconnection — 2026-10-15

Scope: Desktop connection, reconnection and native connection controls. Broader mobile parity remains unfinished. All data writes use marked isolated copies; normal Desktop installation and original vaults stay unchanged. Both PRs remain unmerged. The owner's one complete CI exception applies to Desktop only; no mobile Actions are requested or disabled.

## Baseline and build identity

Original references: Desktop `0a173fd9c698a7cb2d5989aa64b59cddd329bcf9`, mobile `ad6e3069bcea67b48de76de561fc27c3db417563`.

Delivered beta **0.1.0 (1002)** remains available internally. Before these changes, mobile `07e0fca65ea5be9113893fec2ea2334f495975ad` had no connection-source differences from the supplied beta source `bd1f008`; this is a source comparison, not retrospective binary acceptance.

The successor is configured as **0.1.0 (1003)** for app and extension. It contains native connection fixes; it is **not yet archived/uploaded** by this checkpoint. Shared Desktop surface resources intentionally retain beta 1002's Desktop `80c54bd09e0aa8d85f96b1978f05094fe7d2316f` provenance. No claim of current-main renderer parity is made.

Desktop's compatible private preview is Nodus 5.10.0, arm64, Electron 43.6.0, Developer-ID signed with team `6RPLS9EA4X`; strict/deep verification and all 81 individual code components passed. It is not notarized, installed over normal Nodus or published. Its production code is built at Desktop `9dfa24f7`, with dependency/signing corrections at `756c6473`/`63100ae9`. The [Desktop checkpoint](https://github.com/jorgepb96/nodus/blob/codex/mobile-0.1.0-parity/docs/mobile-0.1.0/checkpoints/direct-connection-2026-10-15.md) records hashes and packaging details.

## Implemented behavior

- Desktop's dedicated **Conexión móvil** Settings tab offers one temporary code, QR or link for the complete workspace. The actual preload now forwards `{wholeWorkspace:true}`; the old lost argument caused private-domain errors after apparent pairing. Advanced server/cloud controls remain outside the primary mobile flow.
- The permanent `_nodus-mobile._tcp` advertisement provides only bounded, public `discoveryVersion=1`, Mac UUID and HTTPS address hints (`rc`, `r0`…`r15`). It never broadcasts codes, tokens, pins or vault names. Existing single-use-code advertisements remain compatible.
- `DesktopLinkedMacAdvertisement` validates UUID/count/HTTPS syntax and payload limits. `LinkedMacDiscovery` bounds services, resolves/retries with capped backoff, watches TXT changes and cancels on background/removal/success.
- `verifyDiscoveredOrigin` probes capabilities without authentication using the already approved TLS leaf pin and a four-second timeout. Redirects stay disabled; exact Mac identity must match before a bearer can reach the new origin.
- The store rechecks the grant under the renewal lock. Current token, pin, grant/device IDs, expiry, scopes and local storage ownership stay unchanged. A healthy primary is retained; individually verified alternatives are learned for later use. Existing clients follow a verified primary change without rebuilding mounted sessions/editors.
- Captured private clients use the canonical grant credential instead of stale origin aliases. Pending, revoked and expired grants cannot be revived through discovery; ambiguous writes are not retried blindly.
- Visible native Settings diagnostics are keyed by origin and protected from stale completion; a cancellable 30-second refresh covers a returning Mac on the same origin. Semantic probes use generation guards and retry the actual HTTP operation after recovery. Live never changes to autonomous automatically.
- Whole-workspace catalogs reconcile newly created/removed vaults. Desktop-issued code renewal preserves the existing phone/grant/workspace; mobile renew rotates the credential, while revoke requires confirmation and removes every connection associated with the grant.

## Executed native and transport acceptance

Private evidence: `artifacts/pairing-2026-10-15/`. Each native `.source.json` was recorded before execution and includes a successful exact-source build receipt and artifact digests. Missing inputs fail acceptance; an omitted test is not a pass. Physical iPhone testing remains assigned to the owner after TestFlight.

| Operation | Actual result | Evidence |
| --- | --- | --- |
| Portable connection/security contracts, including real macOS HTTPS | PASS: 76 tests / 12 suites / 0 skips | `mobile-pairing-resolution-retry.log` |
| Native storage/retired aliases and same/changed-origin semantic recovery | PASS: 9 tests / 0 skips | `native-storage-02.xcresult` |
| iPhone: enter real Desktop UI code, Bonjour, pinned HTTPS, whole workspace and process restart | PASS: 1 UI test / 0 skips | `code-iphone-02.xcresult` |
| iPad: same code/workspace/restart path; primary QR camera sheet open/close and advanced fields absent | PASS: both UI cases; mixed bundle's unit race failed and was corrected separately | `code-ipad-01.xcresult`; corrected units in `native-storage-02.xcresult` |
| Desktop creates a new isolated vault after linking | PASS: 13 visible connections, no new code, two app restarts | `new-vault-iphone-02.xcresult` |
| Desktop deletes only the newly created QA vault | PASS: removed vault disappears, other 12 remain usable across two restarts | `removed-vault-iphone-01.xcresult` |
| Actual Mac shutdown/restart on same port while iPad Settings remains foreground | PASS: current Mac model, successful real semantic response, Live retained | `reconnect-ipad-01.xcresult` |
| Actual saved-port occupation forces Mac to another port while iPhone Settings stays foreground | PASS: Bonjour/pinned HTTPS recovery, actual new model and semantic identity, no code or injected origin | `reconnect-iphone-02.xcresult` |
| Desktop Settings renews the existing phone using an actual new code/QR | PASS: same Mac/grant/device/pin/scopes and 12 connections; restart works; primary connection UI passes | `code-renewal-iphone-01.xcresult`, laboratory `iphone-code-renewal-result.json` |
| Native renew button; restart without another code | PASS | `native-controls-iphone-02.xcresult` |
| Native revoke cancel preserves Live; confirm removes all 12 vaults; restart does not restore access | PASS: combined controls bundle 2 tests / 0 failures / 0 skips | `native-controls-iphone-02.xcresult` |
| New code after real revocation links the workspace again | PASS | `relink-iphone-01.xcresult` |
| Signed packaged Desktop generates real code → iPhone discovers/links all 12 vaults → native restart | PASS: 1 UI test / 0 skips; real native-store postconditions checked | `packaged-code-iphone-01.xcresult`, `.result.json` |
| Signed packaged Desktop stops/restarts while iPhone Settings remains foreground | PASS: 1 UI test / 0 skips; real current model and semantic response, existing grant and Live retained | `packaged-reconnect-iphone-03.xcresult`, `.source.json`, `.result.json` |
| Actual Desktop Settings QR pixels | PASS: Apple Vision decodes code/pin/Mac/all 12 vaults | Desktop laboratory `qr-vision-result.json` |

Native build 09 and the signed-app code test used mobile `d99adbca0acbefc13ca05979ac051c33bf1243b3`. Build 10 at `0624e03` changes only the test's separate bounded model/semantic waits; no production mobile behavior changed. Earlier accepted builds/tests keep their own actual receipts, rather than being attributed retrospectively to build 10.

The portable HTTPS fixture runs on macOS with isolated Node/OpenSSL servers and temporary certificates. It rejects a bad certificate before HTTP, rejects a correctly pinned wrong Mac without sending a bearer, then verifies later authenticated use, alternative learning, revocation/renewal races, pending/expired states, lost acknowledgement and ambiguous-write boundaries. These fixtures do not count as native iOS TLS/Bonjour acceptance; the native runs above supply that separate evidence. Model markers are stored on the actual isolated Mac; no AI-provider request is needed to verify the catalog.

## Failure history and remaining limits

Raw failed attempts are preserved. `code-iphone-01` linked successfully but then failed an unrelated report keyboard assertion. The first iPhone recovery exposed a real stale embedding error and led to the cancellation/generation/retry fix. The mixed iPad bundle failed the unit wait race despite its UI passes. Native controls attempt 01 failed only a deferred screenshot of an already terminated app after the revocation assertions passed; attempt 02 corrects the capture lifetime and passes. The first packaged foreground recovery got the model but spent its shared deadline before scrolling to semantic status; build 10 gives that distinct assertion its own bounded time. A subsequent manually timed attempt restarted the Mac too late for the model deadline; it is not accepted as a product result. Automated lifecycle orchestration removes that model-turn timing dependency and passes in `packaged-reconnect-iphone-03`, using build 10 at `0624e0318667b3d7188e5826a4fb91cc5223c8e1`.

- Real LAN code/Bonjour/HTTPS and same/changed-port reconnection have executed. A real change of Wi-Fi interface, sleep/wake and IPv6-only Desktop route are not established by a port-collision fixture.
- Tailscale is installed but its backend is stopped and no online peer/route is available. **Real VPN handover remains unverified.** Learned approved VPN-origin fixtures do not prove multicast or actual VPN routing.
- QR decoding used actual pixels and Apple Vision. Camera-sheet UI open/close passed; a physical iPhone camera scan is not claimed.
- No provider-generation or whole-application parity campaign is approved by these connection tests.
- Version 1002 does not contain these native rediscovery fixes. Build 1003 delivery remains a separate release step; do not tell testers they already have the new binary.

Credentials, private offers, copied vault contents, screenshots, logs and `.xcresult` bundles remain local. Only sanitized descriptions and source are committed.
