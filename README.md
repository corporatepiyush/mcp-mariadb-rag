# MCP KV

SQLite + HNSW/IVF-FLAT MCP server with Knowledge Graph, Vector Store, and RAG capabilities.

Built with Zig (0.16) and the SQLite C library.

## Features

- **Knowledge Graph**: entity/relation/observation CRUD, BFS pathfinding, full-text search via FTS5
- **Vector Search**: HNSW (Hierarchical Navigable Small World) and IVF-FLAT indexes implemented natively in Zig
- **RAG Pipeline**: document ingestion, chunking, hybrid retrieval (BM25 + vector), MMR diversity re-ranking
- **Transport**: stdio (MCP default) and HTTP/1.1 (RFC 9112) with keep-alive

## Prerequisites

- [Zig](https://ziglang.org/) 0.16
- SQLite 3.53.2 (bundled via amalgamation)

```bash
brew install zig
```

## Build

```bash
zig build
```

The binary is written to `zig-out/bin/mcp-kv`.

## Run

```bash
# stdio mode (default for MCP)
MCP_AUTH_TOKEN="secret" zig-out/bin/mcp-kv

# HTTP mode
MCP_AUTH_TOKEN="secret" zig-out/bin/mcp-kv --http
```

## Test

```bash
DATABASE_URL="sqlite:///tmp/mcp_test.db" zig build test
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `sqlite:///tmp/mcp.db` | SQLite database path |
| `MCP_AUTH_TOKEN` | — | Auth token for MCP requests |
| `MCP_HTTP_PORT` | `3001` | HTTP server port |
| `MCP_LOG_LEVEL` | `info` | Log level |
| `MCP_MIN_CONNECTIONS` | `5` | Min pool size |
| `MCP_MAX_CONNECTIONS` | `8*CPU` | Max pool size |
| `MCP_STDIO` | `false` | Force stdio transport |

## MCP Client Configuration

```json
{
  "mcpServers": {
    "mcp-kv": {
      "command": "/path/to/zig-out/bin/mcp-kv",
      "env": {
        "DATABASE_URL": "sqlite:///tmp/mcp.db",
        "MCP_AUTH_TOKEN": "secret"
      }
    }
  }
}
```

## Project Status

Active migration from MariaDB + TidesDB to SQLite + native vector indexes.

**Remaining work:**
- Phase 1a: SQLite C bindings — `src/sqlite.zig`
- Phase 1b: SQLite connection pool — `src/pool.zig` rewrite
- Phase 1c: Schema DDL translation to SQLite dialect
- Phase 1d: Native HNSW/IVF-FLAT vector index
- Phase 1e: FTS5 + hybrid retrieval
- Phase 2a–2d: HNSW, IVF-FLAT, SIMD distances
- Phase 3a–3b: MMR re-ranking + streaming chunking
- Phase 4: RFC 9112 HTTP/1.1 transport
- Phase 5: Ancillary files (URL parser, validation, config)
- Phase 6: Benchmarks
