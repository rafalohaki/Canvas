---
name: canvas-verify-build
description: Full verification pipeline after any change — apply patches, compile, test, rbp, runDev. Enforce before declaring done. Covers test authoring for Canvas, verification after patch/refactor/upstream-sync changes, and CI verification commands. Triggers on "verify", "is it done", "check build", "after change", "pre commit", "did it work", "write test", "add test", "after refactor", "after upstream".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - edit
argument-hint: "[stage]"
subagent: true
---

# Canvas Verify Build

Never say "done" without running the pipeline. Verification is self-contained
and runs as a subagent so the parent session keeps working.

## Argument

`[stage]` — optional. One of: `apply`, `compile`, `test`, `rbp`, `runDev`,
`full` (default), `ci`. Runs only that stage when given; runs the full
sequence when omitted.

## Required Sequence (in order)

1. `./gradlew applyAllPatches --no-configuration-cache`
   - Must succeed with zero unexpected rejects.
   - Check `canvas-server/minecraft-patches/rejected/` is empty or only expected.

2. Compile
   ```bash
   ./gradlew :canvas-api:compileJava
   ./gradlew :canvas-server:compileJava
   ```

3. Tests
   ```bash
   ./gradlew test
   ```

4. Rebuild patches (if you edited source)
   ```bash
   ./rbp.sh          # the fixed version without folia garbage
   # or manually:
   # ./gradlew fixupMinecraftFilePatches rebuildMinecraftSourcePatches ...
   ```

5. (Optional but recommended for runtime changes)
   ```bash
   ./gradlew runDev
   # or runPaperclip / runBundler as appropriate
   ```

## Test Authoring for Canvas

### Identify the test framework first
```bash
grep -rn "@Test\|JUnit\|jupiter" canvas-server/src/test/ 2>/dev/null | head
grep -rn "testImplementation\|junit" build.gradle.kts gradle.properties 2>/dev/null
```
Canvas uses JUnit 5 (Jupiter). Match existing test style — do not introduce a
new framework.

### Unit tests
- Location: `canvas-server/src/test/java/` (mirror the package of the class under test).
- Name: `<ClassUnderTest>Test.java`.
- Cover the happy path AND edge cases: null inputs, boundary values, empty
  collections, overflow, concurrent access where relevant.
- One assertion focus per test method; use `@Nested` to group edge cases.
- Use `@DisplayName` for human-readable intent.

### Integration tests (region threading)
- Tests that touch world/entity/block data must run on the correct tick
  thread. Use the scheduler APIs (`RegionScheduler`, `EntityScheduler`) —
  never access region-owned data from the test thread directly.
- For scheduler-dependent tests, use a `runDev` cycle: drop a `-debug` plugin
  that exercises the path and assert via console output or a test hook.
- Assert thread ownership with `TickThread.isTickThreadFor(...)` where
  applicable.

### runDev plugin testing
- Create a `*-debug` or `*-plugin` subproject (build system auto-sets
  `foliaSupported = true`).
- Exercise the changed behavior in-game; watch the console for
  `IllegalStateException` (wrong-thread) and scheduler errors.
- See `/canvas-plugin-compat` for the plugin scaffold.

### Coverage gaps
- Before declaring a change done, grep for the symbol you touched and confirm
  a test exists for each public entry point:
  ```bash
  grep -rn "<changedSymbol>" canvas-server/src/test/ 2>/dev/null
  ```
- If no test covers it, add one. Cite the gap in the PR description if it
  cannot be tested (e.g., pure visual change).

## Verification After Patch Changes

- After editing any patch file or source under
  `canvas-server/minecraft-patches/` or `canvas-api/paper-patches/`:
  1. `./gradlew applyAllPatches --no-configuration-cache` — confirms the
     patch still applies cleanly.
  2. `./rbp.sh` — confirms the patch regenerates from source without drift.
  3. `git diff --stat` — only the intended patches should change.
- If a base patch was edited, verify `index` lines are present (required for
  `git am --3way`).

## Verification After Refactoring

- Run the full sequence (apply → compile → test → rbp).
- Pay extra attention to `./gradlew test` — refactors often shift call sites
  that existing tests exercise.
- Grep for callers of any moved/renamed symbol:
  ```bash
  grep -rn "<oldSymbol>" canvas-server/src/ canvas-api/src/ 2>/dev/null
  ```
  Any remaining reference = incomplete refactor.
- Confirm `./rbp.sh` produces no unexpected patch growth (minimal diff — see
  `/canvas-refactor-guard`).

## Verification After Upstream Sync

After `./upstream.sh update|apply|rebuild|full` (Paper bump or Canvas OG
absorb):
- Full sequence + review that only `local/` patches grew (`canvas/` should be
  clean import or small delta).
