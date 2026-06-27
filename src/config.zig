const std = @import("std");
const c = std.c;

pub const AccessMode = enum {
    unrestricted,
    restricted,
};

// ── Scaling tiers ──────────────────────────────────────────────────────
// One binary spans phone → datacenter; the tier only sets *defaults*, and every
// individual knob stays overridable by an explicit env var (PLAN.md Part II).

pub const Tier = enum {
    mobile,
    edge,
    server,
    dc,

    /// Auto-detect from detected RAM. Cores refine the boundary so a many-core
    /// box with modest RAM still lands at least at `edge`.
    pub fn detect(ram_bytes: u64, cores: usize) Tier {
        const gb = ram_bytes / (1 << 30);
        var t: Tier = if (gb >= 128) .dc else if (gb >= 8) .server else if (gb >= 1) .edge else .mobile;
        if (t == .mobile and cores >= 4) t = .edge;
        return t;
    }

    pub fn parse(s: ?[]const u8) ?Tier {
        const str = s orelse return null;
        if (std.ascii.eqlIgnoreCase(str, "mobile")) return .mobile;
        if (std.ascii.eqlIgnoreCase(str, "edge")) return .edge;
        if (std.ascii.eqlIgnoreCase(str, "server")) return .server;
        if (std.ascii.eqlIgnoreCase(str, "dc")) return .dc;
        return null;
    }

    pub fn name(self: Tier) []const u8 {
        return @tagName(self);
    }
};

/// Vector index backend. `flat` is the always-correct O(N) streaming scan;
/// `hnsw` builds an in-memory ANN cache for O(log N) queries (PLAN.md §3).
pub const IndexType = enum {
    flat,
    hnsw,

    pub fn parse(s: ?[]const u8) ?IndexType {
        const str = s orelse return null;
        if (std.ascii.eqlIgnoreCase(str, "flat")) return .flat;
        if (std.ascii.eqlIgnoreCase(str, "hnsw")) return .hnsw;
        return null;
    }

    pub fn name(self: IndexType) []const u8 {
        return @tagName(self);
    }

    /// Tiers that can afford the resident graph default to HNSW.
    pub fn forTier(t: Tier) IndexType {
        return switch (t) {
            .mobile, .edge => .flat,
            .server, .dc => .hnsw,
        };
    }
};

/// Database component — each gets its own file, pool, and PRAGMA profile.
pub const DbKind = enum { kg, rag };

/// Derive a per-component database URL from the base. A file URL gains a
/// `.<component>` segment before its extension (`…/mcp.db` → `…/mcp.rag.db`); an
/// in-memory URL (`sqlite://` with no path) is returned unchanged, so both
/// components share one in-memory database (the no-blocking win only applies to
/// real files anyway).
pub fn componentUrl(allocator: std.mem.Allocator, base: []const u8, comp: []const u8) ![]u8 {
    const prefix = "sqlite://";
    if (!std.mem.startsWith(u8, base, prefix)) return allocator.dupe(u8, base);
    const path = base[prefix.len..];
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return allocator.dupe(u8, base); // in-memory
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        if (slash == null or dot > slash.?)
            return std.fmt.allocPrint(allocator, "{s}{s}.{s}{s}", .{ prefix, path[0..dot], comp, path[dot..] });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}.{s}", .{ prefix, path, comp });
}

/// Detected host facts that seed every default. Cheap to gather; logged once.
pub const HostInfo = struct {
    ram_bytes: u64,
    cores: usize,

    pub fn detect() HostInfo {
        const ram = std.process.totalSystemMemory() catch (1 << 30); // 1 GiB fallback
        const cores = std.Thread.getCpuCount() catch 1;
        return .{ .ram_bytes = ram, .cores = @max(1, cores) };
    }
};

// ── SQLite storage-engine tuning ───────────────────────────────────────
// Per-connection PRAGMAs scaled by tier. Applied in `pool.DatabaseConn.initTuned`.

pub const Synchronous = enum {
    off,
    normal,
    full,
    pub fn sql(self: Synchronous) []const u8 {
        return switch (self) {
            .off => "OFF",
            .normal => "NORMAL",
            .full => "FULL",
        };
    }
};

pub const TempStore = enum {
    default,
    file,
    memory,
    pub fn sql(self: TempStore) []const u8 {
        return switch (self) {
            .default => "DEFAULT",
            .file => "FILE",
            .memory => "MEMORY",
        };
    }
};

