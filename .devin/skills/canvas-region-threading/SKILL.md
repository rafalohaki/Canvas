---
name: canvas-region-threading
description: Use whenever writing or reviewing code that touches Minecraft world/entity/block data in Canvas — region threading safety rules, TickThread validation, choosing the right scheduler (RegionScheduler, EntityScheduler, GlobalRegionScheduler, AsyncScheduler), thread ownership checks, or avoiding IllegalStateException from off-thread access. Triggers on "region threading", "tick thread", "TickThread", "RegionScheduler", "EntityScheduler", "GlobalRegionScheduler", "AsyncScheduler", "thread safety", "isTickThreadFor", "ensureTickThread", "IllegalStateException", "off-thread", "wrong thread", "TickGuard", "guardSeverity".
triggers:
  - user
  - model
model: sonnet
argument-hint: "[scenario]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Region Threading Safety

Canvas replaces Minecraft's single main thread with **region threading**: nearby
chunks are grouped into regions, each ticked independently in parallel. This is
the core architectural constraint — violating it causes `IllegalStateException`
or silent data corruption.

Sources: DeepWiki `CraftCanvasMC/Canvas` (Region Threading, CRS Scheduler);
local `canvas-server/minecraft-patches/base/0001-Region-Threading-Base.patch`,
`0011-Fixup-Region-Threading.patch`; `io.canvasmc.canvas.util.TickGuard`.

## The One Rule

> **Only the tick thread currently ticking a region may access data owned by that region.**

"Region-owned data" = entities in that region, blocks/chunks in that region,
tile entities, world data for those chunks. Violations throw
`IllegalStateException` (when guarded) or corrupt silently (when unguarded).

## Thread Validation

```java
TickThread.isTickThreadFor(Level level, int chunkX, int chunkZ)  // owns this chunk?
TickThread.isTickThreadFor(Entity entity)                         // owns this entity?
TickThread.isTickThreadFor(Location location)                     // owns this location?
TickThread.ensureTickThread(...)                                  // throws if wrong
TickThread.isTickThread()                                         // any tick thread?
```

**Always validate before accessing region data from code that might run off-thread.**

### TickGuard (Canvas-original)

`io.canvasmc.canvas.util.TickGuard` wraps the checks with configurable severity
(`GlobalConfiguration.regionScheduler.guardSeverity`):

| Severity | Behavior |
|----------|----------|
| `THROW` (default) | `TickThread.ensureTickThread(...)` — throws `IllegalStateException` |
| `LOG` | Validates tick thread, logs warning + stack trace if region mismatch, continues |
| `SILENT` | Validates tick thread only, no region check, no log |

```java
TickGuard.guard(chunkX, chunkZ, level, "reason");   // chunk-based
TickGuard.guard(entity, "reason");                   // entity-based
TickGuard.ensureGlobalOrStartup("reason");           // global tick or startup thread
TickGuard.hardThrowIfStarted(() -> isTickThreadFor(...), "reason");
```

`ensureGlobalOrStartup` passes if on `RegionShutdownThread` (owns all during shutdown).

## Choosing the Right Scheduler

| Scheduler | Use for | Key property |
|-----------|---------|--------------|
| `RegionScheduler` | Tasks by **location** (block changes, explosions at a point) | Runs on the region owning that location. **Not** for entities (they move between regions). |
| `EntityScheduler` | Tasks acting on an **entity** (teleport, damage, metadata) | "Follows" the entity across region boundaries. |
| `GlobalRegionScheduler` | Global tick tasks (world time, weather, console commands) | Runs on the global region. |
| `AsyncScheduler` | Pure computation, I/O, no world access | Off-tick, truly async. **Never access world data here.** |

### Selection guide

- **Block at coords** → `RegionScheduler.execute(location, ...)` / `runDelayed`
- **Entity work** → `entity.getScheduler().execute(plugin, task, retired, delay)` — never `RegionScheduler`
- **World-wide / no specific chunk** → `GlobalRegionScheduler`
- **Pure compute / DB / HTTP** → `AsyncScheduler` — no `world.getX()`, no `entity.getLocation()`
- **Legacy `Bukkit.getScheduler().runTask()`** → does not exist; migrate to one of the above

### API access
```java
Bukkit.getRegionScheduler()       // RegionScheduler
entity.getScheduler()             // EntityScheduler
Bukkit.getGlobalRegionScheduler() // GlobalRegionScheduler
Bukkit.getAsyncScheduler()        // AsyncScheduler
```

## Common Patterns

### Schedule a block change at a location
```java
Bukkit.getRegionScheduler().execute(location, () -> {
    location.getBlock().setType(Material.STONE);
});
```

### Schedule work on an entity
```java
entity.getScheduler().execute(plugin, () -> {
    entity.setVelocity(new Vector(0, 1, 0));
}, null, 1L);  // retired=null, delay=1 tick
```

### Run something next tick on the global region
```java
Bukkit.getGlobalRegionScheduler().runDelayed(plugin, task -> {
    // world time, weather, etc.
}, 1L);
```

