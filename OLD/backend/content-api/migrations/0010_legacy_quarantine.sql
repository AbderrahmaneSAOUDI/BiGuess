-- Legacy import is a private local operator operation, never an authenticated
-- contributor mutation. Provenance/fences survive rollback and content purge.
CREATE TABLE studio_legacy_imports (
  import_id TEXT PRIMARY KEY,
  manifest_json TEXT NOT NULL CHECK(json_valid(manifest_json)),
  imported_at TEXT NOT NULL,
  record_count INTEGER NOT NULL,
  source_count INTEGER NOT NULL,
  object_count INTEGER NOT NULL
);
CREATE TABLE studio_legacy_records (
  resource_type TEXT NOT NULL CHECK(resource_type IN ('topic','pack','card')),
  resource_id TEXT NOT NULL,
  import_id TEXT NOT NULL REFERENCES studio_legacy_imports(import_id),
  record_json TEXT NOT NULL CHECK(json_valid(record_json)),
  PRIMARY KEY(resource_type,resource_id)
);
CREATE INDEX studio_legacy_import_records ON studio_legacy_records(import_id);
CREATE TABLE studio_legacy_rollbacks (
  import_id TEXT PRIMARY KEY REFERENCES studio_legacy_imports(import_id),
  rolled_back_at TEXT NOT NULL,
  report_json TEXT NOT NULL CHECK(json_valid(report_json))
);
CREATE TRIGGER studio_legacy_import_no_update BEFORE UPDATE ON studio_legacy_imports
BEGIN SELECT RAISE(ABORT,'immutable_legacy_import'); END;
CREATE TRIGGER studio_legacy_import_no_delete BEFORE DELETE ON studio_legacy_imports
BEGIN SELECT RAISE(ABORT,'immutable_legacy_import'); END;
CREATE TRIGGER studio_legacy_record_no_update BEFORE UPDATE ON studio_legacy_records
BEGIN SELECT RAISE(ABORT,'immutable_legacy_import'); END;
CREATE TRIGGER studio_legacy_record_no_delete BEFORE DELETE ON studio_legacy_records
BEGIN SELECT RAISE(ABORT,'immutable_legacy_import'); END;
CREATE TRIGGER studio_legacy_rollback_no_update BEFORE UPDATE ON studio_legacy_rollbacks
BEGIN SELECT RAISE(ABORT,'immutable_legacy_import'); END;
CREATE TRIGGER studio_legacy_rollback_no_delete BEFORE DELETE ON studio_legacy_rollbacks
BEGIN SELECT RAISE(ABORT,'immutable_legacy_import'); END;
-- Quarantined Topic changes are Owner-only; they do not invalidate a Collector's
-- taxonomy cursor or disclose otherwise invisible administrative activity.
DROP TRIGGER studio_changes_view_version;
CREATE TRIGGER studio_changes_view_version AFTER INSERT ON studio_read_changes
BEGIN
  UPDATE studio_scope_versions SET version = version + 1 WHERE scope_key = 'owner';
  UPDATE studio_scope_versions SET version = version + 1 WHERE scope_key = 'taxonomy'
    AND NEW.resource_type = 'topic' AND NOT EXISTS (
      SELECT 1 FROM studio_legacy_records q WHERE q.resource_type='topic' AND q.resource_id=NEW.resource_id);
  INSERT INTO studio_scope_versions(scope_key,version)
    SELECT 'uid:' || NEW.pack_creator_uid,1 WHERE NEW.pack_creator_uid IS NOT NULL
    ON CONFLICT(scope_key) DO UPDATE SET version = version + 1;
END;
-- Visibility and approval guards also execute at the final transaction, closing
-- races with a trusted publication that began before a local import committed.
CREATE TRIGGER legacy_catalog_topic_insert BEFORE INSERT ON catalog_topics
WHEN NEW.published=1 AND EXISTS (SELECT 1 FROM studio_legacy_records WHERE resource_type='topic' AND resource_id=NEW.id)
BEGIN SELECT RAISE(ABORT,'legacy_quarantine'); END;
CREATE TRIGGER legacy_catalog_topic_update BEFORE UPDATE ON catalog_topics
WHEN NEW.published=1 AND EXISTS (SELECT 1 FROM studio_legacy_records WHERE resource_type='topic' AND resource_id=NEW.id)
BEGIN SELECT RAISE(ABORT,'legacy_quarantine'); END;
CREATE TRIGGER legacy_catalog_pack_insert BEFORE INSERT ON catalog_packs
WHEN NEW.published=1 AND EXISTS (SELECT 1 FROM studio_legacy_records WHERE
  (resource_type='pack' AND resource_id=NEW.id) OR (resource_type='topic' AND resource_id=NEW.topic_id))
BEGIN SELECT RAISE(ABORT,'legacy_quarantine'); END;
CREATE TRIGGER legacy_catalog_pack_update BEFORE UPDATE ON catalog_packs
WHEN NEW.published=1 AND EXISTS (SELECT 1 FROM studio_legacy_records WHERE
  (resource_type='pack' AND resource_id=NEW.id) OR (resource_type='topic' AND resource_id=NEW.topic_id))
BEGIN SELECT RAISE(ABORT,'legacy_quarantine'); END;
CREATE TRIGGER legacy_publication_revision BEFORE INSERT ON publication_revisions
WHEN EXISTS (SELECT 1 FROM studio_legacy_records WHERE
  (resource_type='pack' AND resource_id=NEW.pack_id) OR (resource_type='topic' AND resource_id=NEW.topic_id))
BEGIN SELECT RAISE(ABORT,'legacy_quarantine'); END;
CREATE TRIGGER legacy_rights_approval BEFORE INSERT ON studio_rights_approvals
WHEN EXISTS (SELECT 1 FROM studio_legacy_records WHERE
  (resource_type='pack' AND resource_id=NEW.pack_id) OR (resource_type='topic' AND resource_id=(SELECT parent_id FROM studio_entities WHERE resource_type='pack' AND id=NEW.pack_id)))
BEGIN SELECT RAISE(ABORT,'legacy_quarantine'); END;
CREATE TRIGGER legacy_publication_approval BEFORE INSERT ON studio_publication_approvals
WHEN EXISTS (SELECT 1 FROM studio_legacy_records WHERE resource_type=NEW.resource_type AND resource_id=NEW.resource_id)
BEGIN SELECT RAISE(ABORT,'legacy_quarantine'); END;
