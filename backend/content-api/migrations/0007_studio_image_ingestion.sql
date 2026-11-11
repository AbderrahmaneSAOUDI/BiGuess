-- Private staged images. No change to published immutable object keys/artifacts.
CREATE TABLE IF NOT EXISTS studio_image_uploads (
  pack_id TEXT NOT NULL,
  object_reference TEXT NOT NULL,
  actor_uid TEXT NOT NULL,
  request_uid TEXT NOT NULL,
  request_role TEXT NOT NULL CHECK(request_role IN ('owner_admin','collector')),
  pack_revision INTEGER NOT NULL,
  staging_key TEXT UNIQUE,
  byte_length INTEGER NOT NULL CHECK(byte_length BETWEEN 1 AND 5242880),
  content_type TEXT NOT NULL CHECK(content_type IN ('image/png','image/webp')),
  width INTEGER NOT NULL CHECK(width BETWEEN 1 AND 1024),
  height INTEGER NOT NULL CHECK(height BETWEEN 1 AND 1024),
  state TEXT NOT NULL CHECK(state IN ('reserved','ready','attached','deleting')),
  lease_token TEXT NOT NULL,
  lease_expires_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  canonical_reserved INTEGER NOT NULL DEFAULT 0 CHECK(canonical_reserved IN (0,1)),
  PRIMARY KEY(pack_id,object_reference)
);
CREATE INDEX IF NOT EXISTS studio_image_actor ON studio_image_uploads(actor_uid);
CREATE INDEX IF NOT EXISTS studio_image_expiry ON studio_image_uploads(state,expires_at);
CREATE TABLE IF NOT EXISTS studio_image_cleanup_scan (id INTEGER PRIMARY KEY CHECK(id=1), cursor TEXT);
INSERT OR IGNORE INTO studio_image_cleanup_scan VALUES (1,NULL);
CREATE TRIGGER IF NOT EXISTS studio_image_reservation_guard BEFORE INSERT ON studio_image_uploads
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM studio_entities p JOIN studio_entities t ON t.resource_type='topic' AND t.id=p.parent_id
      JOIN studio_creators c ON c.resource_type='pack' AND c.resource_id=p.id
    WHERE p.resource_type='pack' AND p.id=NEW.pack_id AND p.state IN ('active','hidden')
      AND t.state IN ('active','hidden') AND p.revision=NEW.pack_revision
      AND (NEW.request_role='owner_admin' OR (c.source='authenticated' AND c.created_by_uid=NEW.request_uid))
  ) THEN RAISE(ABORT,'image_scope_changed') END;
  SELECT CASE WHEN (SELECT coalesce(sum(byte_length),0) FROM studio_image_uploads WHERE pack_id=NEW.pack_id)+NEW.byte_length>104857600
    OR (SELECT count(*) FROM studio_image_uploads WHERE pack_id=NEW.pack_id)>=1000
    OR (SELECT coalesce(sum(byte_length),0) FROM studio_image_uploads WHERE actor_uid=NEW.actor_uid)+NEW.byte_length>524288000
    THEN RAISE(ABORT,'image_quota_exceeded') END;
END;
CREATE TRIGGER IF NOT EXISTS studio_image_finalize_guard BEFORE UPDATE ON studio_image_uploads
WHEN NEW.state='ready' AND OLD.state='reserved'
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM studio_entities p JOIN studio_entities t ON t.resource_type='topic' AND t.id=p.parent_id
      JOIN studio_creators c ON c.resource_type='pack' AND c.resource_id=p.id
    WHERE p.resource_type='pack' AND p.id=NEW.pack_id AND p.state IN ('active','hidden')
      AND t.state IN ('active','hidden') AND p.revision=NEW.pack_revision
      AND (NEW.request_role='owner_admin' OR (c.source='authenticated' AND c.created_by_uid=NEW.request_uid))
  ) THEN RAISE(ABORT,'image_scope_changed') END;
END;
-- A binding can expire after mutation validation. This insert runs in the same
-- guarded T24 transaction and closes that race before any Card is changed.
CREATE TABLE IF NOT EXISTS studio_image_commits (
  batch_id TEXT NOT NULL,
  pack_id TEXT NOT NULL,
  object_reference TEXT NOT NULL,
  PRIMARY KEY(batch_id,pack_id,object_reference)
);
CREATE TRIGGER IF NOT EXISTS studio_image_attachment_guard BEFORE INSERT ON studio_image_commits
BEGIN
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM studio_pack_images
      WHERE pack_id=NEW.pack_id AND object_reference=NEW.object_reference)
    OR EXISTS (SELECT 1 FROM studio_image_uploads WHERE pack_id=NEW.pack_id
      AND object_reference=NEW.object_reference AND state NOT IN ('ready','attached'))
    THEN RAISE(ABORT,'image_binding_expired') END;
  UPDATE studio_image_uploads SET state='attached' WHERE pack_id=NEW.pack_id AND object_reference=NEW.object_reference;
END;
