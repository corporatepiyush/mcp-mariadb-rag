# SQLite Release History (2016–2026)

## 3.53.2 — 2026-06-03 (Patch)
Fixes for problems reported in 3.53.0.

## 3.53.1 — 2026-05-05 (Patch)
Fixes for problems reported in 3.53.0.

## 3.53.0 — 2026-04-09
**Query Result Formatter (QRF):** New library for formatting SQL query results for human readability. Used by CLI for box-drawing Unicode output. TCL `format` method provides access.

**ALTER TABLE:** ADD and DROP of NOT NULL and CHECK constraints now supported.

**REINDEX EXPRESSIONS:** Rebuilds expression indexes — repairs stale expression indexes.

**VACUUM INTO with reserve=N:** URI parameter `reserve=N` sets reserve space on copied database.

**New SQL functions:** `json_array_insert()`, `jsonb_array_insert()`.

**Session extension:** Incremental change API — `change_begin/blob/double/int64/null/text/finish()`, `changegroup_config()`.

**CLI:** Enhanced `.mode`; box-drawing Unicode by default (interactive); bare semicolons at end of dot-commands silently ignored; `.timer once`; `.progress --timeout S`; `.indexes` PATTERN matches index name.

**New C APIs:** `sqlite3_str_truncate()`, `sqlite3_str_free()`, `sqlite3_carray_bind_v2()`, `SQLITE_PREPARE_FROM_DDL`, `SQLITE_UTF8_ZT`, `SQLITE_LIMIT_PARSER_DEPTH`, `SQLITE_DBCONFIG_FP_DIGITS`.

**Query planner:** Sort-and-merge for EXCEPT/INTERSECT/UNION; star schema join improvements; EXISTS-to-JOIN enhancement; omit-noop-join chains; GROUP BY e1 ORDER BY e2 single-index optimization; virtual table DISTINCT optimization.

**Float↔text conversions:** Reimplemented for performance; defaults to 17 significant digits (was 15).

**Self-healing index:** Automatically repairs stale expression indexes.

**Other:** `sqlite3_rsync -p|--port`; Windows RT discontinued; WASM "opfs-wl" VFS using Web Locks.

## 3.51.3 — 2026-03-13 (Patch)
WAL-reset database corruption fix; minor bug fixes.

## 3.52.0 — 2026-03-06 (Withdrawn)
Features moved to 3.53.0.

## 3.51.2 — 2026-01-09 (Patch)
Obscure deadlock fix in broken-posix-lock detection; EXISTS-to-JOIN fixes.

## 3.51.1 — 2025-11-28 (Patch)
Incorrect results from nested EXISTS queries (3.51.0 regression); latent FTS5vocab bug fix.

## 3.51.0 — 2025-11-04
**New macros:** `SQLITE_SCM_BRANCH` (source branch), `SCM_TAGS` (check-in tags), `SCM_DATETIME` (check-in date/time).

**JSON:** `jsonb_each()`, `jsonb_tree()` — return JSONB for "value" column.

**Amalgamation:** `carray` and `percentile` extensions built-in (disabled by default).

**CLI:** Microsecond `.timer`; double-wide char support; `.imposter` read-only imposter tables (no `--unsafe-testing`); `--ifexists`; `.width` max 30000.

**Performance:** Fewer cycles for read tx commit; early empty-join detection; scalar subquery elimination; faster window functions with large FOLLOWING.

**New PRAGMA/APIs:** `PRAGMA wal_checkpoint=NOOP`, `SQLITE_CHECKPOINT_NOOP`, `sqlite3_set_errmsg()`, `sqlite3_db_status64()`, `SQLITE_DBSTATUS_TEMPBUF_SPILL`, `sqlite3changeset_apply_v3()`.

**STRICT typing** enforced on computed columns.

**WASM:** 64-bit support.

## 3.50.4 — 2025-07-30 (Patch)
Two long-standing uninitialized variable fixes.

## 3.50.3 — 2025-07-17 (Patch)
FTS5 memory error fix; CREATE TRIGGER comment parsing fix (3.49.0 regression); AND over-optimization fix.

## 3.50.2 — 2025-06-28 (Patch)
concat_ws() empty string fix; MinGW build fix; WAL checksum fix after savepoint rollback; Bitvec stack overflow fix; FTS5 BLOB UPDATE fix; RIGHT JOIN transitive IS fix.

