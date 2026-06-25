**Mandatory:** Before pushing any changes, consult `sqlite_releases.md` for SQLite release features and compatibility constraints. Every SQL feature, C API, and query-plan behavior used in new code must be verified against the supported SQLite version range.

**Core Objective:** Treat every abstraction as a measurable, quantifiable cost. Prioritize mechanical sympathy, cache-line granularity, zero-allocation hot paths, kernel-boundary minimization, and compiler-friendly structures. Every byte of indirection, every cycle of branch misprediction, and every nanosecond of cache coherency traffic is a failure to respect the silicon.

---

## Data Representation & CPU Cache Alignment

**Mechanical Sympathy over Deep Hierarchies:** Flat arrays over object graphs. A pointer dereference costs ~100 ns (DRAM) vs ~1 ns (L1). L1 is 32–64 KB per core, 64-byte cache lines on x86 and most ARM Cortex; 128-byte on Neoverse. Ensure each cache line carries only active payload. Avoid vtables and fat pointers in hot structs — they block scalar replacement. Pack fields tightly.

**SoA vs AoS:** Structure-of-Arrays loads only active fields into cache; auto-vectorizes naturally. Array-of-Structs drags inactive metadata into every cache line. For mixed patterns, use AoSoA (block 8–16 elements into mini-SoA bundles). Prefetch-friendly, SIMD-friendly.

**False Sharing:** Two threads writing distinct variables on the same 64-byte cache line trigger MESI invalidation — throughput can drop from millions to thousands of ops/sec. Pad atomics and hot counters to `align(64)`. Profile with `perf c2c`.

**Pointer Elimination:** Use base + index×stride instead of pointers. Intrusive lists embed links inside data. Dense arrays + sentinel bitmasks over hash-map buckets. Relative 32-bit offsets over 64-bit pointers — saves TLB entries and reduces per-element footprint.

**Tail Merge & Structure Slicing:** Group cold fields (flags, back-pointers) into a trailing allocation; only the hot prefix shares the primary cache line. Tagged unions: hot tag + index into a secondary payload arena. Zig `extern struct` with manual field ordering.

**Thread-Local & Per-CPU Data:** Partition hot mutable state per thread/CPU to eliminate coherency traffic. `threadlocal` in Zig maps to `fs`/`gs`-relative load (single instruction). For data without thread affinity, `rseq` (restartable sequences, Linux 4.18+) provides race-free per-CPU access with zero syscall cost — aborts on migration.

**NUMA Awareness:** Local DRAM ~80 ns, remote ~130–150 ns. Pin threads to their socket, allocate from local node. Interleave only for read-mostly cross-node data. Use `mbind`/`numactl` to enforce policy; disable kernel NUMA balancing for deterministic placement. Never allocate on one socket and mutate from another.

**Memory Sealing:**
**mseal (6.10+):** Lock VMA permissions permanently — stops `mprotect`/`munmap` tampering. Adds ~20–40 ns per VMA on seal. Use after `.text`/`.rodata` loading.
- **MAP_DROPPABLE (6.11+):** Anonymous mapping that kernel can zero under pressure — never swapped, never counts as mlocked. Enables vDSO `getrandom()` — cryptographically secure RNG in ~20 ns, no syscall.
- **memfd_create + F_SEAL*:** Anonymous RAM fd with one-way sealing (shrink, grow, write, exec). Combine with `MFD_HUGETLB` for sealed huge pages. Useful for immutable configuration blobs shared across processes.
- **userfaultfd RWP (6.14+):** Working-set tracking via page-fault traps. Identifies hot/cold pages without scanning. Async mode for lightweight detection, sync for race-free eviction.
- **guard pages:** `MADV_WIPEONFORK` for secret zeroing across fork; `MADV_DONTFORK` to exclude regions; `MADV_COLD`/`MADV_PAGEOUT` for proactive reclaim.

---

## Project Architecture & Abstraction Layers

**Flat Layering, Not Deep Hierarchies:** Define clear layer boundaries — transport → protocol → domain → storage. Each layer gets its own allocator and error set; crossing a layer means a clean type conversion, not leaking internals. Keep the dependency graph acyclic: inner layers never import outer layers. Direct style over indirection: prefer flat function calls over interface dispatch between internal layers.

**OS-Specific Code Isolation:** Gate platform logic with `@import("builtin").os.tag`. For large divergences, use separate `.zig` files per platform and conditionally `@import`. Do NOT scatter `if (builtin.os.tag == .linux)` through hot paths — centralize the divergence in one thin mapping file. Consequence of mixing: two parallel codebases maintained in one file, harder to read than actual duplication.

**Adapter Pattern Over C Dependencies:** One wrapper file per C library. Rules:
- Never leak C pointers or raw `*c_void` past the wrapper boundary — translate to Zig slices, enums, and tagged unions immediately.
- Convert C return codes to Zig error unions at the call site, not one level up.
- Use a vtable struct (function pointer table) only when the backend is swappable at runtime. Pro: one indirect call per operation, zero allocation for dispatch. Con: blocks inlining across the boundary. For single-backend builds, skip the vtable and call the wrapper type directly — monomorphization beats polymorphism.

