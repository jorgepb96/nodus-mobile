# Authored offline pages — source stage

A new standalone page created through the typed mutation outbox now receives a protected durable empty document immediately. The shared BlockNote editor opens that owned document while the Mac is unavailable, saves the full structured draft and reopens it independently of selected read-copy expiry. The empty revision-one creation baseline is used only for this new identity. It cannot replace an already consulted Mac baseline; subsequent Mac page/document edits still trigger the existing explicit conflict flow.

Before document edits and dependent jobs are submitted, the foreground coordinator drains already-authorised content changes and checks actual applied state. Pending mutations and legacy acceptance without proof of application hold those dependent requests. Unsubmitted drafts remain untouched. A network failure therefore does not turn a not-yet-created parent into a permanent missing-page write failure.

Prepared Kit cases cover creation/reopening/structured editing, the original empty baseline, refusing an existing page and pending/accepted/applied parent transitions. **Unexecuted and uncompiled for this revision.** Canonical Mac integration, lost acknowledgements, keyboard/editor behaviour and iPhone/iPad acceptance remain pending.
