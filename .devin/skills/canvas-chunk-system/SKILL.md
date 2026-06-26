---
name: canvas-chunk-system
description: Use whenever working with Canvas's chunk system — BalancedChunkSystem, ThreadedRegionizer, WorldRegionizer, region boundaries, chunk lifecycle, ChunkHolder registration, chunk generation pool, chunk loading/unloading behavior, or how the chunk system interacts with region threading. Triggers on "chunk system", "BalancedChunkSystem", "ThreadedRegionizer", "WorldRegionizer", "region boundary", "ChunkHolder", "chunk loading", "chunk generation", "chunk pool", "regionizer", "gridExponent", "chunk lifecycle", "OrderedStreamGroup".
triggers:
  - user
  - model
subagent: true
argument-hint: "[component]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Chunk System & Regionization

Canvas replaces the vanilla chunk system with a rewritten pool
(`BalancedChunkSystem`) and uses `ThreadedRegionizer` to group nearby chunks
into independently-ticked regions. The chunk system feeds region threading —
chunk load/unload drives region split/merge.

Sources: DeepWiki `CraftCanvasMC/Canvas` (Chunk System, Regionization);
local `io.canvasmc.canvas.world.chunk.BalancedChunkSystem`,
`io.canvasmc.canvas.world.CanvasRegionizedWorldData`,
patches `0001`, `0011`, `0013`.

## Core Concepts

### ThreadedRegionizer

`io.papermc.paper.threadedregions.ThreadedRegionizer` (patch `0001`) divides
the world into sections and manages region boundaries. Each region is a
collection of nearby loaded chunks that tick together on one thread.

- **Region size** = `2^gridExponent` chunks per side (default `gridExponent=4` → 16x16 chunks)
- **Dynamic boundaries** — regions merge/split as chunks load/unload
- `ChunkHolder` instances register/unregister with `ThreadedRegionizer` as chunks are created/deleted
- `getRegionAtUnsynchronised(chunkX, chunkZ)` / `getRegionAtSynchronised(chunkX, chunkZ)` — look up current region
- `ThreadedRegion<TickRegionData, TickRegionSectionData>` — a region instance; `getData()` yields the tick data

### WorldRegionizer interface

The `WorldRegionizer` interface (patch `0001`) abstracts regionization per
world. `ThreadedRegionizer` is the implementation. Each `ServerLevel` exposes
its regionizer via `level.regioniser`. Region sections merge into regions
based on chunk proximity and the grid exponent.

### BalancedChunkSystem

`io.canvasmc.canvas.world.chunk.BalancedChunkSystem` — Canvas's rewritten chunk
system executor for chunk generation/loading. Extends
`BalancedPrioritisedThreadPool` (ConcurrentUtil by SpottedLeaf), modified to
remove max parallelism and rework the constructor for Canvas.

Replaces Moonrise's executor (patch `0013-Replace-Moonrise-Executor`,
`0007-Replace-Moonrise-Executor` paper-base). Key internals:

- `WorkerThread` pool — `adjustThreadCount(n)` adds/trims threads at runtime
- `OrderedStreamGroup` — chunk-ordered task stream; `createExecutor()` returns
  a `Queue` (`PrioritisedExecutor`) per chunk load/generation stream
- `groupTimeSliceNS` — time slice per worker poll loop
- Tasks prioritised via `Priority` (e.g. `Priority.HIGHEST` for profiler loads)
- `peekTask()` scans all queues for the highest-priority task across streams

### Data Isolation

Each region owns:
- Loaded chunks in its area
- Ticking chunks
- Entities in those chunks
- Tile entities (block entities) in those chunks

This data is **not shared** between regions — access from the wrong thread
throws `IllegalStateException` (guarded by `TickGuard` /
`TickThread.ensureTickThread`).

`CanvasRegionizedWorldData` (patch `0012`) is Canvas's regionized world data
implementation — holds per-region entity/chunk/TE storage.

## Finding the Code

```bash
# ThreadedRegionizer / WorldRegionizer
grep -rl "ThreadedRegionizer\|WorldRegionizer" canvas-server/src/minecraft/java/ 2>/dev/null
grep -rl "ThreadedRegionizer" canvas-server/minecraft-patches/base/ 2>/dev/null

# BalancedChunkSystem / chunk executor
grep -rl "BalancedChunkSystem" canvas-server/src/main/java/ 2>/dev/null

# Region data
grep -rl "RegionizedWorldData\|CanvasRegionizedWorldData" canvas-server/src/main/java/ 2>/dev/null
```

**Always grep current source** — class locations shift between MC versions.

## Key Base Patches

