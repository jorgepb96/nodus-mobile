# Linked page-associated content

Status: source implemented; local compilation and acceptance **pending**.

A selected page's explicit linked-database references now include actual database attachment catalogues and chosen originals, actual row-associated page documents, raw page metadata and the dependencies in those associated pages. This closes the gap where the selected linked view could show rows but its existing row documents could not be opened offline.

The existing owning-vault database presentation supplies the actual row/page association. `CompanionDatabasePageDownload.capture` verifies page ownership and captured metadata and reads complete documents through the bounded batch protocol. Every linked row page is added to the same page traversal, where real page assets and explicit synced/linked references are retained. Identity sets break page and view cycles; the former 256-page traversal ceiling is removed in favour of the aggregate selected-copy size limit.

The complete page set undergoes another content comparison after dependency and asset preparation. Canonical query cursors and definitions are also checked again. A changed, inaccessible, oversized or cancelled source cannot produce a partially saved pack. Private sources stay within the selected, explicit dependency closure and their required grants.

Existing row-page capture checks cover complete pages, real owners, titles/dates, source-content epoch changes, duplicates, bounded batches and budget rejection. Whole linked-page traversal, cross-database cycles, selected image/file scope and opening the associated documents still require executed local contract and iPhone/iPad acceptance evidence. No executed result or release readiness is claimed by this record.
