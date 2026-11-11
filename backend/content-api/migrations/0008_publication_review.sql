-- T35 review metadata is separate from gameplay and immutable signed history.
CREATE TABLE studio_rights_approvals (
  pack_id TEXT NOT NULL,
  subject TEXT NOT NULL,
  evidence TEXT NOT NULL,
  actor_uid TEXT NOT NULL,
  approved_at TEXT NOT NULL,
  PRIMARY KEY(pack_id,subject)
);
CREATE TABLE studio_publication_approvals (
  resource_type TEXT NOT NULL CHECK(resource_type IN ('topic','pack')),
  resource_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  actor_uid TEXT NOT NULL,
  approved_at TEXT NOT NULL,
  PRIMARY KEY(resource_type,resource_id,fingerprint)
);
CREATE TABLE studio_release_requests (
  id TEXT PRIMARY KEY NOT NULL,
  pack_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  revision INTEGER NOT NULL,
  expected_revision INTEGER NOT NULL,
  actor_uid TEXT NOT NULL,
  actor_role TEXT NOT NULL CHECK(actor_role IN ('owner_admin','collector')),
  created_at TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending_operator','released')),
  UNIQUE(pack_id,fingerprint)
);
-- All workflow writes use the same optimistic generation fence as T24/T22.
CREATE TABLE studio_publication_events (
  id TEXT PRIMARY KEY NOT NULL,
  resource_type TEXT NOT NULL,
  resource_id TEXT NOT NULL,
  action TEXT NOT NULL,
  actor_uid TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  expected_generation INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TRIGGER studio_publication_event_guard BEFORE INSERT ON studio_publication_events
BEGIN
  SELECT CASE WHEN NEW.expected_generation != (SELECT generation FROM studio_generation WHERE id=1)
    THEN RAISE(ABORT,'review_conflict') END;
END;
CREATE TRIGGER studio_publication_event_generation AFTER INSERT ON studio_publication_events
BEGIN UPDATE studio_generation SET generation=generation+1 WHERE id=1; END;
CREATE TRIGGER studio_publication_event_no_update BEFORE UPDATE ON studio_publication_events
BEGIN SELECT RAISE(ABORT,'immutable_review'); END;
CREATE TRIGGER studio_publication_event_no_delete BEFORE DELETE ON studio_publication_events
BEGIN SELECT RAISE(ABORT,'immutable_review'); END;
-- The private operator inserts this BEFORE the T22 generation guard, in the
-- very same activation transaction. It does not advance the generation itself.
CREATE TABLE studio_release_guards (
  request_id TEXT PRIMARY KEY NOT NULL REFERENCES studio_release_requests(id),
  expected_generation INTEGER NOT NULL
);
CREATE TRIGGER studio_release_guard BEFORE INSERT ON studio_release_guards
BEGIN
  SELECT CASE WHEN NEW.expected_generation != (SELECT generation FROM studio_generation WHERE id=1)
    OR NOT EXISTS (SELECT 1 FROM studio_release_requests WHERE id=NEW.request_id AND status='pending_operator')
    THEN RAISE(ABORT,'review_conflict') END;
END;
CREATE TRIGGER studio_rights_no_update BEFORE UPDATE ON studio_rights_approvals
BEGIN SELECT RAISE(ABORT,'immutable_rights'); END;
CREATE TRIGGER studio_rights_no_delete BEFORE DELETE ON studio_rights_approvals
BEGIN SELECT RAISE(ABORT,'immutable_rights'); END;
CREATE TRIGGER studio_approval_no_update BEFORE UPDATE ON studio_publication_approvals
BEGIN SELECT RAISE(ABORT,'immutable_approval'); END;
CREATE TRIGGER studio_approval_no_delete BEFORE DELETE ON studio_publication_approvals
BEGIN SELECT RAISE(ABORT,'immutable_approval'); END;
CREATE TRIGGER studio_request_no_update BEFORE UPDATE ON studio_release_requests
WHEN OLD.status!='pending_operator' OR NEW.status!='released'
  OR NEW.id!=OLD.id OR NEW.pack_id!=OLD.pack_id OR NEW.fingerprint!=OLD.fingerprint
  OR NEW.revision!=OLD.revision OR NEW.expected_revision!=OLD.expected_revision
  OR NEW.actor_uid!=OLD.actor_uid OR NEW.actor_role!=OLD.actor_role OR NEW.created_at!=OLD.created_at
BEGIN SELECT RAISE(ABORT,'immutable_release_request'); END;
CREATE TRIGGER studio_request_no_delete BEFORE DELETE ON studio_release_requests
BEGIN SELECT RAISE(ABORT,'immutable_release_request'); END;
