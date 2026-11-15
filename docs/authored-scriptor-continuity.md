# Scriptor: durable authored documents

Status: source implemented, acceptance **pending**. The checks below are prepared but have not been compiled or executed for this change.

A canonical workspace-save receipt now stores the actual structured editor document and its actual note metadata in the encrypted, vault-scoped writing store before retiring the replayable request. Reusable reading-cache eviction cannot discard work written on the phone. This retains documents the user authored or edited; it does not download the Mac's complete workspace. Embedded document data remains structured, including BlockNote tables, images and academic metadata.

Only actual folder ancestors of retained authored notes and creations are persisted. A stale offline catalogue cannot overwrite confirmed note location or folder metadata. Offline catalogues overlay the confirmed editor revision, while live catalogues use the Mac's current membership and cannot resurrect missing confirmed notes. Trashed note metadata remains scoped to the trash catalogue.

Live reads still query the Mac. Only transport loss permits fallback to the owned document or selected/reusable copy; authorization and malformed responses remain visible. Newer canonical reads refresh an already-owned document. Explicit conflict resolution stores the selected Mac baseline before releasing the draft or rebasing it. Incorrect note identity or manual-idea provenance cannot become confirmed authorship.

Version 2 storage is bound to the vault and migrates legacy draft dictionaries. Disk writes are serialized to prevent an earlier autosave from replacing a later durable state during actor suspension.

Prepared checks in `CompanionDocumentOutboxTests`: structured acknowledged content with zero reusable-cache budget and restart; actual folder ancestry; stale offline catalogue and editor revisions; live membership and trash filtering; vault mismatch rejection; legacy queued edits; invalid ownership acknowledgements; explicit Mac conflict choice. Existing lost-acknowledgement and concurrent typing cases remain in the acceptance campaign.

Final local acceptance must exercise actual Desktop/iPhone/iPad save, reopening after expiry, Mac shutdown, conflict choices and reconnection. No TestFlight readiness is claimed by this source record.
