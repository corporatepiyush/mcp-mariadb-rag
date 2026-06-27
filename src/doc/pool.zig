//! Memory pools for the document-ingest hot path.
//!
//! Why a pool on top of allocators (the question that motivated this file):
//! massive ingest chunks thousands of documents back-to-back. Each document the
//! chunker needs three scratch arrays (token starts, token ends, chunk records)
//! whose sizes scale with the document. Calling `alloc`/`free` per document
//! thrashes the general-purpose allocator (lock, size-class lookup, fragmentation)
//! and re-faults fresh pages every time. Per Agent.md:
//!   * "Object pools with intrusive free-lists eliminate per-element metadata."
//!   * "ArenaAllocator.reset(.retain_capacity) keeps the backing buffer mapped
//!      across requests, only bumping the pointer back."
//!
//! So we provide two primitives, both backed by a caller-supplied allocator:
//!   1. `Scratch`     — a retain-capacity arena: reset between documents, the
//!                      backing pages stay resident, the bump pointer rewinds.
//!                      This is the right tool for the variable-length per-doc
//!                      working set (token spans, chunk arrays).
//!   2. `Pool(T)`     — a fixed-size object pool with an intrusive free-list over
//!                      a dense slab. O(1) acquire/release, zero per-object
//!                      metadata, perfect locality on iteration. The right tool
//!                      for long-lived, uniformly-sized records recycled across
//!                      the whole ingest run (e.g. per-document descriptors).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Reset-per-document arena. Hand `allocator()` to the chunker/extractor; call
/// `reset()` after each document to rewind the bump pointer while keeping the
/// pages mapped. `deinit()` returns everything to the backing allocator.
pub const Scratch = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: Allocator) Scratch {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn allocator(self: *Scratch) Allocator {
        return self.arena.allocator();
    }

    /// Rewind for the next document; retains the backing buffer (no munmap).
    pub fn reset(self: *Scratch) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *Scratch) void {
        self.arena.deinit();
    }
};

/// A fixed-size object pool with an intrusive free-list.
///
/// Layout: a dense `slab` of `Node`s. Each free node stores the index of the
/// next free node in its own storage (the "intrusive" free-list — no side
/// table). The slab grows geometrically; live objects never move, so handles
/// stay valid across growth. `acquire` returns a stable `*T`; `release` pushes
/// it back. `index`/`get` allow handle-style (u32) references that survive a
/// realloc, per Agent.md's "relative offsets over 64-bit pointers".
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        const nil: u32 = std.math.maxInt(u32);

        const Node = union {
            value: T,
            next_free: u32,
        };

        backing: Allocator,
        slab: []Node,
        len: u32, // high-water mark of initialized nodes
        free_head: u32,
        live: u32, // currently-acquired count (diagnostics / leak check)

        pub fn init(backing: Allocator) Self {
            return .{
                .backing = backing,
                .slab = &.{},
                .len = 0,
                .free_head = nil,
                .live = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.backing.free(self.slab);
            self.* = undefined;
        }

        /// Pre-grow so the next `n` acquires don't reallocate (exact-fit per
        /// Agent.md when the count is known).
        pub fn ensureCapacity(self: *Self, n: u32) Allocator.Error!void {
            if (n <= self.slab.len) return;
            try self.grow(n);
        }

        fn grow(self: *Self, want: u32) Allocator.Error!void {
            const old = self.slab.len;
            var new_cap: usize = if (old == 0) 16 else old * 2;
            if (new_cap < want) new_cap = want;
            const fresh = try self.backing.realloc(self.slab, new_cap);
            self.slab = fresh;
        }

        /// O(1). Returns a stable pointer to (uninitialized) storage. The node's
        /// active union field is transitioned to `.value` by whole-union
        /// assignment so neither read nor address-of touches an inactive field.
        pub fn acquire(self: *Self) Allocator.Error!*T {
            if (self.free_head != nil) {
                const idx = self.free_head;
                self.free_head = self.slab[idx].next_free; // active field is .next_free
                self.slab[idx] = .{ .value = undefined }; // make .value active
                self.live += 1;
                return &self.slab[idx].value;
            }
            if (self.len == self.slab.len) try self.grow(self.len + 1);
            const idx = self.len;
            self.slab[idx] = .{ .value = undefined };
            self.len += 1;
            self.live += 1;
            return &self.slab[idx].value;
        }

        /// Handle form: stable u32 index that survives slab growth.
        pub fn index(self: *Self, ptr: *T) u32 {
            const node: *Node = @fieldParentPtr("value", ptr);
            const base = @intFromPtr(self.slab.ptr);
            const off = @intFromPtr(node) - base;
            return @intCast(off / @sizeOf(Node));
        }

        pub fn get(self: *Self, idx: u32) *T {
            return &self.slab[idx].value;
        }

        /// O(1) return to the free-list. Whole-union assignment flips the active
        /// field to `.next_free` without writing through an inactive field.
        pub fn release(self: *Self, ptr: *T) void {
            const idx = self.index(ptr);
            self.slab[idx] = .{ .next_free = self.free_head };
            self.free_head = idx;
            self.live -= 1;
        }

        /// Recycle every object at once without freeing backing memory.
        pub fn reset(self: *Self) void {
            self.len = 0;
            self.free_head = nil;
            self.live = 0;
        }
    };
}