- Update `paperCommit` and/or `canvasCommit` in `gradle.properties`.
- Update `roadmap.md` summary.
- Re-run `./gradlew test` — upstream changes can break assumptions in
  Canvas-original patches. Investigate every new failure, do not dismiss as
  "flaky" without evidence.
- See `/canvas-upstream-sync` for the full sync workflow.

## CI Verification Commands

For local CI parity (mirror what GitHub Actions would run):
```bash
# Full pipeline, clean state
./gradlew clean
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-api:compileJava :canvas-server:compileJava
./gradlew test
./rbp.sh
./gradlew createPaperclipJar   # confirms a distributable jar builds
```
- `createPaperclipJar` is the release artifact — always build it before
  tagging a release.
- See `/canvas-pr-workflow` for the GitHub Actions workflow setup (build +
  upstream-check).

### Stage `ci` — GitHub Actions CI verification

When invoked with `ci` stage, run the exact commands GitHub Actions executes:

```bash
# 1. Clean + apply (CI always starts fresh)
./gradlew clean
./gradlew applyAllPatches --no-configuration-cache

# 2. AT verification — check all 4 AT files are present and valid
test -f build-data/canvas.at     || echo "MISSING: canvas.at"
test -f build-data/folia.at      || echo "MISSING: folia.at"
test -f build-data/paperApi.at   || echo "MISSING: paperApi.at"
test -f build-data/paperServer.at || echo "MISSING: paperServer.at"

# 3. Compile both subprojects
./gradlew :canvas-api:compileJava :canvas-server:compileJava

# 4. Tests
./gradlew test

# 5. Rebuild patches (confirms no drift)
./rbp.sh

# 6. Build distributable
./gradlew createPaperclipJar

# 7. Check for unexpected rejects
test -z "$(ls -A canvas-server/minecraft-patches/rejected/ 2>/dev/null)" \
  && echo "No rejects" || echo "REJECTS FOUND"
```

CI runs with `--no-configuration-cache` for all apply tasks (fresh state).

## Fast Feedback Loop During Work

While iterating:
- Edit → `applyAllPatches --no-configuration-cache` → compileJava (fast)
- Only full test + rbp when you think you're done with the change.

## Flaky Test Detection

Tests that pass and fail intermittently are common in region-threaded code.
Identify and handle them:

### Signs of flakiness
- Test passes on re-run without code changes.
- Test fails only on parallel execution (`--parallel`) but passes serially.
- Test fails only on CI but passes locally (or vice versa).
- Test involves threading, scheduling, or timing-dependent assertions.
- Test uses `Thread.sleep()` or fixed-time waits.

### Detection workflow
```bash
# Run a specific test class multiple times
./gradlew test --tests "io.canvasmc.canvas.SomeTest" -Dtest.repeat=10

# Run with parallel execution (exposes race conditions)
./gradlew test --parallel

# Run with a fresh apply state (rules out stale cache)
rm -rf canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
./gradlew applyAllPatches --no-configuration-cache
./gradlew test
```

### Handling flaky tests
1. **Document** — add a `@Disabled("flaky: <description>")` with a TODO and
   the file:line of the race condition.
2. **Fix the race** — prefer fixing over disabling. Common fixes:
   - Replace `Thread.sleep()` with proper scheduler synchronization.
   - Use `await()` with timeout instead of fixed waits.
   - Ensure region-owned data is accessed on the correct tick thread.
3. **Quarantine** — if can't fix immediately, move to a `@Disabled` test class
   and track in `roadmap.md`.
4. **Never dismiss as "flaky" without evidence** — run at least 3 times to
   confirm intermittent behavior. If it fails consistently, it's a real bug.

## Common Failures & Fixes

- apply fails after AT change → delete runCanvasSetup cache, re-apply.
- compile error on region threading code → touched something from wrong
  thread. Use scheduler correctly (see `/canvas-region-threading`).
- test fails on something unrelated → may be pre-existing flaky or needs the
  full apply state. Document with file:line if pre-existing.
- rbp.sh complains about folia tasks → old rbp.sh. Fix it first.
- `createPaperclipJar` fails after a patch change → a patch header or
  numbering issue; run `./rbp.sh --force` and re-check.
- `folia.at not found` → `build-data/folia.at` missing. Create it (absorbed
  from upstream Canvas) or sync from upstream.

## Exit Criteria for "This Change is Complete"

- applyAllPatches clean
- api + server compile clean
- tests pass (or known pre-existing failures documented with file:line)
- patches rebuilt and only the intended ones changed
- new/changed behavior has a test (or a documented reason it cannot)
- relevant skills/docs updated if behavior or process changed
- commit message cites sources (DeepWiki / commits / files)

Use this skill at the end of every non-trivial task.