## 3.50.1 — 2025-06-06 (Patch)
jsonb_set() bug fix; ASAN warning fix; sqlite3_rsync off-by-one fix; LEFT JOIN flatten for virtual tables.

## 3.50.0 — 2025-05-29
**New API:** `sqlite3_setlk_timeout()` — separate timeout for blocking locks.

**SQL functions:** `unistr()`, `unistr_quote()`.

**CLI:** Control character escaping; `.dump` uses `unistr()`; better `.schema --indent` for partial indexes.

**sqlite3_rsync:** WAL mode no longer required; enhanced sync protocol; Mac auto-discovery.

**JSON:** JSON5 `\0` escape enforced; `json_group_object` omits element when LABEL is NULL; jsonb_set/jsonb_replace minimize changed bytes in large JSONB objects (reduces I/O).

## 3.49.2 — 2025-05-07 (Patch)
NOT NULL optimization fix (3.40.0 regression); count-of-view DISTINCT fix; UNIQUE constraint + IN fix; generate_series() fixes.

## 3.49.1 — 2025-02-18 (Patch)
Portability fixes; concat_ws() memory error fix (separator >2MB); LOOKASIDE robustness.

## 3.49.0 — 2025-02-06
**Query planner:** Improved query-time index optimization for WITHOUT ROWID tables; better star-join query plans; tie-breaker by bytes per row.

**SQL:** iif() now accepts any number of arguments (≥2).

**Session extension:** Works on databases with generated columns.

**New DBCONFIG options:** `ENABLE_ATTACH_CREATE`, `ENABLE_ATTACH_WRITE`, `ENABLE_COMMENTS` (all default ON).

**Build:** Autosetup replaces Autotools for the amalgamation tarball configure script.

## 3.48.0 — 2025-01-14
**Build:** Configure script refactored to use Autosetup (canonical sources). No TCL required for common build targets.

**SQL:** Two-argument iif(); `if()` as alias for `iif()`.

**CLI:** `.dbtotxt` command.

**C APIs:** `SQLITE_IOCAP_SUBPAGE_READ`, `SQLITE_PREPARE_DONT_LOG`, `SQLITE_FCNTL_NULL_IO`, max function args 127→1000.

**FTS5:** xInstToken() works with prefix queries via `insttoken` config option and `fts5_insttoken()` SQL function.

**Other:** Minimum `SQLITE_LIMIT_LENGTH` raised from 1 to 30; removed vestigial SQLITE_USER_AUTHENTICATION.

## 3.47.2 — 2024-12-07 (Patch)
Float conversion fix for values where first 16 significant digits are '1844674407370955' (x64/i386 only, regression in 3.47.0).

## 3.47.1 — 2024-11-25 (Patch)
DESTDIR fix for make install; SQLITE_IOCAP_SUBPAGE_READ for non-standard VFSes; sqlite3_rsync.exe Windows line endings fix; IN query optimization fix.

## 3.47.0 — 2024-10-21
**SQL:** Arbitrary expressions in RAISE() function; `->>` with negative index accesses from right; generate_series() constraint awareness.

**FTS5:** `fts5_tokenizer_v2` API with `locale=1` option; `contentless_unindexed=1` option; tables droppable without custom tokenizer.

**Query planner:** Bloom filter for IN subqueries; order-by-subquery optimization; indexed-subtype-expr optimization; star query improvements; automatic index avoidance on non-selective columns.

**CLI tools:** Experimental sqlite3_rsync; median/percentile/percentile_cont/percentile_disc extensions; .www dot-command.

