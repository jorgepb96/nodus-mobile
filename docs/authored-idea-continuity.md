# Authored ideas after acknowledgement

Status: source implemented; local compilation and acceptance **pending**.

Confirmed manual-idea notes written on the mobile device are now projected from the durable writing store into the offline idea catalogue. Only real owning note IDs and `manual-idea` provenance are eligible. Their latest structured text can be consulted after restart and reusable-cache eviction.

This projection carries an explicit `authoredText` scope. It supplies the user's text, not a canonical downloaded dossier. The native catalogue replaces placeholder statistics with “Texto propio”; readers explain that evidence and connections require their own download. Queries for an unknown neighbourhood return an explicit unavailable result. Live reads remain authoritative, and a confirmed text copy is ineligible for the pending-creation 404 fallback.

A complete selected dossier wins over an authored-text projection, regardless of copy order. Partial text cannot suppress actual selected graph edges or claim absence of evidence. This preserves downloaded historical dossier semantics; Scriptor retains the separately confirmed authored document.

The shared idea inspector now handles failed detail/edge reads, preserves a successfully loaded detail when connections fail, and offers retry. A failed connection request cannot display a false “no connections” state. Authored-text readers skip canonical neighbourhood queries and identify their actual scope.

Prepared checks: acknowledged manual idea survives zero reusable-cache budget and reopening; owning vault isolation; complete selected dossier and graph precedence in both copy orders; unknown neighbourhood errors; malformed partial evidence rejection. These checks have not been executed for this source change. Actual iPhone/iPad/desktop interaction and reconnection remain acceptance requirements.
