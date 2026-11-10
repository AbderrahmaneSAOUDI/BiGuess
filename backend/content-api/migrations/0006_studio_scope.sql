-- Additive, local-only contributor scope. Reapplication preserves evidence and
-- cursor keys. Existing draft columns and immutable public artifacts are intact.
CREATE TABLE IF NOT EXISTS studio_creators (
  resource_type TEXT NOT NULL CHECK(resource_type IN ('topic','pack','card')),
  resource_id TEXT NOT NULL,
  created_by_uid TEXT,
  created_at TEXT,
  source TEXT NOT NULL CHECK(source IN ('legacy','authenticated')),
  PRIMARY KEY(resource_type,resource_id),
  CHECK((source = 'legacy' AND created_by_uid IS NULL AND created_at IS NULL)
    OR (source = 'authenticated' AND created_by_uid IS NOT NULL AND length(created_by_uid) BETWEEN 1 AND 128 AND created_at IS NOT NULL))
);
INSERT OR IGNORE INTO studio_creators
  SELECT resource_type,id,NULL,NULL,'legacy' FROM studio_entities;
CREATE INDEX IF NOT EXISTS studio_creator_scope ON studio_creators(resource_type,created_by_uid,resource_id);
-- Attribution may only be established after its typed entity and parent exist.
-- The legacy backfill precedes this guard so historical malformed fences remain
-- Owner-only rather than making an old database impossible to migrate.
CREATE TRIGGER IF NOT EXISTS studio_creator_entity_guard BEFORE INSERT ON studio_creators
WHEN NEW.source = 'authenticated'
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM studio_entities e WHERE e.resource_type = NEW.resource_type AND e.id = NEW.resource_id
      AND (e.resource_type = 'topic' OR EXISTS (
        SELECT 1 FROM studio_entities p JOIN studio_creators c
          ON c.resource_type = p.resource_type AND c.resource_id = p.id
        WHERE p.resource_type = CASE e.resource_type WHEN 'pack' THEN 'topic' ELSE 'pack' END
          AND p.id = e.parent_id
      ))
  ) THEN RAISE(ABORT,'invalid_creator_entity') END;
END;
CREATE TRIGGER IF NOT EXISTS studio_creator_no_update BEFORE UPDATE ON studio_creators
BEGIN SELECT RAISE(ABORT,'immutable_creator'); END;
CREATE TRIGGER IF NOT EXISTS studio_creator_no_delete BEFORE DELETE ON studio_creators
BEGIN SELECT RAISE(ABORT,'immutable_creator'); END;
CREATE TABLE IF NOT EXISTS studio_pack_images (
  pack_id TEXT NOT NULL,
  object_reference TEXT NOT NULL,
  established_by_uid TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY(pack_id,object_reference)
);
CREATE TABLE IF NOT EXISTS studio_scope_versions (
  scope_key TEXT PRIMARY KEY NOT NULL,
  version INTEGER NOT NULL CHECK(version BETWEEN 0 AND 9007199254740991)
);
INSERT OR IGNORE INTO studio_scope_versions VALUES ('owner',0),('taxonomy',0);
CREATE TABLE IF NOT EXISTS studio_read_changes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  generation INTEGER NOT NULL,
  resource_type TEXT NOT NULL CHECK(resource_type IN ('topic','pack','card')),
  resource_id TEXT NOT NULL,
  pack_id TEXT,
  pack_creator_uid TEXT,
  kind TEXT NOT NULL CHECK(kind IN ('upsert','remove')),
  projection_json TEXT NOT NULL CHECK(json_valid(projection_json)),
  CHECK((resource_type = 'topic') = (pack_id IS NULL))
);
CREATE INDEX IF NOT EXISTS studio_changes_creator ON studio_read_changes(pack_creator_uid,sequence);
CREATE INDEX IF NOT EXISTS studio_changes_resource ON studio_read_changes(resource_type,sequence);
CREATE INDEX IF NOT EXISTS studio_changes_generation ON studio_read_changes(generation,sequence);
CREATE TRIGGER IF NOT EXISTS studio_changes_no_update BEFORE UPDATE ON studio_read_changes
BEGIN SELECT RAISE(ABORT,'immutable_studio_change'); END;
CREATE TRIGGER IF NOT EXISTS studio_changes_no_delete BEFORE DELETE ON studio_read_changes
BEGIN SELECT RAISE(ABORT,'immutable_studio_change'); END;
CREATE TRIGGER IF NOT EXISTS studio_changes_view_version AFTER INSERT ON studio_read_changes
BEGIN
  UPDATE studio_scope_versions SET version = version + 1 WHERE scope_key = 'owner';
  UPDATE studio_scope_versions SET version = version + 1 WHERE scope_key = 'taxonomy' AND NEW.resource_type = 'topic';
  INSERT INTO studio_scope_versions(scope_key,version)
    SELECT 'uid:' || NEW.pack_creator_uid,1 WHERE NEW.pack_creator_uid IS NOT NULL
    ON CONFLICT(scope_key) DO UPDATE SET version = version + 1;
END;
CREATE TABLE IF NOT EXISTS studio_read_meta (
  id INTEGER PRIMARY KEY CHECK(id = 1),
  bootstrap_sequence INTEGER NOT NULL,
  cursor_key TEXT NOT NULL CHECK(length(cursor_key) = 64)
);
INSERT OR IGNORE INTO studio_read_meta VALUES (1,0,lower(hex(randomblob(32))));