| Patch | What it does |
|-------|-------------|
| `0001-Region-Threading-Base` | Heart of region threading — ThreadedRegionizer, TickThread, region schedulers, WorldRegionizer |
| `0003-Add-chunk-system-throughput-counters` | Throughput counters for chunk system |
| `0004-Prevent-block-updates-in-non-loaded-or-non-owned-chu` | Block updates only in loaded+owned chunks |
| `0005-Block-reading-in-world-tile-entities-on-worldgen` | TE worldgen safety |
| `0011-Fixup-Region-Threading` | Canvas fixups — AFFINITY scheduler type, region split/merge profiler hooks |
| `0012-Canvas-RegionizedWorldData` | Canvas's regionized world data implementation |
| `0013-Replace-Moonrise-Executor` | Canvas chunk executor (`BalancedChunkSystem`) replaces Moonrise's |

## Chunk Lifecycle

```
Chunk requested (player movement, ticket)
  → BalancedChunkSystem queues generation/load (OrderedStreamGroup.Queue)
  → WorkerThread polls highest-priority task, generates/loads chunk
  → ChunkHolder created → registers with ThreadedRegionizer
  → Region assigned (existing region absorbs it, or new region created)
  → Chunk ticks on that region's tick thread (AffinitySchedulerThreadPool)
  → Chunk unloaded → ChunkHolder unregisters
  → Region may shrink; if too small, merges with neighbor
```

Chunk generation runs on `BalancedChunkSystem.WorkerThread` (async, not tick
threads). Chunk ticking runs on region tick threads. **Never access region
data from chunk generation callbacks** — schedule onto the owning region
instead.

## Chunk Loading / Unloading Behavior

- **Tickets** drive load/unload. `TicketType.REGION_PROFILING_HOLD` (Canvas)
  keeps chunks loaded for profiling — non-persistent, like `forced`.
- `level.moonrise$loadChunksAsync(minX, maxX, minZ, maxZ, Priority, callback)`
  — async bulk load; callback runs on the owning region's tick thread.
- `level.canvas$loadOrRunAtChunksAsync(...)` — Canvas extension; loads or runs
  directly if already loaded.
- Unload: `ChunkHolder` unregisters from `ThreadedRegionizer` → region may
  split/shrink. Profiler hooks (`onRegionSplit`/`onRegionMerge`) repin as needed.

## How Chunk System Interacts with Region Threading

1. **Chunk load** → `ChunkHolder` registers with `ThreadedRegionizer` → region
   created/expanded → `RegionScheduleHandle` scheduled on tick pool
2. **Chunk unload** → `ChunkHolder` unregisters → region shrinks/splits →
   `SchedulerHandler.onRegionSplit` / `onRegionMerge` transfer pinning state
3. **Region tick** → tick thread owns all chunks/entities/TEs in the region;
   `TickThread.isTickThreadFor(level, chunkX, chunkZ)` validates ownership
4. **Block updates** — patch `0004` prevents block updates in non-loaded or
   non-owned chunks; new block update paths must check ownership
5. **Worldgen TE access** — patch `0005` blocks reading world TEs during
   worldgen; respect in new worldgen code

## Region Boundary Considerations

- **Cross-region block updates** — patch `0004` enforces ownership; new code must too.
- **Entity movement across boundaries** — entities transfer between regions;
  the `EntityScheduler` handles this. Don't cache region references for entities.
- **Tile entity access** — patch `0005` blocks reading world TEs during worldgen.
- **Region split/merge** — `ThreadedRegionizer` merges adjacent regions when
  small, splits when large. Profiler repins via `SchedulerHandler` hooks.

## When Modifying Chunk System Code

1. **Identify the patch** — `grep -rl "ClassName" canvas-server/minecraft-patches/base/`
2. **Apply patches**: `./gradlew applyAllPatches`
3. **Edit in `canvas-server/src/main/java/`** (Canvas code) or
   `canvas-server/src/minecraft/java/` (patched vanilla)
4. **Rebuild**: `./rbp.sh`
5. **Test**: `./gradlew runDev` — load chunks by moving around, watch for
   region split/merge errors

## Verification

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew runDev
# Test: teleport around, load/unload chunks, check for region errors in console
# Watch: "Region surrounding ... missed deadline" (overload), region split/merge logs
```

## Pitfalls

1. **Don't cache region references** — regions merge/split dynamically; always look up current region.
2. **Block updates must check ownership** — patch `0004` enforces this; new code must too.
3. **Chunk gen is async, chunk tick is regional** — don't access region data from chunk generation threads.
4. **Moonrise executor is replaced** — don't reference Moonrise's executor; Canvas has its own (`0013`, `BalancedChunkSystem`).
5. **`CanvasRegionizedWorldData` is Canvas-original** — patch `0012`; changes go in source patches, not base.
6. **`OrderedStreamGroup.Queue` is per-stream** — don't share a queue across unrelated chunk loads.
7. **`adjustThreadCount` is runtime-safe** — can grow/shrink the worker pool without restart.