pub const SqliteTuning = struct {
    /// Page cache, in KiB. Applied as `PRAGMA cache_size = -<cache_kib>`.
    cache_kib: u32,
    /// Memory-mapped I/O window in bytes (0 disables mmap I/O).
    mmap_bytes: u64,
    /// DB page size; only takes effect on a fresh file (ignored otherwise).
    page_size: u32,
    wal_autocheckpoint: u32,
    synchronous: Synchronous,
    temp_store: TempStore,
    busy_ms: u32,

    /// Conservative defaults that mirror the historical fixed PRAGMAs (WAL,
    /// 5 s busy timeout, ~2 MB cache). Used when no tier is resolved — e.g. by
    /// `DatabaseConn.init` in unit tests.
    pub const safe_default: SqliteTuning = .{
        .cache_kib = 2048,
        .mmap_bytes = 0,
        .page_size = 4096,
        .wal_autocheckpoint = 1000,
        .synchronous = .full,
        .temp_store = .default,
        .busy_ms = 5000,
    };

    pub fn forTier(tier: Tier) SqliteTuning {
        return switch (tier) {
            .mobile => .{
                .cache_kib = 2 * 1024,
                .mmap_bytes = 0,
                .page_size = 4096,
                .wal_autocheckpoint = 1000,
                .synchronous = .full,
                .temp_store = .file,
                .busy_ms = 5000,
            },
            .edge => .{
                .cache_kib = 64 * 1024,
                .mmap_bytes = 256 * 1024 * 1024,
                .page_size = 8192,
                .wal_autocheckpoint = 5000,
                .synchronous = .normal,
                .temp_store = .memory,
                .busy_ms = 5000,
            },
            .server => .{
                .cache_kib = 2048 * 1024,
                .mmap_bytes = 1024 * 1024 * 1024,
                .page_size = 8192,
                .wal_autocheckpoint = 10000,
                .synchronous = .normal,
                .temp_store = .memory,
                .busy_ms = 5000,
            },
            .dc => .{
                .cache_kib = 16384 * 1024,
                .mmap_bytes = 65536 * 1024 * 1024,
                .page_size = 16384,
                .wal_autocheckpoint = 20000,
                .synchronous = .normal,
                .temp_store = .memory,
                .busy_ms = 5000,
            },
        };
    }
};

pub const ServerConfig = struct {
    host: []const u8,
    port: u16,
    request_timeout_secs: u64,
    access_mode: AccessMode,
    auth_token: ?[]const u8,
    allow_url_import: bool,
    stdio: bool,
    log_level: []const u8,
    enable_metrics: bool,
    metrics_port: u16,
};

pub const PoolConfig = struct {
    min_size: u32,
    max_size: u32,
    queue_timeout_secs: u64,
    create_timeout_secs: u64,
};

/// TLS settings for the connection to the database.
pub const TlsConfig = struct {
    /// Require an encrypted connection; the handshake fails if TLS is unavailable.
    enforce: bool,
    /// Verify the server certificate against the system / CA bundle.
    verify: bool,
    /// Optional path to a CA certificate file.
    ca_path: ?[]const u8,
};

pub const Config = struct {
    database_url: []const u8,
    server: ServerConfig,
    pool: PoolConfig,
    tls: TlsConfig,
    // ── Scaling resolution ── (defaulted so manual literals stay valid; `load`
    // always sets them from the detected host).
    host: HostInfo = .{ .ram_bytes = 1 << 30, .cores = 1 },
    tier: Tier = .mobile,
    mem_budget_mb: u64 = 0,
    /// Active embedding dimensionality (MCP_EMBED_DIMS, default 384). Lets one
    /// binary serve a corpus built with a higher-dimensional embedder.
    embed_dims: u32 = 384,
    // ── Vector index ──
    index_type: IndexType = .flat,
    /// true = cosine, false = euclidean/L2. The HNSW cache is built for one
    /// metric; requests using the other metric fall back to the flat scan.
    index_cosine: bool = true,
    hnsw_m: u32 = 16,
    hnsw_ef_construction: u32 = 200,
    hnsw_ef_search: u32 = 64,
    // ── Semantic query cache ──
    qcache_entries: u32 = 0,
    qcache_threshold: f32 = 0.97,
    sqlite: SqliteTuning = SqliteTuning.safe_default,
    /// Print the resolved-config table and exit without serving (capacity
    /// preflight). Also settable via the `--print-config` CLI flag.
    dry_run: bool = false,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.database_url);
        allocator.free(self.server.host);
        allocator.free(self.server.log_level);
        if (self.server.auth_token) |t| allocator.free(t);
        if (self.tls.ca_path) |p| allocator.free(p);
    }

    /// Per-component SQLite tuning. The RAG database stores large embedding
    /// BLOBs and is scan-heavy, so it uses a larger page size (more vector bytes
    /// packed inline, fewer overflow pages — `page_size` only applies when the
    /// file is first created, which is exactly when these component files are).
    /// The KG database is small-row, point-lookup work and keeps the tier page
    /// size.
    pub fn sqliteFor(self: *const Config, kind: DbKind) SqliteTuning {
        var t = self.sqlite;
        switch (kind) {
            .rag => t.page_size = @max(t.page_size, 16384),
            .kg => {},
        }
        return t;
    }

    /// Emit the fully-resolved knob table so an operator can see exactly what the
    /// tier picked. One `info` line per group (PLAN.md §8).
    pub fn logResolved(self: *const Config) void {
        const log = std.log.scoped(.config);
        log.info("tier={s} (detected from RAM={d}MB cores={d}); mem_budget={d}MB", .{
            self.tier.name(),
            self.host.ram_bytes / (1024 * 1024),
            self.host.cores,
            self.mem_budget_mb,
        });
        log.info("pool: min={d} max={d}; embed_dims={d}", .{ self.pool.min_size, self.pool.max_size, self.embed_dims });
        log.info("index: type={s} metric={s} hnsw_m={d} ef_construction={d} ef_search={d}", .{
            self.index_type.name(),
            if (self.index_cosine) "cosine" else "euclidean",
            self.hnsw_m,
            self.hnsw_ef_construction,
            self.hnsw_ef_search,
        });
        log.info("qcache: entries={d} threshold={d:.3}", .{ self.qcache_entries, self.qcache_threshold });
        log.info("sqlite: cache={d}MB mmap={d}MB page_size={d} synchronous={s} temp_store={s} wal_ckpt={d} busy_ms={d}", .{
            self.sqlite.cache_kib / 1024,
            self.sqlite.mmap_bytes / (1024 * 1024),
            self.sqlite.page_size,
            self.sqlite.synchronous.sql(),
            self.sqlite.temp_store.sql(),
            self.sqlite.wal_autocheckpoint,
            self.sqlite.busy_ms,
        });
    }
};

