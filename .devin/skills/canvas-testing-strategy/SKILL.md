---
name: canvas-testing-strategy
description: Use whenever writing or running Canvas tests — unit tests for pure logic, integration tests with mocked server, runtime tests via runDev, load tests with simulated players, region threading test utilities (mock TickThread, simulated region tick), test-plugin module usage, flaky test detection, coverage requirements for schedulers/threading/config/patches, and CI test commands. Triggers on "test", "testing", "unit test", "integration test", "load test", "flaky", "coverage", "test plugin", "mock TickThread", "region test", "gradlew test".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Testing Strategy

Canvas testing spans four layers: **unit** (pure logic, no server),
**integration** (mocked server / scheduler), **runtime** (`runDev` with
a live server), and **load** (multi-player simulation). Region
threading adds a constraint: tests that touch world/entity/block data
must run on the owning tick thread or they throw
`IllegalStateException` from `TickThread.ensureTickThread(...)`.

Sources: DeepWiki `CraftCanvasMC/Canvas` (test infrastructure);
local `canvas-server/src/test/`, `test-plugin/` module,
`io.canvasmc.canvas.tick.TickThread`.

## When to Use

Invoke this skill when the user mentions:
- "test", "testing", "unit test", "integration test", "load test"
- "flaky", "coverage", "test plugin"
- "mock TickThread", "region test", "gradlew test"

## Test Layers

| Layer | What | How | Speed |
|-------|------|-----|-------|
| Unit | Pure logic (math, config parsing, data structures) | JUnit 5 in `src/test/` | Fast (ms) |
| Integration | Scheduler, region tick with mocked server | JUnit 5 + mocked `TickThread` / `ServerLevel` | Medium (100s ms) |
| Runtime | Full server, real patches applied | `./gradlew runDev` + test-plugin | Slow (seconds) |
| Load | Many simulated players, chunk/entity stress | test-plugin + bot harness | Slow (minutes) |

## Unit Tests — Pure Logic

Unit tests live in `canvas-server/src/test/` and `canvas-api/src/test/`.
They must not touch Minecraft server classes that require a running
server. Test pure logic: config parsing, scheduler math (EDF priority
calculation), data structures (`SlopeDistanceNodeDeque`), region
boundaries.

```java
@Test
void slopeDistanceDequeOrdersBySlope() {
    var deque = new SlopeDistanceNodeDeque();
    deque.add(node(0, 0, 0));
    deque.add(node(1, 0, 0));
    // ... assert ordering
}
```

- **No static `MinecraftServer` access** — unit tests must not reference
  `MinecraftServer.getServer()` or `Bukkit.getServer()`. These are null
  without a running server.
- **No region data access** — anything touching `Level`, `Entity`,
  `ChunkAccess` belongs in integration or runtime tests.

## Integration Tests — Mocked Server

Integration tests mock the minimal server surface needed to exercise
scheduler + region threading code. The key challenge: `TickThread`
guards throw if the test thread isn't a tick thread for the region.

**Mocking `TickThread`**:
```java
// Pattern: run test body on a mock TickThread
TickThread mockThread = new TickThread(() -> {
    // test assertions that call ensureTickThread(...)
}, "Test-TickThread-0", ...);
mockThread.start();
mockThread.join();
```

**Simulated region tick**:
```java
// Build a minimal RegionScheduleHandle + tick it directly
RegionScheduleHandle handle = createTestRegion(world, chunks);
handle.tick();  // runs entity/block/fluid tick for the region
// assert side effects
```

- **Mock `ServerLevel`** — use a lightweight stub or Mockito. Full
  `ServerLevel` construction requires NMS + registries; too heavy for
  integration tests.
- **Scheduler tests** — instantiate `AffinitySchedulerThreadPool`
  directly with a small thread count (≥2 for region profiling support).
  Submit tasks, assert execution order / thread affinity.

```bash
# Find existing integration test patterns
grep -rln "TickThread\|RegionScheduleHandle" canvas-server/src/test/ 2>/dev/null
grep -rln "AffinityScheduler\|mock.*Scheduler" canvas-server/src/test/ 2>/dev/null
```

## Test Plugin Module

Canvas ships a `test-plugin/` module for **runtime API testing**. It loads when `runDev` starts (the dev server loads `*-plugin` / `*-debug` directories). Use it to exercise the Canvas API against a live server.

- **Purpose** — validate `RegionScheduler`, `EntityScheduler`, `GlobalRegionScheduler`, `AsyncScheduler` dispatch; config reads; region data access patterns.
- **How to add a test** — add a class in `test-plugin/src/main/java/`, register it in the plugin's `onEnable`. The plugin loads automatically on `runDev`.
- **Assertions** — log results to console; CI can grep for `TEST-PASS` / `TEST-FAIL` markers. No JUnit inside the server process (not on the runtime classpath).

```bash
ls test-plugin/src/main/java/ 2>/dev/null
grep -rn "onEnable\|TEST-PASS\|TEST-FAIL" test-plugin/src/main/java/ 2>/dev/null
```

## Load Testing

Load tests simulate many players + chunks + entities to stress region threading and the scheduler.

- **Simulated players** — the test-plugin can spawn fake `Player`-like entities or use a bot harness (headless client via protocol). Distribute them across regions to test balance.
- **Chunk load stress** — teleport fake players to unloaded areas, forcing chunk gen. Watch for `BalancedChunkSystem` backlog and TPS impact.
- **Entity density stress** — spawn N entities in one region, measure tick time. Tune `entities-activation-range` config.

