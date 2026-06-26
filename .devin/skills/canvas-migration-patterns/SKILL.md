---
name: canvas-migration-patterns
description: Use whenever migrating Canvas between Minecraft versions, porting patches across versions, handling API deprecations, absorbing upstream Paper changes, or ensuring config/plugin compatibility across version bumps. Covers MC version migration workflow (26.2 to next), API deprecation detection, patch porting patterns, config migration, plugin API migration guides, backward compatibility shims, and common 26.1 to 26.2 migration patterns (EntityType to EntityTypes, Profiler removal). Triggers on "migrate", "migration", "26.2 to 26.3", "API change", "breaking change", "deprecation", "port patch", "upstream sync", "version bump", "shim", "backward compat".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Migration Patterns

Canvas tracks Paper's `dev/26.2` branch (see `gradle.properties` →
`paperCommit`). Each MC version bump requires: absorbing upstream
changes, porting Canvas-specific patches, migrating the API, and
preserving config/plugin compatibility. This skill covers the workflow
and patterns for each step.

Sources: DeepWiki `CraftCanvasMC/Canvas` + `PaperMC/Paper`; local
`gradle.properties`, `roadmap.md`, `upstream.sh`,
`canvas-server/minecraft-patches/`.

## When to Use

Invoke this skill when the user mentions:
- "migrate", "migration", "26.2 to 26.3", "version bump"
- "API change", "breaking change", "deprecation"
- "port patch", "upstream sync", "absorb changes"
- "shim", "backward compat", "config migration"

## MC Version Migration Workflow

Step-by-step from one MC version to the next (e.g., 26.2 → 26.3):

1. **Read `gradle.properties` + `roadmap.md`** — confirm current
   `paperCommit`, `mcVersion`, `apiVersion`. These drift; never assume.
2. **Update upstream** — `./upstream.sh update` pulls the latest Paper
   commit for the target branch. See `/canvas-upstream-sync`.
3. **Apply upstream changes** — `./upstream.sh apply` attempts to
   apply Canvas patches on top of the new Paper. Conflicts surface
   here.
4. **Resolve conflicts** — for each failed patch:
   - Read the new upstream code at the conflict site.
   - Re-apply the Canvas change with minimal diff (see
     `/canvas-patch-authoring`).
   - Preserve the patch's intent, not its exact lines (upstream may
     have refactored).
5. **Rebuild patches** — `./rbp.sh --force` regenerates patch files
   from the resolved source.
6. **Migrate the API** — apply `canvas-api/paper-patches/base/` on the
   new Paper API. Resolve conflicts the same way.
7. **Migrate configs** — ensure `global.yml` schema is backward
   compatible (see Config Migration below).
8. **Verify** — `./gradlew applyAllPatches` → compile → `./gradlew
   test` → `./gradlew runDev`. See `/canvas-verify-build`.
9. **Update `gradle.properties`** — bump `mcVersion`, `apiVersion`,
   `paperCommit` to the new values.
10. **Document** — note breaking changes in `roadmap.md` and the PR
    description.

```bash
# The migration loop
./upstream.sh update
./upstream.sh apply
# ... resolve conflicts ...
./rbp.sh --force
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew test
./gradlew runDev
```

## API Deprecation Detection

When upstream (Paper/Mojang) deprecates APIs Canvas uses:

- **Find `@Deprecated`** — grep the new upstream for newly added
  `@Deprecated` annotations on APIs Canvas references.
- **Check `@Deprecated(forRemoval = true)`** — these will be removed
  in the next version; prioritize migration.
- **Compiler warnings** — `./gradlew compileJava` emits deprecation
  warnings. Review them; don't suppress with `@SuppressWarnings`
  unless migration is genuinely blocked.
- **Canvas-specific deprecations** — Canvas may deprecate its own
  APIs (e.g., old scheduler methods replaced by CRS). Follow the
  deprecation timeline (see `/canvas-api-evolution`).

