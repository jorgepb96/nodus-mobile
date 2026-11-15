# Bounded row-page consultation

Status: source implemented; local compilation, contract execution and device performance **pending**.

Desktop exposes a corpus-only, read-only `getMobilePageDocuments` operation. The request enumerates actual page identities, allows at most 2,000 identities per request and returns at most 20 documents per cursor page. A 4 MiB soft response budget separates extensive documents into smaller batches; a single larger document retains the existing 32 MiB transport ceiling. Every response observes one owning-vault SQLite transaction. Malformed identities, duplicate identities, foreign or missing pages and invalid cursors fail explicitly.

The mobile download validates actual vault and page ownership, response order, total count, progress and exact continuation. It reads all associated row pages in bounded batches and compares the complete sources with a second batch pass after preparing dependencies. Mac capabilities select the batch path; older compatible Macs retain individual reads and the same final source comparison. Permission or transport errors never trigger a fallback to a different protocol.

The page source already includes the canonical `pageDocumentAssets` catalogue. Downloads reuse that actual catalogue, rather than requesting it again for each row. Root document checks are grouped at the owning row-page capture; separately followed synced sources still undergo their own final checks. Documents, asset descriptors and chosen originals remain in one atomic selected pack with its 50 MiB aggregate protected-storage ceiling.

Prepared checks include 523 row-associated documents, bounded cursor progression, complete-content changes with unchanged titles, invalid cursor/order/count/vault responses and local read-budget failures. Actual Desktop fixtures cover 41 ordered pages, no SQL writes during consultation, a large document split, invalid requests and owning-vault isolation. These checks have not been executed for this change.

Final acceptance must measure real LAN/VPN latency and memory, cancel during preparation, change a source mid-download and verify reopening documents, covers, files and linked content on iPhone/iPad.
