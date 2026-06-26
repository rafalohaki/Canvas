---
name: canvas-performance-optimization
description: Use whenever profiling, optimizing, or benchmarking Canvas performance — Spark profiler advanced usage (heap summary, sampler, GC profiler), TPS optimization for region threading, memory leak detection, GC tuning for Java 25 (ZGC vs G1), JMH micro-benchmarks, flame graph interpretation, hot path identification in the tick loop, allocation profiling, lock contention, and Canvas-specific optimizations (fluid spread via SlopeDistanceNodeDeque, chunk gen pool, scheduler tuning). Triggers on "optimize", "performance", "slow tick", "TPS drop", "lag", "flame graph", "benchmark", "hot path", "allocation", "GC", "ZGC", "G1", "JMH", "heap dump", "memory leak", "profiler", "Spark sampler", "GC log".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Performance Optimization

Performance work on Canvas spans three axes: **tick throughput (TPS)**,
**memory footprint (heap + GC)**, and **scheduler efficiency (AFFINITY)**.
Region threading changes the optimization landscape — hot paths are
per-region, not global, and the AFFINITY scheduler's EDF + work stealing
introduces its own overhead profile. Always ground in real measurements
(Spark, JMH, GC logs) before optimizing.

Sources: DeepWiki `CraftCanvasMC/Canvas` (Spark integration, AFFINITY
scheduler, chunk system); local `io.canvasmc.canvas.spark.*`,
`io.canvasmc.canvas.tick.*`, `SlopeDistanceNodeDeque`, `BalancedChunkSystem`.

## When to Use

Invoke this skill when the user mentions any of:
- "optimize", "performance", "slow tick", "TPS drop", "lag"
- "flame graph", "benchmark", "hot path", "allocation", "GC"
- "ZGC", "G1", "JMH", "heap dump", "memory leak"
- "Spark sampler", "GC log", "profiler" (beyond region profiling — see
  `/canvas-region-profiling` for the pinning system itself)

## Spark Profiler — Advanced Usage

Canvas ships a full Spark integration (see `/canvas-region-profiling` for
the pinning system). Beyond region pinning, Spark provides:

- **Sampler** (`/spark sampler`) — CPU sampling profiler. Start with
  `/spark sampler start`, stop with `/spark sampler stop`. Uploads a
  flame graph to Spark's host. Use `--thread "Region Scheduler Thread #N"`
  to target a specific region thread without pinning.
- **Heap summary** (`/spark heapsummary`) — dumps a histogram of live
  objects by class. Use to find unexpected object retention (e.g.,
  leaked `RegionScheduleHandle` instances, oversized chunk caches).
  Look for classes from `io.canvasmc.canvas.*` dominating the heap.
- **GC profiler** (`/spark gc`) — records GC events, pause times,
  allocation rate. Pair with `-Xlog:gc*` JVM flags for full analysis.
  On Canvas the interesting metric is **pause time per region tick** —
  a long GC pause stalls all region threads uniformly.
- **Disk I/O** (`/spark health`) — general health report covering TPS,
  MSPT, disk, memory. Good first-pass diagnostic.

```bash
# In-game (requires runDev or live server)
/spark sampler start --thread "Region Scheduler Thread #0"
/spark heapsummary
/spark gc
/spark health
```

## TPS Optimization Strategies

TPS drops on Canvas are almost always one of:
1. **Tick-heavy region** — one region doing too much work (entity AI,
   redstone, fluid spread). Diagnose with Spark sampler on the offending
   thread. Fix by splitting the region (player movement triggers splits)
   or reducing per-chunk work.
2. **Entity density** — too many entities in one region. Check
   `spark heapsummary` for `Entity` subclass counts. Cap via
   `entities-activation-range` config or cull inactive entities.
3. **Chunk load spike** — sudden chunk gen/load burst saturates the
   chunk system pool. See `/canvas-chunk-system`. Tune
   `chunk-gen-pool-size` and `chunk-load-queue-cap`.
4. **Scheduler contention** — AFFINITY work-stealing thrashing. Check
   `spark sampler` for `WorkStealingQueue` / `poll` frames. Tune
   `steal-threshold` (see `/canvas-affinity-scheduler`).

