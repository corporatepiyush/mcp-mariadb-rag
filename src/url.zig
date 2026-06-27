//! Parser for `sqlite:///path/to/db` connection URIs.

const std = @import("std");

pub const ConnParams = struct {
    /// Set for `sqlite:///path` URIs. Borrows from the input URL.
    file_path: ?[]const u8 = null,
};

pub const ParseError = error{
    /// The URL did not start with `sqlite://`.
    UnsupportedScheme,
};

/// Parse a connection URL. Returns `file_path` for `sqlite://` URIs.
pub fn parse(url: []const u8) ParseError!ConnParams {
    if (std.mem.startsWith(u8, url, "sqlite://")) {
        const path = url["sqlite://".len..];
        if (path.len > 0 and path[0] == '/') {
            return .{ .file_path = path };
        }
        return .{ .file_path = if (path.len > 0) path else null };
    }
    return error.UnsupportedScheme;
}
