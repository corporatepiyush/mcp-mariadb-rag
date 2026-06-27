//! Tests for src/doc/xml.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/xml.zig");

const toText = srcmod.toText;

test "xml: strips tags, keeps text" {
    try expectXml("<root><a>Hello</a> <b>World</b></root>", "Hello World");
}

test "xml: decodes entities" {
    try expectXml("<p>A &amp; B &lt;3 &#65;</p>", "A & B <3 A");
}

test "html: skips script and style" {
    try expectXml(
        "<html><style>p{color:red}</style><body>Hi<script>alert(1)</script>there</body></html>",
        "Hi there",
    );
}

test "xml: comments and CDATA" {
    try expectXml("<r><!-- skip me --><![CDATA[raw <tag>]]></r>", "raw <tag>");
}

test "xml: whitespace collapse" {
    try expectXml("<p>  a   b  \n c </p>", "a b c");
}

test "fuzz: xml extraction never panics" {
    var prng = std.Random.DefaultPrng.init(0x8A11);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    const alphabet = "<>/&;#amp lt gt 0123ABC \"'";
    for (0..1500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean()) alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)] else rnd.int(u8);
        }
        _ = toText(arena.allocator(), buf[0..n]) catch {};
    }
}

// ---- helpers moved from src ----
pub fn expectXml(input: []const u8, expect: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toText(arena.allocator(), input);
    try testing.expectEqualStrings(expect, r.text);
}