```bash
# After applying new upstream, check for new deprecations
./gradlew :canvas-server:compileJava 2>&1 | grep -i "deprecat"
./gradlew :canvas-api:compileJava 2>&1 | grep -i "deprecat"
# Find Canvas's own deprecations
grep -rn "@Deprecated" canvas-api/paper-patches/ canvas-server/minecraft-patches/
```

## Patch Porting Patterns

Porting a Canvas patch from one MC version to another:

- **Minimal hunk preservation** — keep the Canvas-specific change;
  discard context lines that no longer match. Re-anchor on stable
  context (method signatures, unique strings).
- **Re-anchor on signatures** — if upstream refactored a method body,
  anchor the patch on the method signature + a unique identifier
  (e.g., a field name, a log string).
- **Split if upstream split** — if upstream split one method into two,
  split the Canvas patch accordingly. One Canvas concern may now span
  two patch hunks.
- **Merge if upstream merged** — if upstream merged two methods,
  merge the Canvas hunks into one.
- **Preserve intent, not lines** — the patch's *purpose* (e.g.,
  "route this tick through the region scheduler") must survive; the
  exact code may change.

```bash
# Find patches that failed to apply
./upstream.sh apply 2>&1 | grep -i "fail\|conflict\|patch did not apply"
# Inspect a specific patch
cat canvas-server/minecraft-patches/base/0007-Add-watchdog-thread.patch
```

See `/canvas-patch-lifecycle` for the full Weaver task flow and
`/canvas-patch-authoring` for marking conventions.

## Config Migration

Configs must survive version bumps. Patterns:

- **Additive schema** — new config keys get defaults; old keys remain valid (forwarded to new behavior if renamed). Never remove a key without a deprecation cycle.
- **Key renaming** — if a key is renamed (e.g., `region.scheduler.threads` → `region.scheduler.thread-count`), read the old key as a fallback during migration, log a warning, write the new key on next save.
- **Versioned config** — `global.yml` should carry a `config-version` field. On load, if the version is older, run migration steps.
- **Per-world config** — same rules apply to per-world configs (see `/canvas-config-system`).

```bash
grep -rn "config-version\|configVersion\|migrate" canvas-server/src/main/java/io/canvasmc/canvas/config/ 2>/dev/null
```

## Plugin API Migration Guide

When Canvas's API changes in a way that affects plugins, publish a migration guide:

- **List removed/renamed methods** — old signature → new signature.
- **Scheduler migration** — the most common: `Bukkit.getScheduler()` → `RegionScheduler` / `EntityScheduler` / `GlobalRegionScheduler` / `AsyncScheduler`. Provide a decision table (see `/canvas-plugin-compat`).
- **Config migration** — if config keys changed, document old → new.
- **Code examples** — before/after snippets for common patterns.
- **Deadline** — when will the old API be removed? (See deprecation timeline in `/canvas-api-evolution`.)

## Backward Compatibility Strategies

- **Shim patterns** — keep an old method that delegates to the new implementation:
  ```java
  /** @deprecated use {@link #newMethod(Location)} */
  @Deprecated
  public void oldMethod(int x, int y, int z) { newMethod(new Location(world, x, y, z)); }
  ```
- **Deprecated method forwarding** — the old method calls the new one; no duplicated logic. Mark `@Deprecated` with `since` and `forRemoval`.
- **Behavioral compatibility** — if the new behavior differs (e.g., async vs sync), the shim must preserve old behavior or document the change. Silent behavior changes break plugins.
- **Removal timeline** — deprecate in version N, warn in N+1, remove in N+2 (see `/canvas-api-evolution`).

## Common 26.1 → 26.2 Migration Patterns

These patterns were observed in the 26.1 → 26.2 transition (document in `roadmap.md` as new ones emerge):

