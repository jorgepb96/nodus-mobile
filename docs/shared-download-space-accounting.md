# Shared dependency space accounting

Status: source implemented; local tests and device acceptance **pending**.

A nested page download may return the same linked-database envelope already retained by its parent. Its read budget now accounts for that actual overlap, so early preflight does not reject an otherwise fitting union. Only a validated corpus envelope for the actual vault grants overlap, and each nested read remains capped at 50 MiB.

This affects the temporary preparation budget. The parent still merges exact canonical dossiers, rejects a changed same-ID payload, counts the final unique records and enforces the protected pack's unchanged 50 MiB storage ceiling, including encryption and manifest overhead. Borrowed read space does not permit a larger saved download.

Prepared checks cover three row pages sharing a large dossier near their final plaintext boundary, unique new bytes exceeding that boundary, foreign-vault envelopes and negative read budgets. They have not been executed for this source change. Final local acceptance must additionally check protected-storage boundaries, cancellation and peak memory on real devices.
