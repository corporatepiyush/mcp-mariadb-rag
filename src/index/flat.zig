//! Flat (brute-force) vector index — the honest, always-correct baseline and the
//! mobile-tier default. Correct at any corpus size, just O(N·D).
//!
//! The core is `TopK`: a bounded **max-heap of the k smallest distances**. A
//! scan offers every candidate's distance; the heap keeps only the running best
//! k, so a pass over N candidates costs O(N·log k) time and O(k) memory and
//! never materializes the full result set. This is the structural fix for the
//! old `SELECT … LIMIT k` retrieval, which returned an arbitrary k rows and so
//! had broken recall for any corpus larger than k (PLAN.md §3).
//!
//! Allocation-free: the caller supplies the heap buffer (stack, arena, or a
//! budget-sized slab), keeping the selector usable inside a streaming DB cursor.

const std = @import("std");

/// Bounded top-k selector over an arbitrary payload `T` keyed by an f32 distance
/// (smaller = better). Backed by a max-heap so the worst kept element is always
/// at the root and evicted in O(log k) when a better candidate arrives.
pub fn TopK(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { dist: f32, item: T };

        heap: []Entry,
        len: usize = 0,

        /// `buf.len` is the capacity k. A zero-length buffer accepts nothing.
        pub fn init(buf: []Entry) Self {
            return .{ .heap = buf, .len = 0 };
        }

        pub fn capacity(self: *const Self) usize {
            return self.heap.len;
        }

        /// True once k entries are held — past this point only a strictly better
        /// distance is kept, so a scan can skip materializing a doomed candidate.
        pub fn isFull(self: *const Self) bool {
            return self.heap.len > 0 and self.len == self.heap.len;
        }

        /// Distance of the current worst kept entry. Only meaningful when `len > 0`.
        pub fn worstDist(self: *const Self) f32 {
            return self.heap[0].dist;
        }

        /// Offer a candidate. Returns true if it was kept (heap not yet full, or
        /// it beats the current worst). NaN distances are rejected so a corrupt
        /// vector can never displace a real neighbour.
        pub fn offer(self: *Self, dist: f32, item: T) bool {
            if (self.heap.len == 0 or std.math.isNan(dist)) return false;
            if (self.len < self.heap.len) {
                self.heap[self.len] = .{ .dist = dist, .item = item };
                self.siftUp(self.len);
                self.len += 1;
                return true;
            }
            // Full: replace the worst (root) only if this is strictly better.
            if (dist >= self.heap[0].dist) return false;
            self.heap[0] = .{ .dist = dist, .item = item };
            self.siftDown(0);
            return true;
        }

        /// Sort the kept entries ascending by distance in place and return them
        /// (best first). The heap invariant is destroyed; call once when done.
        pub fn sortedAsc(self: *Self) []Entry {
            const out = self.heap[0..self.len];
            std.sort.block(Entry, out, {}, lessByDist);
            return out;
        }

        fn lessByDist(_: void, a: Entry, b: Entry) bool {
            return a.dist < b.dist;
        }

        fn siftUp(self: *Self, start: usize) void {
            var i = start;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (self.heap[i].dist <= self.heap[parent].dist) break;
                std.mem.swap(Entry, &self.heap[i], &self.heap[parent]);
                i = parent;
            }
        }

        fn siftDown(self: *Self, start: usize) void {
            var i = start;
            while (true) {
                const l = 2 * i + 1;
                const r = 2 * i + 2;
                var largest = i;
                if (l < self.len and self.heap[l].dist > self.heap[largest].dist) largest = l;
                if (r < self.len and self.heap[r].dist > self.heap[largest].dist) largest = r;
                if (largest == i) break;
                std.mem.swap(Entry, &self.heap[i], &self.heap[largest]);
                i = largest;
            }
        }
    };
}
