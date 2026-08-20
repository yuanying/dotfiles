# Architecture Decision Records

One file per decision, named `NNNN-kebab-case-title.md`, numbered in the order
the decisions were made. A record says what the constraints were, what was
chosen, and — the part worth writing down — what was rejected and why, so that
a later reader does not spend an afternoon rediscovering a dead end.

Records are append-only. A decision that no longer holds is not edited away:
its `Status` becomes `Superseded by [[NNNN]]` (or `Deprecated`) and the
replacement gets a new number.
