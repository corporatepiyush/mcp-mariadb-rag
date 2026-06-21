# MCP MariaDB RAG

[MariaDB](https://mariadb.com/) + [TidesDB](https://github.com/tidesdb/tidesdb) MCP server with Knowledge Graph, Vector Store, and RAG capabilities.

Built with Zig (0.16) and the MariaDB C client library (`libmariadb`).

## Overview

This server implements the [Model Context Protocol (MCP)](https://modelcontextprotocol.io) to give LLM agents a rich set of database tools — schema inspection, query execution, full-text search, vector similarity search — with **TidesDB** as the default storage engine for high-throughput LSM-tree performance.

### Features

- **SQL Operations**: SELECT, INSERT, UPDATE, DELETE with safety constraints (WHERE required for UPDATE/DELETE)
- **Schema Management**: list tables, describe columns, manage indexes, views, schemas, constraints, triggers
- **Database Administration**: user management, grants, process list, locks, status/variables, table maintenance (optimize, analyze, check, flush, truncate)
- **Full-Text Search**: FULLTEXT index-aware search in natural, boolean, and query-expansion modes
- **Vector Search**: vector similarity search via MariaDB vector types (e.g. `VECTOR(384)`)
- **Knowledge Graph**: schema-aware introspection for building entity-relationship graphs
- **Access Control**: unrestricted or restricted mode; write operations can be gated
- **Transports**: stdio (newline-delimited JSON-RPC) and HTTP (JSON-RPC with Bearer auth)
- **Connection Pooling**: bounded, thread-safe pool with min/max size, TLS support, and automatic dead-connection eviction
- **Metrics**: optional Prometheus-format `/metrics` endpoint

### Default Engine: TidesDB

[TidesDB](https://github.com/tidesdb/tidesdb) is a high-performance LSM-tree storage engine for MariaDB, optimized for write-heavy and time-series workloads. The MCP server defaults to `TidesDB` for `CREATE TABLE` statements (override via `MCP_DEFAULT_ENGINE`).

## Requirements

- [Zig](https://ziglang.org/) 0.16.x
- [MariaDB](https://mariadb.org/) 11.4+ (LTS) with C client library (`libmariadb`)
- [TidesDB / TideSQL](https://github.com/tidesdb/tidesql) plugin installed in MariaDB

### macOS (Homebrew)

```sh
brew install zig mariadb
# Install TideSQL plugin (see https://github.com/tidesdb/tidesql)
```

The build assumes MariaDB is at `/opt/homebrew/opt/mariadb`. Adjust `mariadb_include` and `mariadb_lib` in `build.zig` for other platforms.

## Build

```sh
zig build
```

The binary is written to `zig-out/bin/mcp-mariadb-rag`.

### Tests

```sh
DATABASE_URL="mysql://user:pass@host:3306/db" zig build test
```

Requires a running MariaDB instance. Tests that depend on the database gate themselves on `$DATABASE_URL`.

## Configuration

The server is configured entirely through environment variables.

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `mysql://root:@localhost:3306/mcp` | MariaDB connection string |
| `MCP_DEFAULT_ENGINE` | `TidesDB` | Default storage engine for CREATE TABLE |
| `MCP_HOST` | `127.0.0.1` | HTTP listen address |
| `MCP_HTTP_PORT` | `3001` | HTTP JSON-RPC port |
| `MCP_PORT` | `3000` | Reserved |
| `MCP_STDIO` | `false` | Run in stdio mode (for Claude Desktop, etc.) |
| `MCP_AUTH_TOKEN` | — | Bearer token for HTTP auth |
| `MCP_ACCESS_MODE` | `unrestricted` | `restricted` blocks write tools |
| `MCP_LOG_LEVEL` | `info` | Log level |
| `MCP_ENABLE_METRICS` | `false` | Enable Prometheus metrics endpoint |
| `MCP_METRICS_PORT` | `9090` | Metrics endpoint port |
| `MCP_MIN_CONNECTIONS` | `min(5, num_cpus)` | Minimum pool connections |
| `MCP_MAX_CONNECTIONS` | `num_cpus * 8` | Maximum pool connections |
| `MCP_DB_SSL` | `false` | Enforce TLS for database connection |
| `MCP_DB_SSL_VERIFY` | `false` | Verify server certificate |
| `MCP_DB_SSL_CA` | — | Path to CA certificate file |

## Usage

### Claude Desktop (stdio)

```json
{
  "mcpServers": {
    "mariadb-rag": {
      "command": "/path/to/zig-out/bin/mcp-mariadb-rag",
      "env": {
        "DATABASE_URL": "mysql://user:pass@localhost:3306/mydb",
        "MCP_STDIO": "true",
        "MCP_AUTH_TOKEN": "your-token"
      }
    }
  }
}
```

### HTTP mode

```sh
DATABASE_URL="mysql://root:@localhost:3306/mcp" MCP_AUTH_TOKEN="secret" zig-out/bin/mcp-mariadb-rag
```

Then send JSON-RPC requests:

```sh
curl -s http://localhost:3001 \
  -H "Authorization: Bearer secret" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

## Tools

The server exposes ~50 MCP tools covering:

- **Querying**: `execute_query`, `execute_insert`, `execute_update`, `execute_delete`, `explain_query`
- **Schema**: `list_tables`, `describe_table`, `list_indexes`, `list_schemas`, `show_constraints`, `list_triggers`
- **DDL**: `create_table`, `drop_table`, `create_view`, `drop_view`, `create_schema`, `drop_schema`, `create_index`, `drop_index`, `add_column`, `drop_column`, `rename_column`, `alter_column_type`, `rename_table`
- **Administration**: `show_table_status`, `show_processlist`, `show_variables`, `show_status`, `show_databases`, `show_engines`, `list_users`, `show_grants`, `optimize_table`, `analyze_table`, `check_table`, `flush_tables`, `truncate_table`, `show_locks`, `show_transaction_isolation`
- **Search**: `fulltext_search`, `list_fulltext_indexes`, `vector_search`
- **Access**: `create_user`, `drop_user`, `grant_privileges`, `revoke_privileges`

## Project Structure

```
├── build.zig                 # Build configuration (MariaDB C bindings, tests)
├── src/
│   ├── main.zig              # Entry point: pool init, transport dispatch
│   ├── server.zig            # MCP JSON-RPC protocol layer
│   ├── transport.zig         # stdio & HTTP transports (concurrent)
│   ├── config.zig            # Environment-based configuration
│   ├── pool.zig              # MariaDB connection pool & wrapper
│   ├── json.zig              # JSON serialization (query results, types)
│   ├── types.zig             # Row / QueryResult / ColumnKind types
│   ├── url.zig               # MariaDB DSN parser
│   ├── validation.zig        # SQL safety validation
│   ├── c.h                   # @cImport translation unit
│   ├── tools.json            # Tool definitions for MCP discovery
│   └── actions/
│       ├── mod.zig           # Tool registry & shared helpers
│       ├── query.zig         # SELECT / INSERT / UPDATE / DELETE / EXPLAIN
│       ├── schema.zig        # Schema introspection & DDL tools
│       └── stubs.zig         # Placeholder stubs for unimplemented tools
```

## License

MIT
