-- Knowledge-graph store. Lives in its own SQLite file (the `kg` component) so
-- its writes never contend with RAG ingest. STRICT enforces column types
-- (release 3.37); the indexes cover the graph's hot access paths — neighbour
-- lookups by from/to entity, observations and vectors by entity — which were
-- previously full table scans.

CREATE TABLE IF NOT EXISTS `rag_entity` (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    entity_type TEXT NOT NULL DEFAULT '',
    observations TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
) STRICT;

CREATE TABLE IF NOT EXISTS `rag_observation` (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_name TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
) STRICT;

CREATE TABLE IF NOT EXISTS `rag_relation` (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_entity TEXT NOT NULL,
    relation_type TEXT NOT NULL,
    to_entity TEXT NOT NULL,
    weight REAL DEFAULT 1.0,
    created_at TEXT DEFAULT (datetime('now')),
    UNIQUE(from_entity, relation_type, to_entity)
) STRICT;

CREATE TABLE IF NOT EXISTS `rag_type_dict` (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    UNIQUE(kind, name)
) STRICT;

CREATE TABLE IF NOT EXISTS `rag_graph_stat` (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    stat_name TEXT NOT NULL UNIQUE,
    stat_value INTEGER NOT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
) STRICT;

CREATE TABLE IF NOT EXISTS `rag_vector_embedding` (
    id TEXT NOT NULL PRIMARY KEY,
    entity_name TEXT NOT NULL,
    text_content TEXT NOT NULL,
    embedding BLOB NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
) STRICT;

CREATE INDEX IF NOT EXISTS `idx_observation_entity` ON `rag_observation` (entity_name);
CREATE INDEX IF NOT EXISTS `idx_relation_from` ON `rag_relation` (from_entity);
CREATE INDEX IF NOT EXISTS `idx_relation_to` ON `rag_relation` (to_entity);
CREATE INDEX IF NOT EXISTS `idx_vector_entity` ON `rag_vector_embedding` (entity_name);