```bash
# Find tick-heavy regions
grep -rn "tickTime\|tickMs" canvas-server/src/main/java/io/canvasmc/canvas/tick/
# Entity density config
grep -rn "activation-range\|entities-activation" canvas-server/src/main/java/io/canvasmc/canvas/config/
```

## Memory Leak Detection

Region threading makes leaks harder to spot — a leaked
`RegionScheduleHandle` keeps an entire region's data alive.

- **Heap dump analysis** — trigger with `/spark heapsummary` (live
  histogram) or `-XX:+HeapDumpOnOutOfMemoryError` for a full dump. Load
  in Eclipse MAT or IntelliJ profiler. Search for
  `RegionScheduleHandle`, `ThreadedRegionizer$Region`, `ChunkHolder`
  retention paths.
- **Weak reference patterns** — Canvas uses `WeakReference` /
  `COWArrayList` for cross-region references. When adding new
  cross-region state, prefer weak refs to avoid pinning dead regions.
- **Cache eviction** — check `io.canvasmc.canvas.*` caches for TTL or
  size bounds. A cache keyed by `RegionPos` that never evicts will leak
  as regions split/merge. Add `Caffeine`-style expiry or manual cleanup
  on `onRegionDestroy`.

```bash
grep -rn "WeakReference\|SoftReference\|Caffeine\|expireAfter" canvas-server/src/main/java/io/canvasmc/canvas/
grep -rn "onRegionDestroy\|onRegionInactive" canvas-server/src/main/java/io/canvasmc/canvas/tick/
```

## GC Tuning for Java 25

Canvas targets Java 25 (toolchain + `options.release = 25`). Recommended
GC depends on workload:

- **ZGC** (default for low-pause) — `-XX:+UseZGC`. Sub-millisecond
  pauses, good for region threading where uniform stall is acceptable
  but long pauses hurt all regions. Tune with
  `-XX:ZUncommitDelay=300`, `-XX:SoftMaxHeapSize`.
- **G1** (default for throughput) — `-XX:+UseG1GC`. Better throughput
  on large heaps with predictable pause targets
  (`-XX:MaxGCPauseMillis=50`). Use when pause budget is generous.
- **Heap sizing** — start with `-Xmx` = 2× observed live set from
  `/spark heapsummary`. Monitor with `-Xlog:gc*:file=gc.log:time`.

**GC log analysis**:
```bash
# Enable GC logging
-XX:+UseZGC -Xlog:gc*:file=gc.log:time,uptime,level,tags
# Analyze with tools like GCEasy or JITWatch
# Look for: allocation spikes during chunk gen, long safepoints
```

## Benchmark Patterns — JMH

For micro-benchmarks (scheduler dispatch, region lookup, fluid spread node selection), use **JMH**. Canvas doesn't ship a JMH harness by default — add a `bench` source set or standalone module.

```java
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@State(Scope.Benchmark)
public class SchedulerDispatchBenchmark {
    @Benchmark
    public void dispatchRegionTask(AffinitySchedulerState state) {
        state.scheduler.runRegionTask(state.location, state.task);
    }
}
```

- **Load testing with simulated players** — use the test-plugin module (see `/canvas-testing-strategy`) to spawn N fake players across regions, measure TPS + MSPT under load. Vary region density and entity count.
- **Avoid micro-benchmark traps** — JIT inlining, dead code elimination. Use `Blackhole.consume()` for results. Warmup ≥ 5 iterations, measure ≥ 10.

## Flame Graph Interpretation

Spark generates flame graphs (Brendan Gregg style). Reading them:

- **Width** = time on stack (sample count). Wide bars = hot.
- **Height** = call depth. Tall narrow stacks = deep but rare.
- **Look for** — wide bars at the top (the actual hot function), wide plateaus (a function called from many places), and `RegionSchedulerThread#tick` as the root for region threads.
- **Canvas-specific hot frames** — `SlopeDistanceNodeDeque.poll`, `ThreadedRegionizer.tick`, `ChunkMap.tick`, `EntityTickList.tick`.

```bash
# After /spark sampler stop, the uploaded URL has the flame graph.
grep -rn "SlopeDistanceNodeDeque" canvas-server/src/main/java/
```

## Hot Path Identification