**External Dependency Discovery:** Browse [awesome-zig](https://github.com/nrdmn/awesome-zig) and [awesome-c](https://github.com/oz123/awesome-c) on GitHub to find packages. Before adopting, read the full source — every dependency must be compatible with Agent.md's principles (no hidden allocs, no deep hierarchies, zero-copy where possible, explicit error handling). If a package violates these but is otherwise useful, fork it locally and refactor to compliance rather than accepting technical debt at the boundary.

**Allocator Flow Through Layers:** Every public function that might allocate takes an `Allocator` parameter. Pass it down from the top: transport creates an arena per connection → protocol parser → query builder → result serializer. At request end, arena reset frees everything in that subtree. Never let an inner layer hold a reference to an outer layer's allocator past the request — that's a use-after-free or arena lifetime extension, both silent corruption.

---

## Algorithmic Mastery & Lock-Free Concurrency

**Eradicate Blocking on Hot Paths:** Mutex context switches cost ~1–2 μs. Replace with CAS loops, acquire/release pairs, atomic sequence counters. On x86, RMW is implicitly strong (TSO); on ARM be explicit. Use Zig's `std.atomic.Value` or `@atomic` builtins. Measure: if you see `futex` in `perf trace` on hot path, you're doing it wrong.

**Futex2 & Multi-Object Wait (5.16+):**
- **futex_waitv:** Wait on up to 128 futexes simultaneously — replaces epoll/eventfd for sync objects. Reduces spin-lock calls >80% in contended workloads.
- **FUTEX2_NUMA:** Bind futex to NUMA node; wake local waiters only.
- **futex_waitv + io_uring:** Submit futex wait as io_uring SQE — eliminates the syscall entirely on the wait side.

**Bespoke Data Structures:**
- **Ring Buffers:** Fixed-size, power-of-two for mask-based indexing. SPSC: head + tail on separate cache lines. MPMC: double-width CAS or fetch-and-add. 64-bit sequence counters to avoid ABA.
- **Sparse Sets:** Dense element array + sparse ID→index map. O(1) insert, delete, clear, membership. Iterates with perfect locality. Zero initialization overhead on clear (just reset count). Ideal for ECS.
- **Radix Tries:** Monolithic node array, 32-bit indices instead of pointers. Multi-bit stride (4–8 bits) for shallow depth. No collisions, no pointer chasing.
- **Intrusive Containers:** Links embedded in data structs — data and link travel together in cache. Index-based version for arena-backed allocators.

**Data Structure Decision Framework — when to reach, when to build:**

**Std lib choice→cost (pros / cons):** `ArrayList(T)` — contiguous iteration, O(1) append amortized, O(n) insert/delete, resizes 2×, worst-case copy of entire live set. `HashMap(K,V,Context)` — O(1) average lookup, but 2–3× memory overhead, resize rehashes everything, iteration is fragmented. `MultiArrayList(T)` — SOA layout, only hot fields in cache, ideal for scan-heavy work; complex insertion/deletion, no random update. `SinglyLinkedList` / `DoublyLinkedList` — intrusive, zero allocation per node, O(1) splice; O(n) traversal, pointer-chasing destroys cache. `Slice([]T)` — zero-cost view, no growth, best for read-only and borrows.

**Memory growth patterns:** Power-of-two doubling (ArrayList default) — simple, waste up to 50% capacity. Exact-fit pre-count — zero waste, zero resize, requires upfront knowledge. Slab region (arena chunk per size class) — no per-element overhead, batch free, ideal for request-scoped allocation. Geometric growth with a min (e.g. `@max(16, @min(cap*2, 1<<20)`) — dampens tail waste.

**Custom data structure signals — spot these in code:**
- Hot path traversing a linked list → replace with flat `ArrayList` + index-based intrusive list.
- HashMap used with a `<1KB` key domain → replace with `[N]Value` array-indexed by key (or perfect hash via `std.hash_map` with single-bucket mode).
- Frequent `ArrayList` resize in a known-max loop → `ensureTotalCapacity` at top; if max unknown, arena reset.
- Append-once, scan-many over structured data → `MultiArrayList` (column-major) or `struct { cols: []align(64) T }` — SOA for SIMD, free prefetch.
- O(n²) nested loops with equality check → hash-join (build set from smaller side, probe with larger).
- Same string repeated in lookups → string interning (dedup to `[]u8` in a global pool, compare by pointer).

**Custom hash functions — when std is not enough:**
`HashMap` default is salted SipHash(1,3) — DoS-resistant, safe. Replace when:
- **Integer keys with dense domain** → identity hash (`fn hash(k: K) u64 { return @intCast(k); }`), simplest, zero collisions.
- **Integer keys with sparse/unknown domain** → xxHash3 or wyhash (throughput over SipHash, no salt required).
- **Small keys (≤8 bytes)** → FNV-1a (trivial, single multiply, competitive latency).
- **Known-at-comptime key set (enum literals, config keys)** → perfect hashing: comptime build a minimal perfect hash; no collisions, no resize, O(1) with one multiply and one dereference.
- **Throughput-sensitive string keys** → XXH3 streaming, compare by pointer after interning.
- **Hash DoS is a threat (public-facing lookup)** → keep SipHash or use SipHash(2,4) with per-table random seed.

**How to spot these in code review / refactoring:**
- `grep` for `HashMap` with large `init(alloc, n)` where `n` is arbitrary — could be array-indexed or perfect-hash.
- `grep` for `LinkedList` or `DoublyLinkedList` in any function called >10³/session — pointer-chasing O(n) is a symptom, not a solution.
- `grep` for `.append(` inside `for` loops without `ensureTotalCapacity` — pre-count needed.
- `grep` for nested `for` loops over slices with `==` or `.eql` — candidate for hash-join.
- `grep` for `ArrayList` pass-by-value or returned from hot function — unnecessary copy.
- `grep` for `Sort` that runs more than once in a request — consider sorted insert instead of sort-after-build.

**Sorting & Searching — algorithm choice by data shape:**
`std.sort.block` (introsort) — general-purpose, O(n log n), no extra memory. TimSort — O(n) on nearly-sorted, ideal for data that arrives partially ordered. Radix sort — O(n) for fixed-size integer keys, by byte stride, beats comparison sort at >10³ elements. Counting sort — O(n+k) when key range (k) is small (< 10⁴). Searching: `std.sort.binarySearch` — always prefer over O(n) scan for sorted data; interpolation search for uniformly-distributed keys (O(log log n)). For unsorted: build hash set once, probe repeatedly — amortizes the build cost across lookups.

**State Sharding:** Partition mutable state by thread/core ID modulo N. Writes hit local shard only; readers merge lazily. Shard count 2–4× physical cores to reduce collisions. Batch global flushes at ms intervals. Pin shards to physical cores.

**RCU & Epoch-Based Reclamation:** Readers proceed with zero atomics; writer publishes via single atomic swap. Grace periods via quiescent-state counters or per-thread epochs. Beats read-write locks at >90% reads. User-space RCU via `liburcu` (membarrier, signal, bp variants).

**Memory Reclamation Taxonomy:**
- **Hazard Pointers:** Per-reader single-word slots pinning in-use pointers. One atomic store per pointer load. Works on any data structure.
- **EBR:** Global epoch; readers announce critical sections. Lower per-access cost than HP, but requires quiescent states.
- **IBR:** Batches retirements; eliminates per-reader overhead entirely.
- **DEBRA:** Hybrid — adapts to read/write ratio dynamically.
- **Kernel RCU flavors:** SRCU (sleepable), Tasks RCU (for `schedule()` quiescence), dyntick RCU (NO_HZ), BHRCU (NUMA-bimodal).

---

## Control Flow & CPU Instruction Maximization

**Branchless Execution:** Mispredict costs 15–20 cycles on 20+ stage pipelines. Replace conditionals with arithmetic masks, cmov/select, or lookup tables for small domains (≤256). Outline all error paths to cold blocks — never mix validation with hot compute.

**Branch Layout:** Mark cold paths with `@branchHint` in Zig. Hot path must fall through; cold path jumps away. TAGE predictors are >95% accurate, but I-cache density matters more for front-end bound workloads.

**Loop Unrolling & Vectorization:** Unroll by SIMD width (4×/8×/16×). Eliminate loop-carried dependencies. Use unsigned induction variables to avoid overflow-check barriers. Scalar epilogue for tails.

**SIMD Multi-Arch & Fallback Discipline:** Every SIMD kernel must have a scalar fallback — CPUID feature flags are checked at runtime, not compile time. Dispatch through a function pointer table or comptime-select: AVX-512 → AVX2 → SSE4.2 → scalar. This guarantees correctness on bare metal, CI runners (no AVX-512), and cloud instances with varying SKUs. Use Zig's `comptime` to generate each variant from the same logic template; the scalar fallback must be exercised in CI. Never `@setRuntimeSafety(false)` in SIMD paths without the scalar fallback also tested.

**Inlining & Monomorphism:** Indirect calls block inlining. Sort arrays by concrete type before processing. Tagged unions with switch dispatch over virtual dispatch. Zig's `anytype` monomorphizes per call site.

**Cache-Oblivious Traversal:** Tile for L1 (32–64 KB), traverse in Morton/Z-order. Matrix ops: 4×4 or 8×8 register blocks. Target >2 FLOPs/byte to stay compute-bound.

**Store Buffers:** Fill store buffers with aligned contiguous stores to trigger write-combining. Scattered stores drain the buffer. Non-temporal streaming stores bypass cache for write-once data.

**ISA-Specific:**
- **x86:** AVX10.1/10.2 (converged vector, FP8, BF16), APX (16 new GPRs, 3-op encoding), FRED (fast event delivery, replaces SWAPGS), AMX (tile matrix), MOVDIR64B (64-byte WC store), UIRET (user-interrupt), CLDEMOTE, PREFETCHIT0/1, UMWAIT/UMONITOR (user-space MWAIT), SERIALIZE, RDTSCP.
- **ARM64:** SVE/SVE2 (128–2048 bit scalable vectors, predicates, gather/scatter), SME/SME2 (streaming matrix, outer-product), MTE (memory tagging), PAuth (pointer auth), BTI (branch target), GCS (shadow stack, 6.13+), FEAT_WFxT (timed WFE), FEAT_SEV (cross-core event).
- **RISC-V:** V extension (VLEN-agnostic vectors), Zb* (CLZ, CTZ, POP, min/max, rev8, CMUL), Zk* (crypto), Zicond (conditional select), Zawrs (reservation-set wake), N extension (user interrupts).

---

## Memory Allocator & Kernel Exploitation

**Zero-Allocation Hot Paths:** Heap allocation introduces locking, fragmentation, and (in GC'd runtimes) scan pauses. Pre-allocate all containers, pools, and working buffers at init. Object pools with intrusive free-lists eliminate per-element metadata.

**Arena Allocators:** Single monolithic buffer, O(1) bump allocation, entire arena freed at once. Zig provides `ArenaAllocator` and `FixedBufferAllocator` directly. Bound subsystem lifetimes to arena reset points.

**Huge Pages:** 4 KB pages thrash TLB (64–128 L1 entries). Use 2 MB or 1 GB pages to collapse page table depth. Enable via `MAP_HUGETLB`, `vm.nr_hugepages`, or `memfd_create` + `MFD_HUGETLB`. Align heaps to huge page boundaries.

**THP Control:** `madvise(MADV_HUGEPAGE)` on known-large allocations — never use system-wide `always`. DAMON `damos_hugepage` (6.14+) dynamically collapses/splits THPs by access pattern. `MADV_NOHUGEPAGE` on stacks and sparse data.

**Prefetching:** `@prefetch` in Zig 8–16 lines ahead. Structure loops linearly so hardware prefetcher recognizes stride. Don't prefetch data already in cache. Prefetch write destinations to establish ownership.

**Zero-Copy I/O:** Memory-mapped files, `sendfile`, `splice`, io_uring, XDP/DPDK — eliminate kernel-to-user copies. Each copy burns memory bandwidth and pollutes caches.

**Process vs Thread:** Threads share address space (zero-copy IPC) but pay synchronization on shared mutation. Processes isolate faults (one crash doesn't take down peers) but need explicit IPC (pipe, socket, memfd, io_uring). `fork+exec` ~5–50 μs. Use processes for privilege separation, threads for throughput within a trust boundary.

**Data-Plane / Control-Plane Split:** Partition program into a latency-critical data plane (I/O, dispatch, hot transforms) and a tolerant control plane (config, metrics, GC). Run data plane on isolated CPUs (`isolcpus`, `nohz_full`, `rcu_nocbs`) with SCHED_FIFO. Communicate via lock-free rings or io_uring MSG_RING. Never let control work preempt data work.

**Eventfd / Timerfd / Signalfd / Pidfd:** FD-based event primitives that integrate with epoll/io_uring — no signal handlers needed.
- **eventfd:** Counter fd, replaces pipe-based wakeup. Single fd, lower overhead. `EFD_SEMAPHORE` for counting-semaphore semantics.
- **timerfd:** Timer expiry as fd readability. Integrates with epoll/io_uring — no separate timer thread or signal timers. `TFD_TIMER_ABSTIME` for skew immunity.
- **signalfd:** Signals as readable bytes. Handle SIGINT/SIGTERM in event loop without async-signal-safe constraints. Don't use for SIGSEGV/SIGBUS.
- **pidfd (5.3+):** Process handle as fd; `poll` for exit. Eliminates PID-reuse race in `waitpid`/`kill` patterns.

**SO_BUSY_POLL (4.5+):** Spin on NIC RX queue instead of sleeping. Drops latency from interrupt path (~10–50 μs) to spin-then-poll (~1–5 μs). Trade-off: burns a full core during idle. Use only when tail latency matters more than power.

**SO_REUSEPORT + BPF:** Multiple sockets on one port; kernel distributes via hash/round-robin/BPF. Attach BPF for custom steering (src IP, cgroup). Shards accept across threads without a single accept bottleneck. Combine with `SO_ATTACH_REUSEPORT_EBPF` for sockmap redirection.

**SO_INCOMING_CPU (4.6+):** Returns CPU that last processed the socket. After `accept`, pin to that CPU to eliminate cross-core cache bouncing for connection state.

**TCP Low-Latency:**
- **TCP_NODELAY:** Disable Nagle — send immediately. Mandatory for interactive/low-latency protocols.
- **TCP_DEFER_ACCEPT (2.6.15+):** Delay `accept` until client sends data. Reduces context-switch overhead for idle connections.
- **TCP_QUICKACK (2.4.4+):** Send ACKs immediately; disable delayed ACK (~40–200 ms). Combine with NODELAY for request-response.
- **TCP_FASTOPEN (3.7+):** Send data in SYN — saves 1 RTT on repeat connections. Requires cookie caching. Enable `net.ipv4.tcp_fastopen=3`.
- **TCP_SAVE_SYN / TCP_SAVED_SYN (4.13+):** Retrieve original SYN for NAT-agnostic routing decisions.
- **TCP_REPAIR (3.5+):** Take over TCP connection state for live migration/debugging.

**SO_ZEROCOPY (4.14+):** Zero-copy transmit — kernel sends user pages directly. Reduces CPU for bulk senders (64+ KB messages). Overhead: notification management, page pinning. Combine with `splice` for fully zero-copy proxy paths.

**kTLS (4.13+):** Offload TLS to kernel — avoids userspace crypto library copy+encrypt cycle. Best with NIC TLS offload (`TLS_HW_RECORD`). Single kernel copy instead of user-kernel-user. Use where TLS throughput matters more than cipher agility.

**XDP / AF_XDP (4.18+):** BPF on NIC RX path before `sk_buff`. AF_XDP socket delivers zero-copy packets via shared ring buffers to userspace. Use for >10 Gbps packet processing (DDoS, load balancers, routers). Combined with `XDP_SHARED_UMEM` for multi-process.

**GRO/GSO/TSO:** NIC aggregates/segments packets — reduces per-packet overhead 10–40%. Enable via ethtool. Disable for kernel-bypass paths (AF_XDP) where raw frames are needed.

**vDSO:** Kernel maps syscall implementations (clock_gettime, gettimeofday, getcpu, getrandom (6.11+)) into userspace. ~10–20 ns per call vs ~100 ns for a real syscall. Only way for ARM64 userspace to read `CNTVCT_EL0` without trapping.

**Membarrier (4.3+):** Issue memory barrier on all cores running threads of the calling process. Use for user-space RCU: one membarrier after pointer publish instead of per-reader acquire. `MEMBARRIER_CMD_PRIVATE_EXPEDITED` uses IPI for sub-μs delivery. Must register at startup.

**SO_TIMESTAMPING (2.6.30+):** Hardware/software packet timestamps via ancillary data. Hardware ~10 ns resolution (Intel I210+). Essential for HFT, network measurement, PTP sync.

**SO_TXTIME (5.4+):** Per-packet launch time for precise egress shaping. Kernel queues until scheduled time. Eliminates bursty transmission from timer-based pacing. Use with ETF qdisc for AVB/TSN.

**MPTCP (5.6+):** Single TCP connection striped across multiple paths/interfaces. Kernel manages subflows, failover. Userspace sees a regular socket. Use for multi-homing, seamless Wi-Fi↔cellular handover.

**io_uring Networking:** Direct async network ops without syscall per operation:
- `IORING_OP_ACCEPT` — multi-shot for N connections per SQE
- `IORING_OP_CONNECT` / `RECV` / `SEND` / `RECVMSG` / `SENDMSG`
- `IORING_OP_SEND_ZC` / `RECV_ZC` — zero-copy variants
- `IORING_SETUP_SINGLE_ISSUER` (5.19+) — lock-free single-thread submission path
- `IORING_OP_FILES_UPDATE` — dynamic fixed-file registration without closing ring
- `IORING_OP_MSG_RING` — cross-ring/cross-process signaling without shared memory

**Always prefer io_uring:** Zero-syscall submission, any I/O type, sub-μs latency, multi-shot ops. epoll is legacy — only consider for pre-5.1 kernels or when io_uring setup is impossible. AIO is broken and must never be used.

**process_vm_readv/writev (3.2+):** Cross-process memcpy via kernel — no ptrace or /proc/pid/mem. ~3–5 μs/page pinning cost. Use for debuggers and snapshotting. Prefer shared `mmap` for trusted high-throughput IPC.

**Unix Domain Sockets & memfd:**
- **SOCK_SEQPACKET:** Reliable, ordered, message-boundary-preserving. No framing needed for RPC.
- **SCM_RIGHTS:** Pass fds between processes via `sendmsg`. Receiver gets a new fd to the same kernel object.
- **memfd_create + seals:** Anonymous fd shared via SCM_RIGHTS. Seal with `F_SEAL_SHRINK|GROW|WRITE` for immutable configuration.

**mlock / mlockall:** Wire pages to RAM — prevents page faults on SCHED_FIFO threads and crypto key material. Bounded by `RLIMIT_MEMLOCK`. Combine with `MADV_WILLNEED` for pre-faulting.

**KSM (2.6.32+):** Kernel de-duplicates identical anonymous pages. Enable candidate regions with `MADV_MERGEABLE`. Use for VM hosting and read-mostly caches where many copies of the same data exist. Trade-off: CPU cost of scanning; disable on latency-sensitive servers.

**zswap / zram:** Compressed in-memory swap. zswap intercepts swap-out, compresses (lz4/zstd/lzo), stores in memory pool — reduces swap I/O 60–90%. zram creates a compressed RAM block device — effective memory multiplier (2–3×). zstd for ratio, lz4 for speed.

**Memory Compaction:** Defragment physical memory before large allocations by writing to `/proc/sys/vm/compact_memory`. Monitor via `/proc/buddyinfo`.

**madvise Flags Summary:**
- **RANDOM/SEQUENTIAL/NORMAL:** Read-ahead policy — RANDOM disables (2-page max), SEQUENTIAL doubles (256-page).
- **WILLNEED:** Pre-fault pages = read without data copy.
- **DONTNEED:** Drop pages immediately (synchronous). **FREE (4.5+):** Lazy drop (cheaper, deferred under pressure).
- **REMOVE:** Punch hole in shared memory (like fallocate for mmap).
- **DONTFORK:** Exclude from child after fork. **WIPEONFORK:** Zero on fork (secrets).
- **COLD/PAGEOUT (5.4+):** De-prioritize / immediately swap out.
- **MERGEABLE/UNMERGEABLE:** KSM control.
- **HUGEPAGE/NOHUGEPAGE:** THP per-VMA.
- **POPULATE_READ/POPULATE_WRITE (5.14+):** Synchronous page table population — deterministic startup.
- **COLLAPSE (6.1+):** Synchronously collapse 4K→2M. For databases that benefit from huge pages but can't use MAP_HUGETLB.

**Huge Page Types:**
- **PMD — 2 MiB:** Default THP size. A L2 TLB (1024 entries) covers 2–4 GiB. `MADV_HUGEPAGE` or `MAP_HUGETLB`.
- **PUD — 1 GiB:** Requires `CONFIG_PGTABLE_LEVELS=5` or `hugepagesz=1G`. Single TLB entry maps 1 GiB. For massive heaps and caches. ARM64 supports 2 MiB (contiguous hint) and 1 GiB.

**OOM Control:**
- **oom_score_adj (-1000 to +1000):** `-1000` makes process immune to OOM killer; `+1000` marks sacrificial processes.
- **memory.oom_group (6.0+):** Kill all tasks in cgroup atomically. Prevents orphaned shared memory on partial kill.
- **PSI proactive OOM:** Poll `/proc/pressure/memory` threshold — kill caches before kernel OOM fires.
- **oomd / systemd-oomd:** Userspace OOM managers using PSI.

**waitid with WNOWAIT (5.4+):** Non-destructive child status query. Child stays zombie until regular `wait`. Avoids `kill(pid,0)` TOCTOU race.

**prctl Operations:**
- `PR_SET_TIMERSLACK`: Timer coalescing slack. 0 for precise timers, default 50 μs for power saving.
- `PR_SET_NAME`: Thread name for `ps`/`htop` identification in production profiles.
- `PR_SET_NO_NEW_PRIVS`: Irrevocably block privilege escalation. Must precede seccomp.
- `PR_CAP_AMBIENT`: Raise ambient capabilities for execve survival.
- `PR_SET_PDEATHSIG`: Signal on parent death — worker self-termination. Race: check `getppid()` after setting.

**io_uring Core (kernel 7.1 as of mid-2026):**
- **Non-circular SQ/CQ (7.0):** Cache-contiguous submission/completion queues — fewer cache misses, ~5–10% throughput gain for large rings.
- **Ring resizing (6.13):** Grow SQ/CQ rings at runtime — start small, resize under load. Avoids over-provisioning for bursty workloads.
- **Fixed wait regions (6.13):** Pre-register wait data — eliminates per-`io_uring_enter` copy of wait arguments.
- **Hybrid IO polling (6.13):** Initial sleep delay before spinning — reduces CPU waste on slow devices.
- **FUSE over io_uring (6.14):** FUSE daemon communicates via io_uring — userspace filesystem performance approaches kernel-native.
- **IOPOLL per-op:** Mixed polling/non-polling in same ring.
- **BPF struct_ops loop:** Event loop as BPF attached to io_uring — no context switch.
- **Zero-copy recv (zcrx):** NIC DMA → user-registered buffers. Multi-area refill queues.
- **Zero-copy send (zctx):** Unified `send_zc`/`sendmsg_zc` with separate notification CQEs.
- **Fixed buffers/files:** Register once — kernel pins pages, no per-I/O GUP cost. Mill+ IOPS per core.
- **Ring coalescing:** `IORING_SETUP_COOP_TASKRUN` / `DEFER_TASKRUN` for batching.
- **Advanced ops:** `IORING_OP_URING_CMD` (NVMe), `MSG_RING` (multi-ring), `PROVIDE_BUFFERS` (pool recycling).

**Storage Zero-Copy:**
- **sendfile:** File→socket via page cache. No userspace buffer.
- **splice:** Pipe-mediated fd→fd with page references. `SPLICE_F_MOVE`/`GIFT`/`ZC`.
- **copy_file_range:** In-kernel file copy; reflink on COW fs (Btrfs/XFS). Microsecond copies regardless of size.
- **fallocate:** Pre-allocate, punch holes, zero ranges, collapse/insert. Prevents fragmentation for write-heavy sequential workloads.
- **O_DIRECT vs buffered:** Bypass page cache for sync DB-style writes. Requires 512B/4K alignment. Benchmark per device.
- **FICLONERANGE:** Extent deduplication within same file. Instant regardless of size.

**Project-Wide I/O & Allocator Strategy:**

**Allocator Per Phase, Not Per Allocation:** Classify each subsystem's allocation pattern and pick the allocator once:
- **Startup/Config:** General-purpose heap (`page_allocator` or `c_allocator`). Few allocations, no perf requirement.
- **Request Parsing:** `FixedBufferAllocator` over a pre-sized stack buffer — zero heap for common-case messages. Fall back to arena for oversized.
- **Request Lifetime (query, result, serialization):** One `ArenaAllocator` per in-flight request, created on arrival, reset on response. All intermediate allocations (parsed SQL AST, result rows, JSON, temp working buffers) live here. No per-allocation tracking.
- **Connection Pools:** Pre-allocated array of connection structs at startup. Checkout/checkin = atomic index CAS — zero allocation.
- **Hot Plumbing:** No allocator at all. Read from io_uring fixed buffers directly into response writer.

**Arena Reset Boundaries:** Map arena lifetimes to natural protocol units: accept, process each request (arena reset between requests), close. Use `ArenaAllocator.reset(.retain_capacity)` — keeps the backing buffer mapped across requests, only bumping the pointer back. Reuses the same pages without `mmap`/`munmap` per request.

**I/O Abstraction Strategy:** Pick one I/O model per project and abstract only the completion path, not the submission. Keep submission thin (one function call per I/O op). Do NOT model I/O as `async`/`await` or callback chains unless you also own the event loop — those leak control flow and make buffer ownership unmanageable.

**Buffer Ownership Rule:** The layer that allocates an I/O buffer owns and frees it. For io_uring fixed buffers: register at connection open, recycle via `IORING_OP_PROVIDE_BUFFERS`. For one-shot reads: the request arena owns the buffer; it dies with the arena reset.

**Hardware Affinity:** Pin threads to physical cores to preserve L1/L2 warmth. Avoid SMT siblings for cache-bound workloads. Offload parallel compute to GPUs/accelerators via direct user-space interfaces.

**eBPF for Performance:**
- **Program cost hierarchy:** Prefer `fentry`/`fexit` (~30 ns) over `kprobe`/`kretprobe`.
- **Map selection:** `BPF_MAP_TYPE_RINGBUF` for per-CPU event delivery; `PERCPU_ARRAY` for per-CPU temp buffers; `ARENA` (6.11+) for kernel-BPF-user shared address space.
- **Tail calls:** Chain up to 33 BPF programs — use for protocol dispatch in XDP.
- **BPF struct_ops:** Kernel callbacks as BPF programs (sched_ext, io_uring). No context switch.
- **EPSO (2025):** BPF superoptimizer — ~24% program size reduction, ~6.6% runtime improvement, 88% less optimization overhead vs K2.
- **Fast path offload:** Deploy common path as BPF (ingress allowlist); rare events via ringbuf to userspace.

---

## Compiler & Runtime Optimization

**CSE & GVN:** Compiler reloads memory if aliasing is possible. Hoist lengths, invariants, and repeated lookups into locals before loops. Never read array length inside a loop body.

**Loop Unswitching:** If a loop invariant conditional exists, branch first and write two specialized loops. Increases code size but guarantees clean I-cache and branchless inner path.

**Cold-Path Outlining:** Error handling in hot blocks pollutes I-cache. Branch immediately to a separate cold function for edge cases. Keeps instruction cache dense with pure compute.

**Scalar Replacement:** Compiler dissolves structs into register-backed locals. Pass stays compact. If address is taken or object escapes, pass aborts — destructure immediately.

**Loop Strength Reduction:** Replace `base + i * stride` with `ptr += stride`. Power-of-two sizing turns modulo into AND. Use unsigned induction variables to avoid overflow-check barriers.

**Alias Analysis:** Nested mutations like `total += items[i].val` force reload on every iteration (compiler can't prove `items` unchanged). Localize accumulator to stack, apply after loop.

**Superword-Level Parallelism:** Loop-carried dependencies kill auto-vectorization. Ensure iteration *i* doesn't depend on *i-1*. Avoid mixing data sizes (16-bit + 64-bit) in same SIMD block.

**Register Pressure & Loop Fission:** >4–5 array updates per loop body causes register spill to stack. Split into multiple sequential loops — more passes but each fits in registers.

**Devirtualization:** One concrete type at a call site enables inlining. Sort/bucket data streams by concrete type before processing. Never mix different implementations in the same array.

**Linker & Binary Layout:**
- **BOLT (LLVM, upstream):** Post-link optimizer reorders blocks/functions via perf samples. 10–30% speedup on front-end bound workloads. Splits hot/cold code, clusters functions by call graph.
- **Propeller (Google, LLVM 19+):** Relinking optimizer using basic-block sections. 1–8% on top of PGO+ThinLTO. 30–70% lower memory than BOLT. Better for distributed builds.
- **Function splitting:** Compiler emits `.text.hot` and `.text.cold`. Keep I-cache dense.
- **ICF:** Linker merges identical functions across TUs — 10–20% .text reduction.
- **`--gc-sections`:** Dead-strip unreferenced sections. Use `-ffunction-sections -fdata-sections`.
- **ThinLTO:** Cross-module inlining, constant propagation, dead stripping. Combined with PGO: 5–15% uplift.
- **PLT/GOT:** `-Wl,-z,now` (resolve at load, no lazy binding), `-z,relro` (read-only GOT after relocation), `--hash-style=gnu` (faster lookup).

---

## Power & Thermal Optimization

**RAPL (Intel/AMD):** Read per-package and per-DRAM energy in μJ via `/sys/class/powercap/`. Use for DVFS based on energy budget. Monitor with `turbostat`.

**EAS (5.0+):** Scheduler places tasks on most energy-efficient CPU using Energy Model. Works on big.LITTLE/hybrid with `schedutil` governor.

**Intel Speed Shift (HWP, Skylake+):** Hardware-managed P-states. Set `energy_performance_preference` hint — use `balance_performance` or `performance` for latency-sensitive work.

**C-states:** Deeper C-states (C6/C7/C8) save power but add 100+ μs wake latency. Set `pm_qos_resume_latency_us` tolerance. Disable deep C-states for network-heavy workloads to avoid interrupt coalescing latency. Tune with `powertop`.

**Idle Injection:** Force idle cycles for thermal capping without frequency throttling.

---

## Sandboxing & Isolation

**seccomp-bpf (3.5+):** BPF filter at syscall entry. Actions: ALLOW, KILL_PROCESS (4.14+), KILL_THREAD, TRAP, LOG. Whitelist by syscall number; blacklists are fragile. `SECCOMP_FILTER_FLAG_TSYNC` for thread-sync.

**seccomp User Notification (5.6+):** Intercept specific syscalls, forward to userspace supervisor via `SECCOMP_RET_USER_NOTIF`. Child blocks until supervisor responds. Use for resource accounting, network policy, /proc virtualization.

**seccomp NEW_LISTENER (5.0+):** `SECCOMP_FILTER_FLAG_NEW_LISTENER` returns an fd for the notify channel. Trusted supervisor installs filter in untrusted worker and monitors from separate thread. Prevents filter bypass.

**Ambient Capabilities (4.3+):** Capabilities that survive `execve`. Raise before dropping `CAP_NET_RAW`/`CAP_NET_ADMIN`. Combine with `PR_SET_NO_NEW_PRIVS` to harden seccomp/Landlock.

**Landlock LSM (5.13+):** Unprivileged file + network access control. ABI v4: TCP port rules; v5: UDP; v6: IPC scoping (abstract Unix sockets, 7.1: pathname Unix domain sockets). No root required. Compose with seccomp + mseal for defense-in-depth.

**cgroup v2:** Resource limits per process group. Controls: `memory.max` (hard), `memory.high` (soft), `cpu.max` (quota), `io.max`, `pids.max`, `cgroup.freeze`. PSI per-cgroup for proactive scaling.

**Namespaces:** `CLONE_NEWUSER` + `NEWNS`/`NEWNET`/`NEWPID`. Combine with `pivot_root` for filesystem jail. `unshare` for lightweight isolation without fork. `setns` to join existing namespaces.

**mseal (6.10+):** Lock VMA permissions. Composes with Landlock (file/network) + seccomp (syscalls) for full defense depth.

---

## Scheduling & CPU Topology

**EEVDF (6.6+):** Default scheduler replacing CFS. Virtual deadline based, better latency for latency-sensitive tasks. Works with deadline servers (6.8+) for bounded RT starvation.

**sched_ext / SCHED_EXT (6.12+, sub-scheduler in 7.1):** Custom scheduling policies as BPF programs loaded at runtime. DSQs: per-CPU local, global FIFO, user-created. Meta and Google in production. Sub-scheduler (7.1): each cgroup runs its own scheduler. Safe fallback to fair scheduling on crash.

**SCHED_FIFO / SCHED_RR:** Real-time. FIFO runs until yield/block — sub-100 μs response. RR adds time slice per priority. Priority 1–99. **Critical:** buggy FIFO can lock system — always set `RLIMIT_RTTIME` and use watchdog threads.

**PREEMPT_RT (6.12+):** Fully preemptible kernel — bounded latencies <50 μs even under load. After 20 years of development. `CONFIG_PREEMPT_RT` build option. **hrtimer rewrite (7.1):** Scheduler uses high-res timers with no performance loss vs coarse timers — sub-μs timer resolution for wake-up decisions.

**SCHED_DEADLINE (3.14+):** EDF scheduling with budget enforcement. Bounded latency. `SCHED_FLAG_DL_OVERRUN` (6.13+) for overrun signaling.

**SCHED_BATCH / SCHED_IDLE:** BATCH: large timeslices, less frequent wakeups — CPU background compute. IDLE: runs only when CPU would be idle — background reclamation, cache warming, housekeeping.

**CPU Isolation:** Reserve cores for dedicated use:
- `isolcpus=` — remove from scheduler load balancer.
- `nohz_full=` — disable scheduler ticks on isolated cores when single task running. Eliminates ~4 ms periodic jitter.
- `rcu_nocbs=` — offload RCU callbacks to housekeeping CPU.
- `irqaffinity=` — bind all IRQs to housekeeping CPUs.
- Reserve 2–4 housekeeping cores; measure isolation with `cyclictest` or `oslat`.

**Capacity Awareness (big.LITTLE/hybrid):** CPU capacity from `/sys/.../cpu_capacity`. Pin latency-critical threads to high-capacity cores (P-cores), background to E-cores.

**cpuset cgroup v2:** Partition CPUs into exclusive sets for latency-critical workloads. Prevents interference.

**NUMA balancing control:** `sysctl kernel.numa_balancing=0` for deterministic placement. Monitor via `/proc/self/numa_maps` and `/proc/vmstat`.

---

## Linux Performance Telemetry

**Intel PT (4.2+):** Hardware branch trace (~1 bit/branch). Use `perf record -e intel_pt//`. Drawback: ~100 MB/s/core data volume.

**PEBS:** Precise event-based sampling — no skid. **Timed PEBS (TPEBS, 6.12+):** Logs instruction retirement latency (Meteor Lake+). Use for Top-down Microarchitecture Analysis (TMA).

**LBR:** Ring buffer of last ~32 branches. **Architectural LBR (5.18+):** XSAVES context-switch compatible. **LBR Event Logging (6.12+):** PMU event data inside LBR for simultaneous branch + precise sampling.

**perf_event_open:** Programmatic PMU access. Ring-buffer samples with configurable data (IP, TID, time, regs, stack, cgroup). Adaptive sampling via `ioctl(PERF_EVENT_IOC_PERIOD)`.

**eBPF Tracing:**
- **fentry/fexit (6.6+):** Lowest overhead (~30 ns). Prefer over kprobes.
- **kprobes:** Dynamic, higher overhead. **tracepoints:** Stable ABI, lower overhead.
- **USDT:** Userspace probes in binaries.
- **bpftrace:** One-liner language for dynamic tracing.
- **BCC:** Python tooling: biosnoop, biolatency, offcputime, runqlat, memleak, etc.

**ftrace:** Built-in function tracer. `trace-cmd` / `kernelshark` frontends. Hist triggers (4.19+) for in-kernel histograms. Latency tracers (irqsoff, preemptoff, wakeup).

**LTTng:** Kernel + userspace tracing, sub-μs overhead. CTF format for Trace Compass.

**DAMON (5.15+):** Data access monitoring + DAMOS actions: THP collapse/split, proactive swap, LRU sorting, CXL tiering. TPP-DAMON (6.16+): multi-threaded tiered page placement for RAM+CXL — 94% improvement on llama.cpp.

**PSI (4.20+):** `/proc/pressure/{cpu,memory,io}` — `some` vs `full` stall percentages. Poll-based triggers for proactive autoscaling and OOM prevention.

**Process files:** `/proc/self/smaps` (per-VMA RSS/PSS/THP), `smaps_rollup` (aggregate), `numa_maps`, `/proc/schedstat`, `/proc/stat` (CPU breakdown), `/proc/vmstat` (memory counters).

---

## Zig-Specific Optimization Patterns

**`comptime` metaprogramming:** Pre-compute tables (sin, CRC, primes) at compile time — zero runtime cost.

**`inline for`:** Unroll fixed-size loops at compile time. Zero loop overhead.

**`comptime_int` / `comptime_float`:** Arbitrary precision at compile time; coerce to optimal runtime type.

**`@typeInfo`:** Full type reflection — build state machines, serializers, protocol parsers without macros or codegen. (`@Type` removed in 0.16; use `@Int`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple`, `@EnumLiteral` instead.)

**`@compileLog` / `@compileError`:** Enforce invariants (alignment, power-of-two, range) at compile time.

**Custom allocator pattern:** Pass `Allocator` everywhere. Arena, FixedBuffer, StackFallback — chosen at call site with zero-cost abstraction (vtable resolved at comptime).

**`anytype`:** Monomorphized per call site — concrete, inlineable. Only explicit instantiations are emitted (unlike C++ templates).

**`@setRuntimeSafety(false)`:** Disable safety checks in proven-hot inner loops. Re-enable at function boundaries.

**`extern struct` / `packed struct`:** Wire-format layouts. `@bitCast` for zero-copy reinterpretation.

**`@field` / `@fieldParentPtr`:** Intrusive containers — navigate from field to parent without storing parent pointer.

**`@alignOf` / `@offsetOf` / `@sizeOf`:** Query layout at comptime for manual cache-line padding and field offset arithmetic.

**`errdefer`:** Deallocate on error without explicit cleanup. Hot path stays branch-free.

**`defer` + arena.reset:** Arena lifetime tied to request scope. No per-allocation tracking. `.retain_capacity` reuses backing storage.

**`@export`:** Override `c_allocator` with custom arena for entire program.

**`@embedFile`:** Binary blobs in `.rodata` at compile time — zero runtime I/O for static data.

**`comptime` string processing:** Parse configs/schemas at compile time — zero runtime parsing.

**`@tagName` / `@enumFromInt` / `@intFromEnum`:** Integer-enum dispatch → jump table or bitmask test. Not string comparison. `inline else =>` for exhaustive handling.

**`@setCold`:** Outline cold branches to separate `.text` region. Keeps hot I-cache dense.

**`@call(.never_inline)` / `callconv`:** `@call(.inline)` forces inlining; `.never_inline` for cold paths. `callconv(.C)`, `.Stdcall`, `.Naked` (no prologue), `.Cold` (function-wide cold hint).

**`@setFloatMode(.Optimized)`:** Enable fast-math (FMA, reassociate, ignore NaN). Wrap hot numeric kernels. Revert to `.Strict` at module boundaries.

**`@optimizeFor(.size)`:** Tune cold error paths for size, hot loops for speed. Overrides global `-O`.

**`@fence` / `@cmpxchg*` / `@atomicLoad` / `@atomicStore` / `@atomicRmw`:** Low-level memory ordering. `@fence(.acquire)` / `(.release)` / `(.acq_rel)` / `(.seq_cst)`. `@cmpxchgWeak` for CAS loops (may spurious-fail); `@cmpxchgStrong` for single-shot CAS. `@atomicRmw` ops: Xchg, Add, Sub, And, Or, Xor, Min, Max. Prefer over `std.atomic.Value` for precise ordering.

**`@clz` / `@ctz` / `@popCount`:** Hardware CLZ/CTZ/POPCNT — single-cycle on modern cores. Bitmap scan, next-power-of-two, work-stealing idle-thread discovery.

**`@byteSwap` / `@bitReverse`:** `bswap`/`rev` for endian conversion; `rbit` for CRC/FFT bit permutations. Single instruction on x86/ARM64.

**`@addWithOverflow` / `@subWithOverflow` / `@mulWithOverflow` / `@shlWithOverflow`:** Arithmetic returning `{result, overflow}`. Branchless saturating math via `result -% overflow_flag`. On x86: `add; seto` merged into cmov.

**`@divExact` / `@divFloor` / `@divTrunc` / `@rem` / `@mod`:** Explicit division semantics. `@divExact` enables multiply+shift strength reduction. `@mod` for correct cyclic indexing with negative values.

**`@shlExact` / `@shrExact`:** Shifts requiring zero bits shifted out. Compile error if unprovable. Use on unsigned power-of-two division for guaranteed no rounding.

**`@truncate`:** Integer truncation without overflow check. Use when high bits known zero from mask. Avoids bounds check in release-safe.

**`@alignCast`:** Cast pointer to stricter alignment. Enables aligned loads (`movaps`) for vector code. UB if runtime alignment insufficient.

**`@ptrFromInt` / `@intFromPtr`:** Integer↔pointer round-trip. Tagged pointers, MMIO access, pointer-offset arithmetic. Purely numerical — unlike `@ptrCast`.

**`@floatCast` / `@intFromFloat` / `@floatFromInt`:** Float/int conversions. `@intFromFloat` truncates toward zero. Use with `@truncate` for float→bitfield extraction.

**`@shuffle` / `@reduce` / `@vector`:** SIMD builtins. `@vector(len, T)` creates vector type. `@shuffle(a, b, mask)` → lane permutation. `@reduce(.Add, v)` → horizontal reduction. Write explicit SIMD without inline asm.

**`@memcpy` / `@memset`:** Compiler-recognized memory ops — can lower to `rep movsb`, inlined register moves, or scalar loops. Prefer over `std.mem.copy` in hot paths.

**C Interop (`@cImport` or translate-c):** Two paths in Zig 0.16. The newer approach: write a C umbrella header referenced by `exe.root_module` in `build.zig`, then `@import("c")` in source — no inline `@cImport` block. The older `@cImport` / `@cInclude` / `@cDefine` still works but is deprecated. Both use Clang under the hood: macros and `#ifdef` resolved at comptime, bindings callable as regular Zig with zero overhead.

**`@hasDecl` / `@hasField`:** Comptime capability check — adapt generics to optional type methods.

**`@typeName`:** Human-readable type name in `.rodata`. Zero cost if unused (DCE'd). Tag arenas, debug logging, serialization.

**`@unionInit(UnionType, "tag", payload)`:** Initialize tagged union in one expression. Tag validated at compile time.

**`@trap`:** Hardware trap (`ud2`/`udf #0`). For fundamental unreachability. Compiler treats as `noreturn` — no return path emitted.

**`@returnAddress` / `@src` / `@errorReturnTrace`:** Stack introspection. `@returnAddress()` for custom unwinders/profilers. `@src()` → file+line+col, DCE'd if unused. `@errorReturnTrace` for error-return traces (Debug mode).

**`Io.async` / `Io.concurrent` / `Future(T)`:** Task-level concurrency. `io.async(fn, .{args})` returns `Future(T)`. `.cancel()` releases task resources. `Io.concurrent` signals must-be-concurrent; can fail `error.ConcurrencyUnavailable`. Grouped via `Io.Group.async` for scatter-gather. Old `@Frame`/`@asyncCall`/`@suspend`/`@resume`/`@await` builtins removed in 0.16.

**`@extern`:** Reference symbol by name without C header. Weak overrides, lazy binding, custom linker scripts.

**`threadlocal`:** ELF `.tbss`/`.tdata`, accessed via `fs`/`gs` segment — single instruction, no locking. Combine with `@export` for C interop.

**`[:0]T` (sentinel-terminated):** Zero-copy C-string compatible. Type system guarantees null terminator at `ptr[len]`. Use for all POSIX/C interop.

**`This` keyword:** Refers to enclosing struct type at monomorphization. Method chaining with correct return type for generics.

**Comptime Discipline — When & How (Not Over-Engineering):**

**Do use comptime for:** precomputing lookup tables (CRC, sin/cos, prime sieves), resolving allocator and backend choices at build time, validating type constraints, generating protocol parsers from schema, stripping debug-only branches that must not exist in release builds. Each of these eliminates runtime work that would otherwise be wasted cycles or branches.

**Don't use comptime for:** replacing runtime configuration (that's what CLI args and config files are for), building general-purpose metaprogramming frameworks, generating code for every possible type combination "just in case," compile-time string templating engines, or comptime reflection wrappers that look like a dynamic language's eval. These turn Zig into a worse Lisp with slower compile times.

**Signal you're over-engineering with comptime:** you're writing `comptime` blocks longer than the runtime code they generate; you have comptime recursion deeper than 3 levels; you're using `@typeInfo` to build a generic serialization framework "for future use" when today you have exactly one wire format; you're allocating at comptime (comptime heap usage). The best comptime code is invisible — it reads like straight-line runtime code and happens to evaluate at compile time because the inputs are known.

**Pattern: comptime for narrowing, not for branching.** Write one generic function parameterized by an enum or type, then let the comptime dispatch collapse to the right implementation. This generates N concrete functions — one per format type used in the binary — with zero dispatch overhead. But don't do this if you only have one format; just write the concrete function.

**Pattern: comptime for pre-validation.** Enforce invariants at compile time that would be runtime panics otherwise. Zero runtime cost, catches misconfiguration at `zig build`, not in production.

**When to reach for runtime over comptime:** configuration that changes per deployment (connection strings, pool sizes, listen addresses), data-dependent dispatch (routing queries by table name), hot paths where the comptime evaluation itself would delay compilation for marginal runtime gain. Rule of thumb: if the answer changes when you restart the binary without recompiling, it's runtime.

---

## Memory Safety, Exploit Mitigation & Correctness Discipline

**Core principle:** every untrusted byte (URL, SQL input, JSON payload, connection-string parameter) is an exploit primitive. A Zig server that accepts text-in, text-out with credentials in the middle must treat each parser boundary as an attack surface.

In Zig's safety model, **memory errors are not a separate category from logic errors** — an out-of-bounds write is an incorrect index computation; a use-after-free is a dangling borrow at the type level. Every bug is a potential memory corruption.

---

### Buffer Overrun & Underread

**String parsers** that slice out of input using `findScalar` and manual range arithmetic must return borrows of the original input. The invariant: every output slice address range must fall within the input's address range. Progressive narrowing (`rest[i+1..]`) is correct as long as each reassignment strictly shrinks the slice. Off-by-one errors are the most common source of overread.

**Serialization writers** that iterate byte-by-byte must handle variable-length input. Fixed-size stack buffers silently truncate when the output exceeds capacity. Rule: never use fixed buffers with untrusted-sized input; prefer allocating writers for variable payloads. Always check the return value of write calls.

**Secrets in process memory** — connection strings containing passwords persist in heap/stack after parsing. Zeroing before free (`std.crypto.utils.secureZero`) prevents credential recovery from core dumps or /proc/self/mem. Arena-backed secrets must be zeroed before arena reset, not just before individual free.

---

### Use-After-Free & Double-Free

**Arena-borrowed references** must not escape the arena's lifetime. Request-scoped allocations (parsed AST, result rows, serialized output) live in a per-request arena reset at end of request. Any reference stored in a global, cached in a connection struct, or returned to the caller outside the arena scope is a use-after-free. Double-free is structurally impossible with arenas (no individual free), but mixing arena allocations with manual heap free creates the risk.

**C library interop** requires discipline: opaque handles from C init functions must be freed with the C destructor, never with Zig's allocator. The pattern: `errdefer` after init, `defer` after successful init. Missing cleanup leaks both memory and file descriptors.

**Object pool free lists** that track reusable resources must drain all entries on close. If the pool is closed while resources are still checked out, those resources become leaked (resource leak, not memory corruption). If the pool's backing memory is freed while checkouts hold pool-owned references, that is use-after-free.

---

### Integer Overflows & Truncation

**Port/numeric parsing** must validate that parsed integers fit their target type. `parseInt` returns `error.Overflow` for out-of-range values. Silently falling back to a default on overflow is safe but silent — the caller may connect to an unexpected port rather than receiving an error. For production systems, propagate the overflow error.

**Length validation** should compare against bounds before any arithmetic. Simple `if (len > MAX_LEN)` comparisons are trivially safe. Any multiplication or addition on user-controlled length before a bounds check is an integer overflow waiting to happen.

**Arena capacity** tracking is safe by construction (pointer bump + end-of-buffer comparison, no arithmetic on user input).

---

### Null Pointer Dereference & Unchecked Optionals

**Optional fields** (e.g., nullable user/pass/host/db in parsed URLs) must be checked before unwrapping. Every downstream consumer must use `orelse` for defaults rather than assuming presence. The pattern `field orelse default` is safe; `field.?` is a crash on null.

**Nullable complex types** (optional rows, column metadata) must gate iteration on null checks before access. The dispatcher should branch on null to select the output path.

**Post-deinit access** to pooled structures is use-after-free. A deinitialized `ArrayList` sibling (e.g., free list) whose backing memory is freed but struct is not zeroed becomes a dangling pointer on the next `.items` access.

---

### Command Injection

**SQL injection defense** must enforce:
- Prefix validation (SQL must start with an allowed keyword: SELECT/INSERT/UPDATE/DELETE)
- Multi-statement rejection (unquoted semicolons are forbidden)
- Proper string escaping (doubled quotes, doubled backticks, NUL dropped)
- Comment awareness (skip `--` and `/* */` before checking for semicolons)

Remaining risk: prefix check only validates the *first word*. Statements like SELECT with INTO OUTFILE pass validation despite performing writes. For read-only tools this is acceptable; for general query engines, more rigorous statement-type enforcement is needed. The `expected_prefix` parameter must be hard-coded per handler, never attacker-controlled.

**Path traversal** is not a risk when no file I/O is performed on user-controlled paths. Environment variable reads are the only file interaction.

---

### Stack Safety & Recursion

**Iterative design** eliminates stack overflow from deep nesting. All parsers, validators, serializers, and pool logic must be iterative, not recursive.

**Fixed stack buffers** (test helpers, small fixed-size writers) must stay well within the default stack size (8 MB on Linux/macOS). Data must be consumed before the stack frame is reused.

**`@trap` guards** (`else => unreachable` on exhaustive switches) compile to hardware trap instructions — immediate crash on logic error before corruption propagates. These belong only where the switch is truly exhaustive and the `else` represents a compile-time bug, not a runtime input.

---

### Race Conditions & Data Races

**Mutex discipline:** every operation that reads or writes shared state must lock. Non-re-entrant mutexes deadlock on double-lock by the same thread — design for single-threaded event-loop usage where contention is near zero.

**Object lifetime ordering:** if object A holds a reference to object B's internal state, B must outlive A. Declare B first, defer its deinit after A. This ordering must be preserved in any refactoring. Violation: submitting I/O on a freed io_uring ring is undefined behavior.

**Data race surfaces:** unlocked reads of shared state see torn writes or stale values. All public API paths must lock. Only diagnostics/monitoring paths may read unlocked, and only if the caller tolerates stale data.

---

### Allocator Mismatch & Ownership Discipline

**Rule: the layer that allocates is the layer that frees.**
- Arena allocations: no individual free needed (arena reset frees all).
- Stack allocations: no free needed.
- Heap-allocated strings: explicit `allocator.free` matching the `allocator.dupe`/`allocator.create`.
- C library handles: freed with the C destructor (`mysql_close`, `free_result`), never with a Zig allocator.

**No shared ownership:** every value has exactly one owner at any point. The pool owns connections; the handler borrows them temporarily. The arena owns request-scoped data. The caller owns the response payload. No reference counting, no garbage collection, no shared pointers.

**Checklist for allocator mismatch:**
- Allocations from an arena: freed by arena reset, not by individual free.
- Allocations from a specific allocator: freed with the same allocator instance.
- C allocator (`c_allocator`): only for C-allocated memory, freed with C `free`.
- Returned owned slices (`[]u8`): documented as owned, caller frees with the same allocator that created them.

---

### Secret Handling in Memory

**Credentials in process memory** must be treated as sensitive. Sources: environment variables (`/proc/self/environ`), parsed connection URLs, configuration strings.

**Mitigations (proportionate to threat model):**
- Zero secrets before freeing: `secureZero(bytes)` before `allocator.free`.
- Unset environment variable after read (note: doesn't clear /proc/self/environ).
- Disable core dumps: `ulimit -c 0` or `PR_SET_DUMPABLE=0`.
- For multi-tenant: run credential-processing in a separate process, pass parsed handles via Unix sockets, isolate the process that holds secrets.

For a developer workstation threat model (no local attacker with core-dump access), zeroing before free is hardening, not a blocker.

---

### Fuzz Testing Invariants

Every pure function that processes untrusted input should have property-based fuzz tests: initialize a PRNG (`std.Random.DefaultPrng`) with a fixed seed, generate random byte sequences of varying lengths into a stack buffer, call the function under test, and discard expected errors. Verify the function does not panic, crash, or produce undefined behavior on any input.

**Coverage per function:**
- All 256 byte values (crashers: control chars, high bytes, NUL).
- Printable ASCII only (exercises normal path).
- Domain-specific prefixes (e.g., URL scheme prefix + random suffix).
- Each JSON value variant (null, bool, int, float, string) for param extractors.

**When to add:** every new function accepting `[]const u8` from an untrusted source, or every new code path in an existing parser/validator. Use `std.Random.DefaultPrng` (Xoroshiro128+) with fixed seeds for deterministic, reproducible execution. Verify the function does not panic, crash, or produce undefined behavior on any input. Add type-specific invariants where they exist (e.g., URL parser returns only expected error codes).

---

### Deploy-Time Exploit Mitigations

**Stack canaries:** enabled by default in optimized build modes (`-O ReleaseSafe`/`ReleaseFast`/`ReleaseSmall`). Checked at every function return — buffer overrun triggers `__stack_chk_fail` before the attacker controls the return address. `Debug` mode has more comprehensive safety checks (bounds, null, unwrap, cast) at higher overhead. For production: `ReleaseSafe` retains safety checks with optimizations.

**Position-independent executable (PIE):** default in modern Zig builds. Randomizes text/heap/stack base addresses. ASLR entropy on x86-64: 28 bits text, 22 bits mmap/heap, 11 bits stack.

**RELRO / BIND_NOW:** `-z relro -z now` is default for PIE. GOT becomes read-only after dynamic linking — prevents GOT overwrite. All PLT/GOT references resolved at load time (no lazy binding).

**No JIT, no W^X pages:** pages are never both writable and executable. No JIT spray vulnerability.

**C interop risk:** linked C libraries are not compiled with Zig's safety guarantees. A buffer overrun in the C library (network parser, auth handshake) can corrupt heap/stack even if the Zig code is safe. Mitigations:
- Use only well-audited, stable C libraries with decades of production use.
- Limit usage to basic client operations (connect, query, fetch, close) — avoid prepared statements, SSL renegotiation, plugin loading.
- Run in `ReleaseSafe` so Zig-allocated buffers crossing the C boundary retain bounds checking.
- For high-security deployments: isolate the C library in a separate process (microservice/sidecar) with reduced privileges, communicating via Unix sockets.

---

## Measurement & Validation

**Cross-platform testing with containers:** Use Docker or Podman to validate the binary on Linux when developing on macOS (or vice versa). Build and run inside a container matching the target OS distribution to catch platform-specific issues early:
- Build the release binary on the host, then copy it into a minimal container (`FROM scratch`, `FROM alpine`, or `FROM distroless`) to verify it links and starts correctly.
- Test against the target database (MariaDB/MySQL) running in a separate container — use `docker compose` or `podman-compose` to spin up db + app with a test-specific network.
- Validate that `zig build test` passes inside the target container, not just on the development host. Different libc versions, page sizes, and thread-local-storage layouts can surface latent bugs.
- Use multi-arch builds (`docker buildx` or `podman farm`) when targeting ARM64 from x86-64 or vice versa.
- For CI, run the full test suite in a container that matches the deployment environment: same distro, same libmariadb version, same allocator settings. This catches regressions that only reproduce under the target libc or kernel version.

**Microbenchmarking:** Use RDTSCP / CNTVCT_EL0. Pin to isolated cores, disable frequency scaling, warm up caches. Report median + percentiles, not mean. Statistical significance for variants.

**Performance Counters:** Profile cycles, instructions, cache misses, branch misses, TLB. CPI < 1.0 target on superscalar. Memory-bound → layout/prefetch. Branch-bound → outline/branchless. Tools: `perf stat`, `perf record/report`, vtune, uProf, Streamline. Quick top-down: `perf stat --topdown` (TMA).

**Compiler Diagnostics:** `-Rpass=.* -Rpass-missed=.*` (Clang) or `-fopt-info-vec-missed` (GCC). In Zig: `-femit-asm` or `-femit-llvm-ir`. Look for "cannot vectorize" — loop-carried dep, aliasing, mixed types.

**Memory Profiling:** `perf mem` for load/store sampling. `perf c2c` for false sharing detection. Zig's `StackFallbackAllocator` avoids heap for small requests. `FixedBufferAllocator` for bounded arenas.

**Binary Layout Profiling:** `perf report --sort=block,symbol` for hot blocks. `llvm-bolt-heatmap` for visual binary heatmaps. `perf lock` for lock contention. ARM `topdown-tool` for TMA.

