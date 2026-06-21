const std = @import("std");
const pool = @import("../pool.zig");
const Payload = @import("mod.zig").Payload;

pub fn notImpl(_: std.Io, _: std.mem.Allocator, _: *pool.PooledConnection, _: ?std.json.Value) Payload {
    return .{ .text = "Not yet implemented", .is_error = true };
}
