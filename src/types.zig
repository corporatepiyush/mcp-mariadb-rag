//! Plain data types shared between the database layer and the JSON serializer.

const std = @import("std");

/// How a column's textual value should be rendered in JSON.
///
/// The database layer hands every cell to us as a byte string regardless of
/// the declared column type, so we cannot infer "is this a number?" from the
/// bytes without corrupting data (`"007"` is a valid zip code, not the integer
/// 7). The connection layer therefore classifies each column up front from the
/// wire type and the serializer honours that classification.
pub const ColumnKind = enum {
    /// Integer / decimal / float column: emit the value as a bare JSON number
    /// token when it is well-formed, preserving exact digits (no float
    /// round-trip), otherwise fall back to a quoted string.
    numeric,
    /// Everything else (text, blob, date, enum, ...): always a JSON string.
    text,
};

/// A single result row. `null` entries represent SQL `NULL` and are distinct
/// from an empty string `""`.
pub const Row = struct {
    values: []const ?[]const u8,
};

/// The outcome of a query. For statements that produce no result set
/// (`INSERT`/`UPDATE`/`DELETE`/DDL) `rows` is `null` and the affected-row /
/// insert-id counters carry the information instead.
pub const QueryResult = struct {
    rows: ?[]const Row,
    column_names: ?[]const []const u8,
    column_kinds: ?[]const ColumnKind,
    num_fields: usize,
    num_rows: u64,
    affected_rows: u64,
    insert_id: u64,
};