fn getEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const len = std.mem.len(ptr);
        return allocator.dupe(u8, ptr[0..len]) catch null;
    }
    return null;
}

fn envBool(name: []const u8) bool {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes");
    }
    return false;
}

fn envU16(name: []const u8, default: u16) u16 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.fmt.parseInt(u16, val, 10) catch default;
    }
    return default;
}

fn envU32(name: []const u8, default: u32) u32 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.fmt.parseInt(u32, val, 10) catch default;
    }
    return default;
}

fn envU64(name: []const u8, default: u64) u64 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.fmt.parseInt(u64, val, 10) catch default;
    }
    return default;
}

fn envF32(name: []const u8, default: f32) f32 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.fmt.parseFloat(f32, val) catch default;
    }
    return default;
}

/// Tier-scaled default for the semantic query cache size, in entries.
fn tierQCacheEntries(t: Tier) u32 {
    return switch (t) {
        .mobile => 0,
        .edge => 128,
        .server => 512,
        .dc => 4096,
    };
}

/// Borrow an env var as a slice (no allocation; valid for the process lifetime).
/// Suitable for parse-and-discard reads like tier/enum knobs.
fn envBorrow(name: []const u8) ?[]const u8 {
    const v = c.getenv(@ptrCast(name.ptr));
    return if (v) |ptr| std.mem.sliceTo(ptr, 0) else null;
}