### Async computation (no world access)
```java
Bukkit.getAsyncScheduler().runNow(plugin, task -> {
    // pure compute, DB, HTTP — NEVER world.getBlock(), entity.getLocation(), etc.
});
```

## Region Schedule Handle & Tick State

Each region has a `TickRegionScheduler.RegionScheduleHandle` (the schedulable
tick task) paired with a `ScheduledHandleTickState`
(`io.canvasmc.canvas.tick.ScheduledHandleTickState`). The state holds:

- `scheduleHandle` — the `RegionScheduleHandle` (current tick, scheduled start, region data)
- Sprint state (`tickCountToSprintTo`) — see Sprinting below
- `runsGameElements` — pause/play game elements without stopping ticks

`ServerRegionTickManager.ensureScheduleHandle(handle, reason)` throws if the
given handle is not `TickRegionScheduler.getCurrentTickingTask()` — use to
guard operations that must run on the currently-ticking handle.

### Sprinting ticks

`ScheduledHandleTickState` supports rapid tick processing:

```java
// Via RegionHandle API (ServerRegionTickManager.ServerRegionHandle)
handle.sprint(int ticks);   // Action.StartSprinting — sets tickCountToSprintTo = current + ticks
handle.walk();               // Action.StopSprinting — stops sprinting
handle.pause();              // stops running game elements (entities, etc.)
handle.play();               // resumes game elements
```

While sprinting, `tickSprint()` returns `1L` (minimal delay) instead of
`getTimeBetweenTicks()`, rapidly processing ticks until `currentTick >=
tickCountToSprintTo`. Used for catch-up or testing. `isSprinting()` /
`doesRunGameElements()` require the calling thread to own the schedule handle.

## Thread Ownership Rules

- **Only the tick thread of a region may access that region's data.** Cross-region
  access → `IllegalStateException`.
- `TickThread.isTickThreadFor(...)` is the cheap check; `ensureTickThread(...)`
  is the throwing check.
- `TickGuard` adds severity control — `THROW` is the production default.
- Entities are mobile — never cache a region reference for an entity; use
  `EntityScheduler` which follows the entity across boundaries.
- Chunk generation runs on `BalancedChunkSystem` threads (async), **not** tick
  threads — never access region data from chunk gen callbacks.

## Region Split / Merge Behavior

Regions split and merge dynamically as chunks load/unload. Canvas hooks these
transitions via `SchedulerUtil.SchedulerHandler`:

- **Split**: `onRegionSplit(from, into, level)` — if the split region is the
  profiling target, pinning state transfers to the new region containing the
  center chunk (`RegionScheduleHandlePinner.RegionPinner.getCenter()`).
- **Merge**: `onRegionMerge(from, to, level)` — unpin `from`, repin `to`.
- **Destroy / Inactive**: `onRegionDestroy` / `onRegionInactive` — unlink the
  runner from the handle.

For non-profiling code: never cache region references across ticks — always
look up the current region via `regioniser.getRegionAtUnsynchronised(x, z)`.

## Fail-Fast on Pinned Region Errors

When a region is pinned for profiling and encounters an unrecoverable error
(region death, uncaught exception in scheduler internals), Canvas **halts the
server** to prevent data corruption. This is intentional: profiling results are
either valid or the server stops — no undefined state. See
`io.canvasmc.canvas.spark.profiler.package-info` (Region Death section) and
`SchedulerUtil.decideScheduler` AFFINITY case `onException` (crash report +
`scheduler.halt()` + `stopServer()`).

## What You CANNOT Do

- `Bukkit.getScheduler().runTask(...)` — **does not exist** in Canvas/Folia. Use region schedulers.
- Access `entity.getLocation()` from async — location is region-owned data.
- Access `world.getBlockAt(x,y,z)` from async or a different region's thread.
- Share mutable region data across regions without synchronization.
- Assume a "main thread" exists — there isn't one. `Bukkit.isPrimaryThread()` is meaningless.

## Canvas-Specific: AFFINITY Scheduler

Canvas has its own scheduler implementation, **AFFINITY**
(`io.canvasmc.canvas.tick.*`), replacing Folia's. DeepWiki refers to this as
the **CRS (Canvas Region-Specific) Scheduler**. It is EDF-based, supports task
pinning and work stealing. Configured via `paper-global.yml` →
`threaded-regions.scheduler` = `AFFINITY`. See `/canvas-affinity-scheduler`
for full internals.

## When Refactoring

1. **Identify the threading context** — what thread will this run on?
2. **If unsure, schedule it** — use the appropriate scheduler rather than assuming.
3. **Add `TickThread.ensureTickThread(...)`** or `TickGuard.guard(...)` at the entry of region-owned methods if the call site is uncertain.
4. **Never move region-owned data to async** — schedule a task on the owning region instead.
5. **Entities are mobile** — always use `EntityScheduler`, never `RegionScheduler` for entity work.

## Verification

When you write or change threading-sensitive code:
```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew runDev    # runtime test — watch for IllegalStateException in logs
```

Grep for violations in your diff:
```bash
git diff --staged | grep -E "getScheduler\(\)\.runTask|Bukkit\.getScheduler"
# These are legacy Bukkit calls that don't exist / don't work in Canvas
```