- **`EntityType` → `EntityTypes`** — Mojang renamed the registry holder class. Canvas patches referencing `EntityType.X` updated to `EntityTypes.X`. Grep for stale references after a bump.
- **Profiler removal** — Canvas patch `0008-Remove-Vanilla-Profiler` removed `Profiler.get().push(...)`. Any upstream code reintroducing profiler calls must be re-patched. See `/canvas-region-profiling`.
- **Scheduler API consolidation** — Folia's scheduler interfaces absorbed and renamed to Canvas's CRS (`RegionScheduler`, etc.). Patches referencing Folia names updated to Canvas names.
- **Watchdog replacement** — old Folia watchdog code removed (patch `0009`); Canvas's `FoliaWatchdogThread` (patch `0007`)
  replaces it. Don't reintroduce old watchdog references.

```bash
# Check for stale 26.1 references after a bump
grep -rn "EntityType\." canvas-server/minecraft-patches/ | grep -v "EntityTypes\."
grep -rn "Profiler.get\|profiler.push" canvas-server/minecraft-patches/
grep -rn "folia\|Folia" canvas-server/minecraft-patches/ | grep -iv "canvas\|watchdog"
```

## Upstream Sync as Migration

When Paper updates (not a full MC version bump, just a commit bump),
Canvas absorbs the changes. This is a *mini-migration*:

- **`./upstream.sh update`** — fetch the new Paper commit.
- **`./upstream.sh apply`** — apply Canvas patches on the new commit.
- **Resolve conflicts** — usually smaller than a full version bump.
- **`./rbp.sh --force`** — regenerate patches.
- **Verify** — compile + test + runDev.

See `/canvas-upstream-sync` for the full dual-upstream workflow
(Paper direct + Canvas OG).

## Migration Workflow Summary

```
read gradle.properties + roadmap.md
  → ./upstream.sh update
  → ./upstream.sh apply
  → resolve conflicts (preserve intent, minimal diff)
  → ./rbp.sh --force
  → migrate API (canvas-api/paper-patches/)
  → migrate configs (additive + versioned)
  → ./gradlew applyAllPatches → compile → test → runDev
  → update gradle.properties (mcVersion, apiVersion, paperCommit)
  → document breaking changes in roadmap.md + PR
```

## Verification

```bash
./upstream.sh update
./upstream.sh apply
./rbp.sh --force
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew :canvas-api:compileJava
./gradlew test
./gradlew runDev
# Confirm: no stale 26.1 references, configs load, plugins still work
```

## Cross-References

- `/canvas-upstream-sync` — dual-upstream sync workflow (Paper + Canvas OG); this skill covers the migration lens.
- `/canvas-refactor-patterns` — minimal diff, layer respect; applies to conflict resolution during migration.
- `/canvas-api-evolution` — API stability guarantees, deprecation timeline, compatibility shims.
- `/canvas-patch-lifecycle` — Weaver task flow, `rbp.sh`, patch regeneration.
- `/canvas-config-system` — config schema, per-world configs, migration versioning.
- `/canvas-verify-build` — the full verify pipeline post-migration.

## Pitfalls

1. **Don't assume API stability across MC versions** — Mojang renames/removes NMS classes freely. Always grep the new upstream.
2. **Don't preserve patch lines, preserve intent** — upstream refactors; the Canvas change must adapt, not rot.
3. **Config removal breaks servers** — never remove a config key without a deprecation cycle. Rename with fallback read.
4. **Suppressing deprecation warnings hides migration debt** — fix the deprecation, don't `@SuppressWarnings` it (unless genuinely blocked, with a TODO).
5. **Forgetting `canvas-api` patches** — migration isn't just server; the API patches need porting too.
6. **`rbp.sh` before `applyAllPatches`** — regenerate patches only after the source compiles; otherwise you capture broken state.
7. **Not updating `gradle.properties`** — `mcVersion` / `apiVersion` / `paperCommit` must reflect the new target; stale values cause confusion in future migrations.
