-- Actor-scoped historical counts and activity use the immutable audit as their
-- authority. This index avoids scanning other contributors' rows; no counters
-- or additional per-action writes are introduced.
CREATE INDEX studio_audit_actor ON studio_audit(actor_id);