## Async Patterns

Region threading does not eliminate async work — it constrains where the
results may be applied. Use these patterns for async computation that
eventually touches region-owned data.

### CompletableFuture usage

`CompletableFuture` is fine for **pure computation** (no world access), but
the terminal stage that touches region data must hop back onto the owning
region's tick thread via a scheduler.

```java
CompletableFuture.supplyAsync(() -> computeExpensivePureValue(executor))
    .thenCompose(value ->
        // Hop back to the region owning the target location
        Bukkit.getRegionScheduler().execute(loc, () -> applyValue(value))
    );
```

- **Never** call `world.getX()` / `entity.getX()` inside a `supplyAsync` /
  `thenApplyAsync` stage — those run on the async executor, not a tick thread.
- Use `AsyncScheduler.runNow(plugin, task -> ...)` as the async stage if you
  want Canvas's async pool rather than a raw `ForkJoinPool`.
- For entity-targeted results, use `entity.getScheduler().execute(...)` as the
  terminal stage so the apply runs on whatever region the entity is in at that
  moment.

### Async resource cleanup

Async tasks that open resources (DB connections, HTTP clients, files) must
clean up in a `whenComplete` or try-finally — the region tick thread will not
clean up after an async task that was cancelled or threw.

```java
Bukkit.getAsyncScheduler().runNow(plugin, task -> {
    try (var conn = dataSource.getConnection()) {
        // ... pure work, no world access
    } catch (SQLException e) {
        LOGGER.warn("async db failure", e);
    }
});
```

### Cancellation patterns

- `AsyncScheduler` tasks return a `ScheduledTask`; call `task.cancel()` to
  cancel (async tasks are cancellable, unlike AFFINITY tick tasks which throw
  `UnsupportedOperationException` on `cancel()`).
- Region/Entity/Global scheduler tasks are **not cancellable** — design them
  to be short and idempotent instead. If you need cancellation, run the work
  on `AsyncScheduler` and only hop to a region scheduler for the final apply.
- For long-running async loops, check `Thread.interrupted()` /
  `task.isCancelled()` periodically and exit early.

See `/canvas-async-patterns` (if created) for a dedicated async cookbook.

## Cross-Region Communication

Regions are isolated — you cannot directly read another region's data from
the current region's tick thread. Use these safe channels to pass data
between regions.

### Schedulers (the primary channel)

The correct way to touch another region's data is to **schedule a task on
that region's scheduler**. The scheduler ensures the task runs on the owning
tick thread.

```java
// Region A's tick thread wants to affect a block in region B
Bukkit.getRegionScheduler().execute(targetLocation, () -> {
    // now running on region B's tick thread — safe
    targetLocation.getBlock().setType(Material.STONE);
});
```

### Callbacks (async → region)

When async work completes and needs to update region data, pass the result
through a scheduler callback (see Async Patterns above). The callback runs on
the owning region's tick thread.

### Thread-safe queues (for streaming data between regions)

For continuous data flow (e.g. region A produces events that region B
consumes), use a concurrent queue and have the consumer poll on its own tick:

```java
// Shared, thread-safe
ConcurrentLinkedQueue<Event> queue = new ConcurrentLinkedQueue<>();

// Region A produces (on its tick thread)
queue.offer(event);

// Region B consumes (on its tick thread, each tick)
Bukkit.getRegionScheduler().runAtFixedRate(plugin, bLoc, task -> {
    Event e;
    while ((e = queue.poll()) != null) handle(e);
}, 1L, 1L);
```

- Use `ConcurrentLinkedQueue` (unbounded) or `ArrayBlockingQueue` (bounded,
  backpressure) — never a plain `ArrayList` / `LinkedList` shared across
  regions.
- The producer must not access region B's data when enqueuing — only hand off
  the immutable payload.
- Payloads passed through the queue **must be immutable** or effectively
  immutable (copy before enqueue if the producer mutates afterwards).

### What NOT to do

- Don't share a mutable `Map`/`List` of region-owned objects across regions
  even with a lock — the lock prevents CME but not wrong-thread access
  exceptions when the contents are touched.
- Don't use `volatile` references to region-owned data as a cross-region
  channel — visibility ≠ ownership; touching it from the wrong thread still
  throws.
- Don't cache a `TickRegionData` / region reference — regions split/merge;
  always look up the current region via
  `regioniser.getRegionAtUnsynchronised(x, z)` and schedule onto it.

## Pitfalls

1. **`RegionScheduler` for entities** — entities move between regions; use `EntityScheduler`.
2. **Async accessing world** — `world.getX()` from async throws or corrupts.
3. **Assuming main thread** — there is no single main thread; `Bukkit.isPrimaryThread()` always returns false.
4. **Cross-region mutable sharing** — if two regions share a mutable object, you need external synchronization.
5. **`guardSeverity = SILENT`** — hides region mismatches; only use in debug, never production.
6. **Plugin compat** — most Paper plugins assume a main thread; they need scheduler migration. See `/canvas-plugin-compat`.
