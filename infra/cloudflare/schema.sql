CREATE TABLE IF NOT EXISTS samples (
  id TEXT PRIMARY KEY,
  receipt_hash TEXT NOT NULL UNIQUE,
  sanitized_text TEXT NOT NULL,
  label TEXT NOT NULL,
  group_id TEXT NOT NULL,
  group_title TEXT NOT NULL,
  system_action TEXT NOT NULL,
  source TEXT NOT NULL,
  model_version TEXT,
  schema_version INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_samples_label ON samples(label);
CREATE INDEX IF NOT EXISTS idx_samples_group ON samples(group_id);
CREATE INDEX IF NOT EXISTS idx_samples_created_at ON samples(created_at);
CREATE INDEX IF NOT EXISTS idx_samples_deleted_at ON samples(deleted_at);