**Notable:** `long double` data type removed (uses Dekker's algorithm); TCL9 support; sqlite_dbpage INSERT can change DB file size.

## 3.46.1 — 2024-08-13 (Patch)
FTS5 tokenize= parsing robustness; covering index over-prediction detection; VALUES clause limit fix; group_concat() window function fix; FTS5 secure-delete false positive fix.

## 3.46.0 — 2024-05-23
**PRAGMA optimize:** Automatic analysis limit; 0x10000 bitmask for all-table updates; auto-re-analyze missing stat1 tables.

**Date/time:** strftime() gains %G, %g, %U, %V; 'ceiling'/'floor' modifiers for month/year shifts; 'utc'/'localtime' are no-ops when already correct.

**SQL:** Underscore in numeric literals; json_pretty() function.

**JSON:** ASCII control chars in JSON5 strings; -> and ->> treat string-looking integers as strings (PG-compat).

**Query planner:** VALUES-as-coroutine (2× faster, half memory for large INSERTs); count(DISTINCT col) using index; constant function recognition; WHERE push-down with uncorrelated subqueries.

**Other:** Parser stack overflow allocates from heap instead of failing.

## 3.45.3 — 2024-04-15 (Patch)
UPSERT trigger old.* values fix (going back to 3.24.0); sum() returning NULL instead of Infinity fix.

## 3.45.2 — 2024-03-12 (Patch)
UPSERT index out-of-sync fix (regression from 3.35.0); NOT NULL strength reduction scope fix.

## 3.45.1 — 2024-01-30 (Patch)
JSON BLOB input backward compatibility restored; integrity_check on read-only DBs with FTS3/5; corrupt JSONB processing fixes; mmap over-read fix; NULL dereference fix.

## 3.45.0 — 2024-01-15
**JSONB:** All JSON functions rewritten to use JSONB internal format (serializable, storable in DB). json_valid() gains optional second argument.

**New property:** `SQLITE_RESULT_SUBTYPE` for app-defined SQL functions.

**FTS5:** tokendata option.

**Performance:** `SQLITE_DIRECT_OVERFLOW_READ` enabled by default.

**Query planner:** Better transitive constraint handling; disregarded low-quality indexes from ANALYZE.

**Max page count:** Increased from 1,073,741,824 to 4,294,967,294.

**CLI:** Improved UTF-8 display on Windows; auto-detects `.dump` playback.

## 3.44.2 — 2023-11-24 (Patch)
CLI fix from 3.44.1; FTS5 fuzz fix; incomplete assert() fixes.

## 3.44.1 — 2023-11-22 (Patch)
CLI uses UTF-16 for Windows console I/O.

## 3.44.0 — 2023-11-01
**SQL:** Aggregate ORDER BY (`string_agg(x, ',' ORDER BY y)`); concat()/concat_ws() scalars; string_agg() aggregate; new strftime() letters: %e %F %I %k %l %p %P %R %T %u.

**C APIs:** `sqlite3_get_clientdata()`, `sqlite3_set_clientdata()`.

**Integrity:** PRAGMA integrity_check verifies FTS3/4/5, RTREE, GEOPOLY via xIntegrity method.

**Security:** DEFENSIVE prevents enabling writable_schema; VTAB_INNOCUOUS on built-in virtual tables; PRAGMA case_sensitive_like deprecated.

**Query planner:** Partial index covering optimization with constant propagation.

**CLI:** Windows defaults to UTF-8 (--no-utf8 to disable).

**Build:** SEH enabled by default on MSVC; runtime detection of long double precision.

## 3.43.2 — 2023-10-10 (Patch)
UAF fixes and memory leak fix; removed sprintf() from CLI; double→unsigned long long conversion fix.

## 3.43.1 — 2023-09-11 (Patch)
sum()/avg()/total() infinity regression fix; json_array_length() + json_remove() fix; omit-unused-subquery-columns fix for compound DISTINCT.

## 3.43.0 — 2023-08-24
**FTS5:** Contentless-Delete FTS5 indexes (store no content, allow deletes).

**Date/time:** timediff() function; ±YYYY-MM-DD HH:MM:SS.SSS shift modifiers.

**SQL:** octet_length() function; sqlite3_stmt_explain() API.

**Query planner:** OUTER JOIN strength reduction generalized (RIGHT/FULL JOINs); better theorem prover for fewer false negatives.

**Extensions:** decimal_pow2(), decimal_exp(); decimal() full float expansion.

**Performance:** 2× JSON processing speedup for large strings.

**Platform:** SQLITE_USE_SEH on Windows; nanosleep() assumed on unix.

## 3.42.0 — 2023-05-16
**JSON:** JSON5 extensions; max array/object recursion depth 2000→1000.

**FTS5:** secure-delete command (removes forensic traces from inverted index).

**Query planner:** count-of-view optimization enabled by default; avoid unused subquery columns; WHERE push-down improvements.

**C APIs:** `SQLITE_DBCONFIG_STMT_SCANSTATUS`, `SQLITE_DBCONFIG_REVERSE_SCANORDER`; app-defined functions can use join keywords as names.

**CLI:** `--unsafe-testing`; `.log on/off` in --safe; `:inf/:nan` magic params; `--utf8` on Windows.

**PRAGMA:** integrity_check detects NaN in NOT NULL columns; improved error messages with root page.

**Session:** Supports tables without explicit ROWID.

## 3.41.2 — 2023-03-22 (Patch)
Buffer over-read fixes (corrupt DB with STAT4, CLI error_offset, recovery extension, FTS3); sqlite3_error_offset() fix for generated columns; 64-bit page cache ref counter.

## 3.41.1 — 2023-03-10 (Patch)
HAVE_LOG2/HAVE_LOG10 compile options; CAST(7 AS INT) column type preserved as INT; integrity_check detects extra bytes at end of index record.

## 3.41.0 — 2023-02-21
**SQL:** unhex() function; base64/base85 extension (in CLI).

**C APIs:** `sqlite3_stmt_scanstatus_v2()`, `sqlite3_is_interrupted()`, `SQLITE_FCNTL_RESET_CACHE`.

**Query planner:** Indexed expressions in aggregate GROUP BY queries; better covering index cost estimates; more aggressive co-routine usage; json_tree()/json_each() ORDER BY rowid no-op.

**CLI:** `.scanstats est`; continuation prompt shows context; double-quoted string misfeature disabled by default.

**Notable:** sqlite3_prepare() now invokes progress handler and responds to interrupt.

## 3.40.1 — 2022-12-28 (Patch)
UPSERT WHERE clause optimization overreach fix; window function PARTITION BY zero-row group fix; JSON BLOB byte ordering fix; large hexadecimal literal fixes.

## 3.40.0 — 2022-11-16
**Platform:** WASM (WebAssembly) support (beta).

**SQL:** Recovery extension; VACUUM INTO honors PRAGMA synchronous.

**Security:** PRNG changed from RC4 to Chacha20; DEFENSIVE prevents changing schema_version.

**C APIs:** `sqlite3_value_encoding()`; `SQLITE_MAX_ALLOCATION_SIZE` compile option.

**Query planner:** Covering indexes on >63 column tables; expression index value extraction; NOT NULL/IS NULL skip large blob loads; avoid single-use view materialization.

## 3.39.4 — 2022-10-06 (Patch)
UAF in window function xStep callback fix; sqldiff PRIMARY KEY ordering fix; SELECT mem accounting fix.

## 3.39.3 — 2022-09-30 (Patch)
UAF in UPSERT with expression indexes fix; JSON BLOB canonical form fixes; CLI .import --csv header fix.

## 3.39.2 — 2022-09-06 (Patch)
sqlite3_db_config() DEFENSIVE fix; sqldiff WITHOUT ROWID support; DBSTAT hash/sort skipping fix.

## 3.39.1 — 2022-07-23 (Patch)
JSON array/object recursion depth fix; sqldiff segfault fix; sqldiff WITHOUT ROWID handling.

## 3.39.0 — 2022-06-25
**JOINs:** RIGHT and FULL OUTER JOIN.

**SQL:** IS NOT DISTINCT FROM / IS DISTINCT FROM operators; HAVING clause without GROUP BY.

**C APIs:** `sqlite3_db_name()`; vtab_distinct() return code 3.

**Security:** `SQLITE_OPEN_NOFOLLOW` fail on symlink path elements.

**Query planner:** Deferred view materialization; ~2.3% CPU reduction.

## 3.38.5 — 2022-05-05 (Patch)
Mem5 OOM deadlock fix; lookaside double-free on OOM fix; FTS5 prefix query fix.

## 3.38.3 — 2022-04-27 (Patch)
Aggregate query flattening overreach fix; DBSTAT permutation generator fix; CLI quote mode fix.

## 3.38.2 — 2022-03-26 (Patch)
OP_OpenDup cursor fix; Bloom filter uninitialized value fix; LEMON parser template CVE fix.

## 3.38.1 — 2022-03-12 (Patch)
`sqlite3_error_offset()` off-by-one fix; fts5vocab ORDER BY performance fix.

## 3.38.0 — 2022-02-22
**JSON:** `->` and `->>` operators (MySQL/PG compatible); JSON functions built-in (`-DSQLITE_OMIT_JSON` to disable).

**SQL:** unixepoch() date function; format() SQL function (printf() retained as alias).

**C APIs:** `sqlite3_error_offset()` (character-level error localization); `sqlite3_vtab_distinct()`, `sqlite3_vtab_rhs_value()`, `sqlite3_vtab_in()`; `SQLITE_INDEX_CONSTRAINT_LIMIT/OFFSET`.

**Query planner:** Bloom filter for large analytic queries; balanced merge tree for UNION/UNION ALL with ORDER BY.

**CLI:** `--wrap/--wordwrap/--quote` options; `.mode qbox`; better error messages.

## 3.37.2 — 2022-01-07 (Patch)
UAF in RBU vacuum fix; ORDER BY {col} with no such column fix; lookaside OOM fix.

## 3.37.1 — 2021-12-13 (Patch)
CLI --safe mode tightened; .import CSV tab fix; .dump --data-only table list fix.

## 3.37.0 — 2021-11-27
**SQL:** STRICT tables (`CREATE TABLE ... STRICT`); ALTER TABLE ADD COLUMN validates existing rows; PRAGMA table_list.

**C APIs:** `sqlite3_autovacuum_pages()`; `sqlite3_changes64()`, `sqlite3_total_changes64()`; `SQLITE_OPEN_EXRESCODE`.

**Query planner:** Omits ORDER BY on subqueries/views when semantics unchanged.

**CLI:** `.connection` (multiple DB connections); `--safe` option.

**generate_series():** START parameter now required.

## 3.36.0 — 2021-06-18
**SQL:** sqlite3_deserialize()/serialize() enabled by default; memdb VFS sharing for names starting with "/"; BOM skipped as whitespace.

**CLI:** REGEXP extension included by default.

**Query planner:** Improved EXPLAIN QUERY PLAN output; constant-propagation on non-join queries; EXISTS-to-IN optimization backed out.

## 3.35.5 — 2021-06-07 (Patch)
REINDEX corruption fix; CREATE TABLE AS with zero-column fix; FTS5 triple-expression fix.

## 3.35.4 — 2021-04-23 (Patch)
Generated column bug fix; CLI hex integer overflow fix; sqldiff constraint detection fix.

## 3.35.3 — 2021-04-16 (Patch)
ALTER TABLE DROP COLUMN fixes; JSON string/INTEGER parity fix; sqldiff detection of renamed columns.

## 3.35.2 — 2021-03-28 (Patch)
WAL reader/writer race fix; ALTER TABLE DROP COLUMN on WITHOUT ROWID fix; JSON boolean/text distinction fix.

## 3.35.1 — 2021-03-16 (Patch)
UPSERT storage leak fix; SELECT ... EXCEPT/INTERSECT with ORDER BY fix; DISTINCT with collation fix.

## 3.35.0 — 2021-03-12
**DDL:** ALTER TABLE DROP COLUMN.

**DML:** RETURNING clause on DELETE/INSERT/UPDATE.

**SQL:** Generalized UPSERT (multiple ON CONFLICT clauses); MATERIALIZED/NOT MATERIALIZED CTE hints; built-in math functions (with `SQLITE_ENABLE_MATH_FUNCTIONS`).

**Query planner:** EXISTS-to-IN optimization; UNION ALL flattening across joins; IS NULL → FALSE conversion with NOT NULL; WHERE push-down into window function subqueries; skip FK checks on UPDATE when FK columns unchanged.

**Performance:** Less memory for VACUUM of large TEXT/BLOB values.

## 3.34.1 — 2021-02-12 (Patch)
ALTER TABLE RENAME COLUMN check constraint fix; .dump --data-only INSERT size fix; ORDER BY LIMIT optimization robustness fix.

## 3.34.0 — 2020-12-01
**SQL:** Multi-recursive CTE terms (SQL Server compatible); substring() alias for substr().

**FTS5:** Trigram indexes.

**C APIs:** `sqlite3_txn_state()`.

**Query planner:** OP_SeekScan opcode for multi-column IN lookups; improved DISTINCT cost estimates; postpone main table seek in multi-column UPDATE/DELETE.

**WAL:** Improved locking with hundreds of concurrent connections.

**CLI:** `.read` accepts pipeline; `.dump --data-only/--nosys`; `.schema --nosys`; `.databases` shows txn state.

## 3.33.0 — 2020-08-14
**SQL:** UPDATE FROM (PostgreSQL syntax); max database file size increased to 281 TB.

**Extensions:** decimal extension (arbitrary-precision); ieee754 enhancements.

**Query planner:** Full-index-scan for INDEXED BY; better detection of missing stat1 data; `SELECT min(x) ... WHERE y IN (...)` using index on t(x,y).

**WAL:** Crashed writer recovery with active readers (previously SQLITE_PROTOCOL).

**CLI:** box, json, markdown, table output modes; auto-expanding column mode.

## 3.32.3 — 2020-07-22 (Patch)
CREATE TABLE AS with no rows and TEXT affinity fix; session changeset TABLE fix; FTS5 corrupt set like "aaa*" fix.

## 3.32.2 — 2020-06-25 (Patch)
AVG() overflow fix for large integers; EXISTS operator over FTS5 content table fix; generated column FK fix.

## 3.32.1 — 2020-06-17 (Patch)
Generated column + ALTER TABLE RENAME fix; CLI --deserialize fix.

## 3.32.0 — 2020-05-22
**SQL:** PRAGMA analysis_limit (approximate ANALYZE); iif() function; ESCAPE clause matches PG behavior.

**C APIs:** `sqlite3_create_filename()`, `sqlite3_free_filename()`, `sqlite3_database_file_object()`; max parameters 999→32766.

**Extensions:** bytecode virtual table; checksum VFS shim; UINT collation.

**CLI:** `.import --csv/--ascii/--skip`; `.dump` multiple patterns; `.oom`; `--bom`.

## 3.31.1 — 2020-02-19 (Patch)
ALTER TABLE ADD COLUMN with DEFAULT and NOT NULL fix; .import CSV whitespace handling fix; RBU VACUUM fix.

## 3.31.0 — 2020-01-22
**SQL:** Generated columns (GENERATED ALWAYS AS ...); SQLITE_DBCONFIG_TRUSTED_SCHEMA; PRAGMA trusted_schema.

**C APIs:** `sqlite3_hard_heap_limit64()`; `sqlite3_filename_database/journal/wal()`; `sqlite3_uri_key()`; `SQLITE_OPEN_NOFOLLOW`.

**JSON:** "#-N" array notation for JSON path arguments.

**Extensions:** uuid.c for RFC-4122 UUIDs.

**Performance:** 2-pool lookaside (48KB/connection, down from 120KB); faster sqlite3_interrupt().

## 3.30.1 — 2019-10-28 (Patch)
VALUES-as-table with correlated subqueries fix; RBU with FTS5 fix; regexp() unicode fix.

## 3.30.0 — 2019-10-04
**SQL:** FILTER clause on aggregates; NULLS FIRST/LAST syntax in ORDER BY.

**C APIs:** `sqlite3_drop_modules()`; `SQLITE_DBCONFIG_ENABLE_VIEW`; `SQLITE_DIRECTONLY` for app-defined functions.

**PRAGMA:** function_list, module_list, pragma_list enabled by default.

## 3.29.0 — 2019-07-10
**SQL:** `SQLITE_DBCONFIG_DQS_DML/DQS_DDL` to control double-quoted string misfeature.

**Query planner:** Improved AND/OR constant optimization; LIKE optimization with numeric affinity.

**Extensions:** sqlite_dbdata virtual table for raw corrupt DB extraction.

**CLI:** `.recover` command; `.filectrl`; `.dbconfig`.

## 3.28.0 — 2019-04-16
**Window functions:** EXCLUDE clause, window chaining, GROUPS frames; `<expr> PRECEDING/FOLLOWING` in RANGE frames.

**C APIs:** `sqlite3_stmt_isexplain()`; `sqlite3_value_frombind()`.

**FTS:** fts3_tokenizer() always returns NULL unless explicitly enabled.

**CLI:** `.parameter` command; `.archive --update/--insert`.

## 3.27.2 — 2019-03-13 (Patch)
UPSERT + expression index fix; sqldiff WITHOUT ROWID fix; DBSTAT VFS name fix.

## 3.27.1 — 2019-02-21 (Patch)
sqldiff INTEGER PRIMARY KEY detection fix; window function ORDER BY complex expression fix; FTS5 integrity-check fix.

## 3.27.0 — 2019-02-07
**SQL:** VACUUM INTO command; double-quoted string literal warning messages.

**C APIs:** `SQLITE_PREPARE_NO_VTAB`; `SQLITE_FCNTL_SIZE_LIMIT` for deserialize; `SQLITE_DESERIALIZE_READONLY` honored.

**FTS:** remove_diacritics=2 option.

**CLI:** `.open --hexdb`; `--memtrace`; `.eqp trace`; `.progress`.

## 3.26.0 — 2018-12-01
**SQL:** SQLITE_DBCONFIG_DEFENSIVE; PRAGMA legacy_alter_table; PRAGMA table_xinfo (includes hidden VT columns).

**C APIs:** `sqlite3_normalized_sql()` (with SQLITE_ENABLE_NORMALIZE).

**CLI:** `--deserialize`; `SQLITE_HISTORY` env var.

**Extensions:** explain virtual table; geopoly; session `CHANGESETAPPLY_INVERT`.

## 3.25.3 — 2018-11-05 (Patch)
Window function ORDER BY NULLS FIRST fix; WAL page cache overflow fix; RTREE container overflow fix.

## 3.25.2 — 2018-09-26 (Patch)
Window function PARTITION BY + ORDER BY fix; ALTER TABLE RENAME COLUMN uniqueness fix; DISTINCT with text affinity fix.

## 3.25.1 — 2018-09-19 (Patch)
Window function integer overflow fix.

## 3.25.0 — 2018-09-15
**SQL:** Window functions (full support); ALTER TABLE RENAME COLUMN; ALTER TABLE updates trigger/view references.

**C APIs:** `SQLITE_FCNTL_DATA_VERSION` file-control.

**Extensions:** Geopoly module.

**Query planner:** IN-early-out for multi-column indexes; transitive constant propagation; avoid unnecessary column loads in aggregate queries.

**Performance:** Separate mutex per inode in unix VFS.

## 3.24.0 — 2018-06-04
**SQL:** PostgreSQL-style UPSERT; auxiliary columns in R-Tree.

**C APIs:** `sqlite3_keyword_count/name/check()`; `sqlite3_str` dynamic string API; `SQLITE_DBCONFIG_RESET_DATABASE`.

**Query planner:** ORDER BY LIMIT avoids unnecessary rows; OR optimization → IN expression; more aggressive auto-indexes for views/subqueries; UPDATE avoids unnecessary disk writes.

**CLI:** EXPLAIN QUERY PLAN → ASCII-art graph; `#` comments; `.backup --append`; `.dbconfig`.

## 3.23.1 — 2018-04-11 (Patch)
LEFT JOIN + transitive constraints fix; OP_TypeCheck with generated column fix; REPLACE + FK fix.

## 3.23.0 — 2018-04-02
**SQL:** TRUE/FALSE as constants; IS TRUE/FALSE/NOT TRUE/NOT FALSE operators.

**C APIs:** `sqlite3_serialize()`, `sqlite3_deserialize()`; `SQLITE_DBSTATUS_CACHE_SPILL`.

**Query planner:** LEFT JOIN strength reduction (LEFT → ordinary JOIN); improved push-down for many LEFT JOINs; omit-unused-left-join works with UNIQUE.

**CLI:** `-A` command-line option for archive management.

## 3.22.0 — 2018-01-22
**SQL:** Read-only WAL mode access without write permission.

**Extensions:** Zipfile virtual table; Append VFS; sqlite_btreeinfo virtual table; fsdir() table-valued function.

**C APIs:** `sqlite3_vtab_nochange()`, `sqlite3_vtab_collation()`, `sqlite3_vtab_distinct()`.

**FTS5:** `^` initial token syntax.

**CLI:** `.archive`, `.expert`, `.excel` commands; `.eqp` trigger variant.

## 3.21.0 — 2017-10-24
**SQL:** F2FS atomic-write support; ATTACH/DETACH inside transactions; WITHOUT ROWID VTs writable (single-column PK).

**Query planner:** Co-routines preferred over flattening for FROM-clause subqueries; LIKE optimization with ESCAPE; ~2.1% CPU reduction.

**Extensions:** sqlite_dbpage; Swarm virtual table; FTS5 "instance" vocab table.

## 3.20.1 — 2017-08-28 (Patch)
LIKE BINARY + case_sensitive_like fix; PRAGMA schema_version + WAL fix; VIEW with compound SELECT + DISTINCT fix.

## 3.20.0 — 2017-08-01
**C APIs:** `sqlite3_prepare_v3()`/`sqlite3_prepare16_v3()`; Query Planner Stability Guarantee (`SQLITE_DBCONFIG_ENABLE_QPSG`).

**Extensions:** SQLITE_STMT virtual table; COMPLETION extension (tab-completion); UNION virtual table.

**SQL:** PRAGMA secure_delete=FAST.

**CLI:** Tab-completion; `.cd`; enhanced `.schema/.tables`; `.import` ignores UTF-8 BOM.

## 3.19.3 — 2017-07-08 (Patch)
REPLACE + FK fix; CHECK constraint with ALTER TABLE ADD COLUMN fix; geopoly fix.

## 3.19.2 — 2017-06-08 (Patch)
sqldiff WITHOUT ROWID + expression index fix; fts5vocab ORDER BY fix.

## 3.19.1 — 2017-06-01 (Patch)
REPLACE + FK ON DELETE fix; .import CSV header quoting fix; csv module quoting fix.

## 3.19.0 — 2017-05-22
**Query planner:** Index expression values used directly; LEFT JOIN view flattening; skip-ahead DISTINCT using index; HAVING-to-WHERE term transfer for GROUP BY columns; reuse VIEW materialization.

**FTS5:** Column filters on arbitrary expressions.

**JSON:** json_extract() caches and reuses JSON parses.

**Bug:** integrity_check detects duplicate rowids; REPLACE corruption fix.

## 3.18.1 — 2017-04-06 (Patch)
LEFT VIEW flattening fix; .import CSV comma-in-string fix; FTS5 "rank" column name fix.

## 3.18.0 — 2017-03-28/30
**SQL:** PRAGMA optimize command; json_patch() in JSON1.

**C APIs:** `sqlite3_set_last_insert_rowid()`; `-DSQLITE_MAX_MEMORY=N` compile option.

**Query planner:** Early empty-table detection in joins; LIKE optimization extended to arbitrary LHS; integrity_check/quick_check verify CHECK constraints.

**Security:** SQLITE_SOURCE_ID / sqlite3_sourceid() use SHA3-256 (was SHA1).

**CLI:** `.sha3sum`, `.selftest`; printf comma-format ("%,d").

## 3.17.0 — 2017-02-13
**SQL:** Session extension supports WITHOUT ROWID tables.

**Query planner:** ~6.5% fewer CPU cycles; UPDATE in single pass instead of two.

**R-Tree:** ~25% better performance.

**C APIs:** `SQLITE_DEFAULT_LOOKASIDE` compile option; `SQLITE_DIRECT_OVERFLOW_READ` in WAL mode.

## 3.16.2 — 2017-01-23 (Patch)
Index on expression maintenance in REPLACE fix; fts3 near + NOT fix; ANALYZE partial index fix.

## 3.16.1 — 2017-01-14 (Patch)
PRAGMA functions + WAL fix; fts4 prefix + column filter fix; fts5 LIKE fix.

## 3.16.0 — 2017-01-02
**SQL:** PRAGMA functions (experimental, table-valued); WHERE x NOT NULL with LIKE/GLOB on partial indexes.

**Query planner:** 9% fewer CPU cycles; faster LIKE/GLOB with multiple wildcards.

**C APIs:** `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE`; sqlite3_interrupt() interrupts checkpoints.

**CLI:** `.mode quote`, `.lint fkey-indexes`, `.imposter`.

**Performance:** Lookaside 500×128 → 125×512 bytes.

## 3.15.2 — 2016-11-29 (Patch)
fts5 expression syntax table creation fix; RBU conflict handling fix; LEFT JOIN materialization fix.

## 3.15.1 — 2016-11-08 (Patch)
UNION ALL query flattening with RIGHT JOIN fix; CHECK constraint REPLACE fix; ALTER TABLE RENAME on fts5 fix.

## 3.15.0 — 2016-10-14
**SQL:** Row value expressions; deterministic functions in partial index WHERE; VACUUM on ATTACH-ed databases.

**Query planner:** ~7% CPU reduction; most optimization in prepare step.

**CLI:** `.testcase`, `.check`; --new on .open.

**C APIs:** `SQLITE_DBCONFIG_MAINDBNAME`; "modeof=filename" URI parameter.

## 3.14.2 — 2016-09-20 (Patch)
WAL + shared memory read-only fix; hex() function memory allocation fix; sqlite3_trace_v2() callback fix.

## 3.14.1 — 2016-08-30 (Patch)
unix VFS NFS race fix; RBU INSERT/UPDATE stats fix; OR optimization + expression index fix.

## 3.14.0 — 2016-08-08 ("π Release")
**SQL:** WITHOUT ROWID virtual tables; OR optimization on VTs with LIKE/GLOB/REGEXP/MATCH; table-valued functions on RHS of IN; json_quote(); PRAGMA compile_options shows compiler version.

**C APIs:** `sqlite3_expanded_sql()`, `sqlite3_trace_v2()` (deprecates trace/profile); `SQLITE_DBSTATUS_CACHE_USED_SHARED`; `SQLITE_OK_LOAD_PERMANENTLY`.

**Query planner:** Improved ORDER BY LIMIT using inner-most loop ordering; partial index full scan over main table; better covering index cost.

**CLI:** dbhash utility; CSV virtual table (RFC 4180); carray() extension.
