-- RAG document/chunk store. Lives in its own SQLite file (the `rag` component)
-- with a 16 KiB page size so chunk rows pack the embedding BLOB with fewer
-- overflow pages. STRICT enforces column types (a non-BLOB embedding is rejected
-- at insert instead of corrupting the vector scan). CREATE ... IF NOT EXISTS
-- leaves a pre-existing database untouched, so upgrades need no migration.

CREATE TABLE IF NOT EXISTS `rag_document` (
    id TEXT NOT NULL PRIMARY KEY,
    uri TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    metadata TEXT NOT NULL,
    chunk_count INTEGER NOT NULL DEFAULT 0,
    content_hash TEXT NOT NULL DEFAULT '',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
) STRICT;

CREATE TABLE IF NOT EXISTS `rag_chunk` (
    id TEXT NOT NULL PRIMARY KEY,
    document_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL DEFAULT 0,
    content TEXT NOT NULL,
    token_count INTEGER NOT NULL DEFAULT 0,
    embedding BLOB NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
) STRICT;

-- Per-document access path (writeChunksByDocument / delete): turns a full scan
-- into a SEARCH, and the key order satisfies ORDER BY ordinal for free.
CREATE INDEX IF NOT EXISTS `idx_chunk_doc` ON `rag_chunk` (document_id, ordinal);
