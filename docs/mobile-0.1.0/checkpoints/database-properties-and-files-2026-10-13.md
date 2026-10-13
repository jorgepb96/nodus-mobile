# Database checkpoint — 2026-10-13

This checkpoint records implemented work and remaining integration. It is not release acceptance, native visual validation or proof of physical-device behavior.

## Committed implementation

- Mobile `c15a955`: all 29 canonical property types and their configuration controls; typed date/time, multiple-choice, people and location editors. Existing configuration fields and unknown canonical fields survive edits. Model references contain provider/model names, without provider credentials.
- Mobile `0729bcd`: authored checkpoint/index/summary commits use encrypted staging and a durable commit marker. An interrupted replacement recovers all three before reading or archiving. Summary ownership requires the actual indexed deep-research checkpoint. Manual property/row saves hold the existing authoring activity lease through durable queueing.
- Mobile `dd3be79`: row edits keep first-touch cell revision/value baselines; untouched cells are not submitted after a background refresh.
- Mobile `ce74f3a`: explicit text/image/button action controls, context downloads for 7/30 days, real errors/status and existing job observation. These controls depend on the separately owned action implementation and its remaining integration below.
- Desktop `8afc72ee`: canonical create/update column configuration, typed option identities, canonical hooks/CAS/duplicate receipts; authenticated 512 KiB chunk transport with complete SHA and actual SQLite storage boundary. No 12 MB entity limit, extraction, indexing or provider invocation.
- Desktop `0f0921ff`: canonical relationship identities, exact relation-set and column-revision preconditions, attachment deletion requiring actual owner/revision/hash. Cross-vault entity targets require the effective vault list supplied by authenticated server authorization; client arguments cannot grow a legacy grant.
- Native consultation includes actual `db_computed_cells` and canonical row metadata. Formula/rollup consultation uses materialized Mac results (fixture 22/12); missing results remain explicit. Native formula evaluation is not used for display.

## Evidence

- Focused NodusKit: 12 tests / 4 suites passed; `/private/tmp/nodus-db-indexed-kit.log`. Includes interrupted commit recovery, exact summary/checkpoint pairing, concurrent index writers, property preservation and materialized consultation. Earlier property/projection/recovery selection: 24 tests passed.
- Actual canonical Desktop mutation fixture passed: `/private/tmp/nodus-db-properties-tests.log`. Includes 29 types, typed options, original-value CAS, stable duplicate receipts, granted versus ungranted cross-vault targets, relation-set CAS and protected attachment deletion.
- Production upload module fixture passed: `/private/tmp/nodus-db-file-tests.log`. Actual canonical 13 MiB + 17 byte readback, chunk resume, stable lost-ACK identity, grant namespace, SHA, source revision conflict; no provider or extraction.
- Native source parse passed. Current native build, interaction, rotation and UI E2E remain unverified for these changes. Physical tests remain with the user after TestFlight.
- The separate real HTTPS upload fixture is recorded by its test source and final runner output; do not treat an uncompleted run as passing.

## Not yet operational

1. The tracked `CompanionDatabaseAttachments.swift.txt` is an unfinished design/code draft outside every production target. It references unimplemented cache-owned file-directory and client upload methods. It has no archive sidecar/receipt validation, new-grant review/adoption, completed-file eviction, stream import or ZIP export. Its initial `Data` chunk preparation also still needs bounded streaming for user-selected large files. Do not rename it into the source tree or claim native attachment upload is implemented.
2. Native relation selection and attachment import/delete/progress/resume UI remain to be connected to the tested canonical backend. Existing consultation continues to show actual relations and private-file controls.
3. Autonomous button execution and the large-image native staged-blob publication path remain in the separate action lane. Text/image/button job allowlists, recovery classifiers and the concrete action publication initializer must be integrated and tested before these UI callbacks are considered complete. Paid results must stay durable and never cause automatic paid retries.
4. Streaming ZIP and protected export lease APIs were designed but not implemented in this checkpoint. Archives without attachments retain the existing JSON export behavior.
5. Parent xcodegen registration is required for `DatabasePropertyConfigurationViews.swift` and separately owned new native action files, followed by current-source native build and acceptance.

No real vaults were modified. No push, GitHub Actions or workflow change was performed by this lane.