fn envSync(name: []const u8, default: Synchronous) Synchronous {
    const s = envBorrow(name) orelse return default;
    if (std.ascii.eqlIgnoreCase(s, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(s, "normal")) return .normal;
    if (std.ascii.eqlIgnoreCase(s, "full")) return .full;
    return default;
}

fn envTemp(name: []const u8, default: TempStore) TempStore {
    const s = envBorrow(name) orelse return default;
    if (std.ascii.eqlIgnoreCase(s, "file")) return .file;
    if (std.ascii.eqlIgnoreCase(s, "memory")) return .memory;
    if (std.ascii.eqlIgnoreCase(s, "default")) return .default;
    return default;
}

/// Resolve per-tier SQLite defaults, then layer explicit env overrides on top
/// (precedence: tier preset → env var, PLAN.md §8).
fn resolveSqlite(tier: Tier) SqliteTuning {
    var t = SqliteTuning.forTier(tier);
    t.cache_kib = @intCast(envU64("MCP_SQLITE_CACHE_MB", t.cache_kib / 1024) * 1024);
    t.mmap_bytes = envU64("MCP_SQLITE_MMAP_MB", t.mmap_bytes / (1024 * 1024)) * 1024 * 1024;
    t.page_size = envU32("MCP_SQLITE_PAGE_SIZE", t.page_size);
    t.wal_autocheckpoint = envU32("MCP_SQLITE_WAL_CKPT", t.wal_autocheckpoint);
    t.synchronous = envSync("MCP_SQLITE_SYNC", t.synchronous);
    t.temp_store = envTemp("MCP_SQLITE_TEMP", t.temp_store);
    t.busy_ms = envU32("MCP_SQLITE_BUSY_MS", t.busy_ms);
    return t;
}

/// Tier-scaled default for the pool's max connection count (PLAN.md §5).
pub fn tierPoolMax(tier: Tier, cores: usize) u32 {
    return switch (tier) {
        .mobile => 2,
        .edge => @intCast(@max(2, cores * 2)),
        .server => @intCast(cores * 8),
        .dc => @intCast(cores * 16),
    };
}

pub fn load(allocator: std.mem.Allocator) !Config {
    const database_url = getEnv(allocator, "DATABASE_URL") orelse try allocator.dupe(u8, "sqlite:///tmp/mcp.db");
    const host = getEnv(allocator, "MCP_HOST") orelse try allocator.dupe(u8, "127.0.0.1");
    const port = envU16("MCP_PORT", 3000);
    const log_level = getEnv(allocator, "MCP_LOG_LEVEL") orelse try allocator.dupe(u8, "info");
    const enable_metrics = envBool("MCP_ENABLE_METRICS");
    const metrics_port = envU16("MCP_METRICS_PORT", 9090);
    const stdio_mode = envBool("MCP_STDIO");
    const access_mode_str = getEnv(allocator, "MCP_ACCESS_MODE");
    const access_mode: AccessMode = if (access_mode_str) |s| blk: {
        defer allocator.free(s);
        break :blk if (std.mem.eql(u8, s, "restricted")) .restricted else .unrestricted;
    } else .unrestricted;
    const auth_token = getEnv(allocator, "MCP_AUTH_TOKEN");
    const allow_url_import = envBool("MCP_ALLOW_URL_IMPORT");

    // Detect the host and resolve the tier (env override wins over detection).
    const host_info = HostInfo.detect();
    const tier = Tier.parse(envBorrow("MCP_TIER")) orelse Tier.detect(host_info.ram_bytes, host_info.cores);
    const num_cpus = host_info.cores;

    // The master memory screw: 70 % of detected RAM unless overridden.
    const default_budget_mb = (host_info.ram_bytes / (1024 * 1024)) * 7 / 10;
    const mem_budget_mb = envU64("MCP_MEM_BUDGET_MB", default_budget_mb);

    const max_size = envU32("MCP_MAX_CONNECTIONS", tierPoolMax(tier, num_cpus));
    // Warm-connection floor, never above the (possibly small, e.g. mobile=2) cap.
    const min_size = @min(envU32("MCP_MIN_CONNECTIONS", @intCast(@min(5, num_cpus))), max_size);
    const queue_timeout = envU32("MCP_QUEUE_TIMEOUT", 10);
    const create_timeout = envU32("MCP_CREATE_TIMEOUT", 5);
    const dry_run = envBool("MCP_DRY_RUN");
    const embed_dims = envU32("MCP_EMBED_DIMS", 384);
    const index_type = IndexType.parse(envBorrow("MCP_INDEX_TYPE")) orelse IndexType.forTier(tier);
    const index_cosine = !std.ascii.eqlIgnoreCase(envBorrow("MCP_INDEX_METRIC") orelse "cosine", "euclidean");

    return .{
        .host = host_info,
        .tier = tier,
        .mem_budget_mb = mem_budget_mb,
        .embed_dims = embed_dims,
        .index_type = index_type,
        .index_cosine = index_cosine,
        .hnsw_m = envU32("MCP_HNSW_M", 16),
        .hnsw_ef_construction = envU32("MCP_HNSW_EF_CONSTRUCTION", 200),
        .hnsw_ef_search = envU32("MCP_HNSW_EF_SEARCH", 64),
        .qcache_entries = envU32("MCP_QCACHE_ENTRIES", tierQCacheEntries(tier)),
        .qcache_threshold = envF32("MCP_QCACHE_THRESHOLD", 0.97),
        .sqlite = resolveSqlite(tier),
        .dry_run = dry_run,
        .database_url = database_url,
        .tls = .{
            .enforce = envBool("MCP_DB_SSL"),
            .verify = envBool("MCP_DB_SSL_VERIFY"),
            .ca_path = getEnv(allocator, "MCP_DB_SSL_CA"),
        },
        .server = .{
            .host = host,
            .port = port,
            .request_timeout_secs = 30,
            .access_mode = access_mode,
            .auth_token = auth_token,
            .allow_url_import = allow_url_import,
            .stdio = stdio_mode,
            .log_level = log_level,
            .enable_metrics = enable_metrics,
            .metrics_port = metrics_port,
        },
        .pool = .{
            .min_size = min_size,
            .max_size = max_size,
            .queue_timeout_secs = queue_timeout,
            .create_timeout_secs = create_timeout,
        },
    };
}
