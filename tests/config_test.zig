const std = @import("std");
const testing = std.testing;
const config = @import("../src/config.zig");

test "isLoopbackHost: localhost variants" {
    try testing.expect(config.isLoopbackHost("localhost"));
    try testing.expect(config.isLoopbackHost("LOCALHOST"));
    try testing.expect(config.isLoopbackHost("LocalHost"));
    try testing.expect(config.isLoopbackHost("127.0.0.1"));
    try testing.expect(config.isLoopbackHost("::1"));
}

test "isLoopbackHost: non-loopback" {
    try testing.expect(!config.isLoopbackHost("192.168.1.1"));
    try testing.expect(!config.isLoopbackHost("db.example.com"));
    try testing.expect(!config.isLoopbackHost("0.0.0.0"));
    try testing.expect(!config.isLoopbackHost("localhost.localdomain"));
    try testing.expect(!config.isLoopbackHost(""));
}

// ---- fuzzing --------------------------------------------------------------

test "fuzz: isLoopbackHost never panics on random ASCII strings" {
    var prng = std.Random.DefaultPrng.init(0xBEAD);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.intRangeAtMost(u8, 32, 126);

        _ = config.isLoopbackHost(s);
    }
}

test "fuzz: isLoopbackHost never panics on random high-byte sequences" {
    var prng = std.Random.DefaultPrng.init(0xFEED);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;

    for (0..200) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.int(u8);

        _ = config.isLoopbackHost(s);
    }
}