```bash
./gradlew runDev
# In console: trigger the load test command registered by test-plugin
# Monitor: /spark health, /spark sampler
```

## Flaky Test Detection

Region-threaded tests are prone to flakiness from thread scheduling noise. Mitigations:

- **Retry patterns** — for timing-sensitive assertions, retry with `Awaitility`: `await().atMost(2, SECONDS).until(() -> state.matches());`
- **Time-sensitive tests** — avoid `Thread.sleep` + assert. Use countdown latches or `Awaitility` to wait for a condition.
- **Thread scheduling noise** — region threads are real OS threads; scheduling jitter can cause order-dependent failures. Make tests order-independent: assert on final state, not intermediate order.
- **Isolate scheduler tests** — each test gets a fresh `AffinitySchedulerThreadPool`; don't share across tests.
- **CI retry** — `./gradlew test --rerun-tasks` or use the `retry` plugin.

## Test Coverage Requirements

What **must** be tested (priority order):

1. **Schedulers** — `RegionScheduler`, `EntityScheduler`, `GlobalRegionScheduler`, `AsyncScheduler` dispatch + thread affinity. Critical: wrong scheduler = region threading violation.
2. **Threading guards** — `TickThread.isTickThreadFor(...)`, `ensureTickThread(...)` throw correctly on off-thread access.
3. **Config system** — per-world config load/merge, `global.yml` parsing, config migration across versions (see `/canvas-config-system`).
4. **Patches** — each base/source patch should have at least a smoke test. Use the test-plugin for runtime patch validation.
5. **Region split/merge** — `ThreadedRegionizer` split/merge repinning, ticket transfer (see `/canvas-chunk-system`).
6. **Fluid spread** — `SlopeDistanceNodeDeque` ordering + bounds.

```bash
# Check current coverage
./gradlew test
./gradlew jacocoTestReport 2>/dev/null  # if configured
```

## Region Threading Test Utilities

Writing tests that respect region boundaries:

- **`TickThread` mock** — construct a `TickThread` with a target
  region; run assertions inside its `run()` body.
- **`RegionScheduleHandle` builder** — helper to create a minimal
  region with N chunks for testing. Avoid full `ServerLevel`
  construction.
- **`ensureTickThread` in tests** — if the code under test calls
  `ensureTickThread`, the test must run on the right thread or it
  throws. This is correct behavior — don't mock away the guard.
- **Cross-region tests** — if a test spans two regions, use the
  scheduler to hop: schedule a task on region B from region A's
  thread, assert it runs on B's thread.

```bash
grep -rn "TickThread\|RegionScheduleHandle\|ensureTickThread" canvas-server/src/test/ 2>/dev/null
```

## CI Test Commands

```bash
# Full test suite
./gradlew test

# Specific module
./gradlew :canvas-server:test
./gradlew :canvas-api:test

# Parallel execution (Gradle defaults to parallel with build-cache)
./gradlew test --parallel

# Exclusions — skip slow/runtime tests
./gradlew test -PexcludeSlowTests

# Force rerun (for flaky investigation)
./gradlew test --rerun-tasks
```

Gradle is configured with configuration-cache + build-cache + parallel
(see `/canvas-build-system`). Tests inherit these; a clean run is
`./gradlew test --rerun-tasks --no-configuration-cache`.

## Test Workflow

1. **Write the test** — pick the right layer (unit > integration >
   runtime > load). Prefer the fastest layer that validates the
   behavior.
2. **Run locally** — `./gradlew test` for unit/integration; `runDev`
   for runtime.
3. **Check for flakiness** — run 5× (`--rerun-tasks`). If it fails
   intermittently, fix with `Awaitility` or isolation before merging.
4. **Verify coverage** — does the test cover the scheduler/threading/
   config path it claims to?
5. **Rebuild patches** — if the test required source changes,
   `./rbp.sh` to regenerate patch files.

## Verification

```bash
./gradlew test
./gradlew :canvas-server:compileTestJava
./gradlew runDev   # runtime + test-plugin
# Watch console for TEST-PASS / TEST-FAIL from test-plugin
```

## Cross-References

- `/canvas-verify-build` — full apply → compile → test → rbp → runDev pipeline. This skill focuses on the test layer.
- `/canvas-region-threading` — CRS/AFFINITY, `TickThread` guards, scheduler selection. Required reading for integration tests.
- `/canvas-config-system` — config tests, per-world config validation.
- `/canvas-build-system` — Gradle configuration-cache + parallel settings that affect test execution.

## Pitfalls

1. **Off-thread world access in tests** — calling `entity.getLocation()` from the JUnit thread throws. Run on a mock `TickThread`.
2. **Shared scheduler across tests** — state leaks; create a fresh `AffinitySchedulerThreadPool` per test.
3. **`Thread.sleep` + assert** — flaky. Use `Awaitility` or latches.
4. **Order-dependent assertions** — region thread scheduling is non-deterministic; assert on final state, not call order.
5. **Unit tests touching NMS** — `MinecraftServer` is null without `runDev`. Keep unit tests pure.
6. **No test-plugin in CI** — `runDev` is manual; CI runs `./gradlew test` only. Runtime tests need a separate CI stage or manual verification.
7. **Mocking away `ensureTickThread`** — don't. The guard is the behavior under test; mocking it defeats the purpose.
