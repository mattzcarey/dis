-- dis-engine metadata database schema (meta.db)
--
-- One row per session. The real durable state (state_blob, KV cache,
-- per-session SQLite) lives in separate files under
-- <data_dir>/sessions/<id_hex>/. This table is the index + lifecycle
-- state machine.

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS sessions (
    id             BLOB PRIMARY KEY,       -- 16-byte Id128
    namespace      TEXT NOT NULL,
    actor_name     TEXT NOT NULL,          -- e.g. "agent"
    model_id       TEXT NOT NULL,
    key_packed     TEXT NOT NULL,          -- see util/key.zig
    phase          TEXT NOT NULL
                   CHECK (phase IN ('provisioning','loading','running',
                                    'idle','hibernating','hibernated',
                                    'destroying','destroyed')),
    created_ms     INTEGER NOT NULL,
    last_used_ms   INTEGER NOT NULL,
    seq_capacity   INTEGER NOT NULL,
    kv_cursor      INTEGER NOT NULL DEFAULT 0,
    state_version  INTEGER NOT NULL DEFAULT 0,
    kv_version     INTEGER NOT NULL DEFAULT 0,
    UNIQUE (namespace, actor_name, key_packed)
);

CREATE INDEX IF NOT EXISTS idx_sessions_last_used
    ON sessions(last_used_ms);

CREATE INDEX IF NOT EXISTS idx_sessions_phase_time
    ON sessions(phase, last_used_ms);

-- Schema migrations.
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL PRIMARY KEY,
    applied_ms INTEGER NOT NULL
);

INSERT OR IGNORE INTO schema_version(version, applied_ms)
VALUES (1, strftime('%s', 'now') * 1000);