The Canvas tick loop per region thread (simplified):
```
TickThreadRunner.run()
  → RegionScheduleHandle.tick()
    → tickRegion()  (entities, blocks, fluids, chunk tasks)
      → EntityTickList.tick()
      → fluidSpread (SlopeDistanceNodeDeque)
      → ChunkMap.tick (for this region's chunks)
```

- **Allocation profiling** — use `/spark sampler` with allocation mode (`--allocation`). Hot allocation sites in the tick loop cause GC pressure. Common offenders: per-tick `ArrayList` allocation, boxed primitives in hot loops, `Location` object creation.
- **Lock contention** — region threads should rarely block. If Spark shows `Object.wait` / `ReentrantLock.lock` frames, investigate cross-region synchronization. Canvas prefers message-passing over locks; a lock in the tick path is a bug.

```bash
grep -rn "synchronized\|ReentrantLock\|\.lock()" canvas-server/src/main/java/io/canvasmc/canvas/tick/
# Any of these in tick-critical code? Investigate.
```

## Canvas-Specific Optimizations

- **Fluid spread (`SlopeDistanceNodeDeque`)** — Canvas rewrote vanilla
  fluid flow with a slope-distance-based deque for better performance
  and deterministic ordering. If fluid spread shows as hot, check the
  deque sizing and the `max-fluid-spread-per-tick` config.
- **Chunk gen pool** — `BalancedChunkSystem` uses a bounded pool for
  chunk generation. Tune `chunk-gen-pool-size` (default derived from
  CPU count). Too small → chunk gen backlog; too large → thread
  contention with region threads.
- **Scheduler tuning** — AFFINITY's `steal-threshold` controls when
  tasks migrate between runners. Low value = more stealing (better
  balance, more overhead); high value = less stealing (risk of
  starvation). See `/canvas-affinity-scheduler`.

```bash
grep -rn "SlopeDistanceNodeDeque" canvas-server/src/main/java/
grep -rn "chunk-gen-pool\|chunkGenPool" canvas-server/src/main/java/io/canvasmc/canvas/config/
grep -rn "steal-threshold\|stealThreshold" canvas-server/src/main/java/io/canvasmc/canvas/tick/
```

## Optimization Workflow

1. **Measure first** — `/spark health`, `/spark sampler`, GC logs. Never optimize without a profile.
2. **Identify the axis** — TPS, memory, or scheduler overhead?
3. **Find the hot frame** — flame graph wide bar at the top.
4. **Read the source** — ground in actual Canvas code (APIs drift between MC versions).
5. **Minimal change** — respect patch layers (`/canvas-patch-authoring`); optimization patches go in `minecraft-patches/sources/` or `features/`.
6. **Benchmark before/after** — JMH for micro, `/spark` for macro.
7. **Verify** — `./gradlew applyAllPatches` → compile → `./gradlew test` → `./gradlew runDev` under load.

## Verification

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew test
./gradlew runDev
# In-game:
/spark health                  # baseline
/spark sampler start           # profile under load
# ... reproduce the lag scenario ...
/spark sampler stop            # review flame graph
/spark heapsummary             # check for leaks
```

## Cross-References

- `/canvas-region-profiling` — task pinning system for per-region Spark profiling. Read before profiling a single region.
- `/canvas-affinity-scheduler` — EDF, task pinning, work stealing. Scheduler tuning is a common optimization lever.
- `/canvas-chunk-system` — `BalancedChunkSystem`, `ThreadedRegionizer`. Chunk gen/load is a frequent TPS bottleneck.
- `/canvas-build-system` — Java 25, Gradle 9.5.1 toolchain settings that affect JIT/GC defaults.

## Pitfalls

1. **Don't optimize without a profile** — guessing the hot path is usually wrong, especially with region threading.
2. **Region threads are not the main thread** — optimizations valid on single-threaded Paper may not apply. Test under region-threaded load.
3. **Task pinning hurts performance** — only enable Spark region pinning when actively profiling; it isolates a runner and reduces throughput.
4. **GC pauses stall all regions uniformly** — a long pause looks like a global TPS drop, not a per-region issue. Check GC logs before blaming region code.
5. **Caches keyed by region must evict on region destroy** — otherwise split/merge churn leaks memory.
6. **JMH without `Blackhole`** — JIT eliminates dead results; your benchmark measures nothing.
7. **Locks in the tick path are bugs** — Canvas is designed for message-passing; investigate any `synchronized` in tick-critical code.
