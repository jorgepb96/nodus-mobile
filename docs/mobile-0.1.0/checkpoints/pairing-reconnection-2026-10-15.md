# Pairing and reconnection — 2026-10-15

Scope: linked Desktop connection only. No vault parity work, provider execution, real-vault mutation, upload or GitHub Actions.

## Baseline and beta 1002

The audited clean mobile baseline was `07e0fca65ea5be9113893fec2ea2334f495975ad`. Compared with beta 1002's supplied source `bd1f008`, Bridge, AppModel, SpaceSession, PairingDiscovery, ConnectionClient, RootView and connection storage had no source differences before this patch. This compares source; it does not revalidate the installed beta binary or its live network behavior.

Baseline tests passed: 28 tests / 6 suites for pairing/offers/lost acknowledgement/renewal/network/scope, and 39 tests / 5 suites for failure classification, relay boundaries and selected offline fallback. Outputs: `artifacts/pairing-2026-10-15/mobile-pairing-core.log` and `mobile-pairing-fallback.log`.

Real gap: beta 1002 only retries stored origins. If all saved addresses become unusable, it cannot discover a newly assigned Mac address without linking again. Bonjour across a VPN is not assumed. A VPN origin already approved remains usable without Bonjour. New discovery support requires the connection-only successor build (planned 1003); the Desktop advertisement remains compatible with beta 1002's original code/QR flow.

## Agreed Desktop contract

A permanent `_nodus-mobile._tcp` advertisement while linked-device grants exist:

- `discoveryVersion=1`
- `macId=<actual Mac UUID>`
- `rc=1..16`
- `r0` through `r<count-1>`: HTTPS origins, each at most 240 UTF-8 bytes, no user info, path, query or fragment.

No code, token, relay key or trusted certificate is transmitted. Existing `n/proof/pN` single-use-code advertisements remain unchanged. The permanent advertisement is an untrusted address hint. Desktop owns listener/advertisement persistence and refresh when interfaces change; this mobile lane did not edit Desktop.

## Mobile implementation

- `DesktopLinkedMacAdvertisement` bounds the payload and validates UUID/count/HTTPS origin syntax, including bracketed IPv6.
- Separate `LinkedMacDiscovery` uses the existing Bonjour service permission. It resolves a bounded service list, monitors TXT changes, retries with cooldown, and stops/cancels on suspension. It starts only when an existing linked grant is valid, stored, unlocked and not pending.
- Before any bearer is sent, `DesktopBridgeClient.verifyDiscoveredOrigin` makes a four-second, unauthenticated `/bridge/v1/capabilities` probe using the existing approved TLS leaf pin. Redirects remain disabled. The exact Mac identity must match.
- The store rechecks the current grant under its renewal lock. Only addresses and verified legacy Mac identity can change. Token, pin, grant ID, phone ID, paired date, expiry, vaults, domains and archive ownership remain current and unchanged.
- A healthy primary is retained; new alternatives are individually verified and remembered. This allows a VPN address learned on LAN to remain available after leaving LAN, without assuming multicast over VPN.
- Already-open clients adopt a changed stored primary on the next request, including when the old origin remains an approved alternative. Mounted sessions/editors are not recreated. All linked cards receive the same verified transport update; IDs, storage and execution-mode preference keys are unchanged.
- Private foreground/background clients obtain the canonical grant credential rather than an obsolete origin alias. Retired aliases are removed after new connection persistence; revocation also cleans aliases for remembered origins. Existing scoped reads/writes continue to enforce current permissions.
- Discovery cannot complete a pending pairing, reactivate an expired/revoked grant or change to autonomous mode. Ambiguous writes retain the existing no-retry rule.

## Verification and limits

The final focused core run covers 74 tests / 12 suites: `artifacts/pairing-2026-10-15/mobile-pairing-final.log`. It includes TXT validation, actual local HTTPS certificate rejection before HTTP, unauthenticated Mac identity checks, later authenticated use by an already-open client, newly verified VPN alternatives, concurrent renewal/revocation, pending/expired grants, actual QR pixel decoding, lost acknowledgement recovery, weaker scopes, offline grants and write retry boundaries.

The actual HTTPS fixture runs on macOS and uses isolated Node/OpenSSL servers and temporary certificates; it is conditionally compiled for macOS because iOS cannot launch those processes. It does not count as an iOS TLS or Bonjour acceptance run. URLProtocol tests separately verify request/credential ordering and races. No test silently skips a failed network scenario.

Native edited sources parse successfully. A native regression was added to `MobileSurfaceStorageTests` for captured private connections after origin aliases are retired; it is prepared but not executed by this lane. UIKit build/typecheck, simulator Bonjour permission/advertisement discovery, server restart with an editor open, real LAN changes and Tailscale/VPN routing remain explicit coordinated acceptance gates. Physical testing remains with the user after TestFlight. Do not label the end-to-end flow 100% accepted from core tests alone.

Expiry audit: the inspected Desktop renewal rotates the token and retains the grant expiry, returning `id/renewedAt`; new simple grants have `expiresAt:null`. The ten-minute code expiry is separate. No ignored expiry-extension defect was established in that server contract.
