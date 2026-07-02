# MCP RAG

SQLite-backed MCP server with Knowledge Graph, Vector Store, and a production
RAG pipeline. One statically-linked binary that auto-tunes from a phone to a
datacenter — the deployment tier only sets defaults; every knob stays overridable.

Built with Zig (0.16) and the SQLite C library.

## Features

- **RAG pipeline**
  - Chunking: sliding token window, **recursive** (paragraph→line→sentence→word),
    and **parent-child** (small retrieval chunks + larger generation context).
  - Hybrid retrieval: dense vector ⊕ lexical, fused with Reciprocal Rank Fusion,
    optional MMR diversity re-ranking.
  - **Correct recall at any scale**: a streaming top-k flat scan (bounded heap,
    O(k) memory) replaces the old `LIMIT k`; an optional in-memory **HNSW** index
    gives O(log N) queries on larger corpora.
  - **Metadata pre-filtering**: scope retrieval to a document set.
  - **Semantic query cache**: a near-identical prior query short-circuits the funnel.
  - **Idempotent ingest**: content-hash dedup skips no-op re-ingests.
  - **Per-query tracing**: stage latencies + candidate counts, logged and optionally
    returned.
- **Vector quantization**: f32 / f16 / int8 / binary blob codec with int8-cosine and
  binary-hamming SIMD kernels (the RAM axis).
- **Runtime embedding dimensionality**: serve a higher-dimensional embedder without a
  recompile (`MCP_EMBED_DIMS`).
- **Knowledge Graph**: entity/relation/observation CRUD, BFS pathfinding, search.
- **Storage**: STRICT tables, a `(document_id, ordinal)` index, atomic multi-statement
  writes, and tier-scaled SQLite PRAGMAs (cache / mmap / synchronous / temp_store / WAL).
- **Transport**: stdio (MCP default).

> Native IVF-FLAT and the remote embedding / cross-encoder rerank / LLM generation
> stages are on the roadmap but not yet implemented.

## Build

```bash
zig build          # binary at zig-out/bin/mcp-rag
zig build test     # unit + fuzz tests
DATABASE_URL="sqlite:///tmp/mcp_test.db" zig build test   # + gated integration tests
```

## Run

```bash
MCP_AUTH_TOKEN="secret" zig-out/bin/mcp-rag          # stdio (MCP default)
MCP_DRY_RUN=1 zig-out/bin/mcp-rag                    # print the resolved config and exit
```

## Deployment tiers

Auto-detected from RAM + CPU (override with `MCP_TIER={mobile|edge|server|dc}`). The
tier sets defaults for the pool size, SQLite PRAGMAs, vector index, and caches; the
master `MCP_MEM_BUDGET_MB` (default 70% of RAM) scales the memory envelope.

| Tier | Vector index | SQLite cache | Query cache | Pool max |
|---|---|---|---|---|
| `mobile` | flat | 2 MB | off | 2 |
| `edge` | flat | 64 MB | 128 | 2·cores |
| `server` | HNSW | 2 GB | 512 | 8·cores |
| `dc` | HNSW | 16 GB | 4096 | 16·cores |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `sqlite:///tmp/mcp.db` | SQLite database path |
| `MCP_STDIO` | `false` | Transport (stdio) |
| `MCP_TIER` | auto | `mobile`/`edge`/`server`/`dc` (overrides detection) |
| `MCP_MEM_BUDGET_MB` | 70% RAM | Master memory budget |
| `MCP_MIN_CONNECTIONS` / `MCP_MAX_CONNECTIONS` | tier | Pool sizing |
| `MCP_EMBED_DIMS` | `384` | Active embedding dimensionality |
| `MCP_INDEX_TYPE` | tier (`flat`/`hnsw`) | Vector index backend |
| `MCP_INDEX_METRIC` | `cosine` | `cosine` or `euclidean` (index build metric) |
| `MCP_HNSW_M` / `_EF_CONSTRUCTION` / `_EF_SEARCH` | `16` / `200` / `64` | HNSW params |
| `MCP_QCACHE_ENTRIES` / `MCP_QCACHE_THRESHOLD` | tier / `0.97` | Semantic query cache |
| `MCP_MAX_REQUEST_MB` | tier | Cap on a single stdio request line (arena bound) |
| `MCP_MAX_K` / `MCP_MAX_CANDIDATES` / `MCP_MMR_MAX_N` | tier | Retrieval caps: result count, per-arm candidates, MMR cutoff |
| `MCP_WRITE_BATCH_ROWS` | tier | Chunk-upsert transaction window (bound-parameter batch inserts) |
| `MCP_SQLITE_CACHE_MB` / `_MMAP_MB` / `_PAGE_SIZE` | tier | SQLite storage engine |
| `MCP_SQLITE_SYNC` / `_TEMP` / `_WAL_CKPT` / `_BUSY_MS` | tier | SQLite durability/IO |
| `MCP_DRY_RUN` | `false` | Print resolved config and exit |

Run `MCP_DRY_RUN=1 zig-out/bin/mcp-rag` to see the fully-resolved knob table for any
tier/override combination.

## Selected RAG tools

| Tool | Notes |
|---|---|
| `rag_chunk_text` | `strategy`: `window` (default) or `recursive` |
| `rag_parent_child_chunk` | small children + larger parents (`parentOrdinal` back-ref) |
| `rag_ingest_document` | atomic; content-hash deduped (`skipped:true` on no-op) |
| `rag_search` | hybrid + RRF + MMR; `documentId(s)` filter; `trace:true` for timings |
| `rag_vector_search` | pure semantic; HNSW-accelerated when enabled (`index:"hnsw"`) |

Embeddings are caller-supplied (the host computes them with its embedder of choice).

## MCP client configuration

```json
{
  "mcpServers": {
    "mcp-rag": {
      "command": "/path/to/zig-out/bin/mcp-rag",
      "env": { "DATABASE_URL": "sqlite:///tmp/mcp.db" }
    }
  }
}
```
