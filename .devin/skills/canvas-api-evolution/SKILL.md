---
name: canvas-api-evolution
description: Use whenever managing Canvas API changes, deprecations, breaking changes, or plugin compatibility — API stability guarantees, deprecation timeline (deprecate to warn to remove), breaking change detection, plugin API versioning via api-version in plugin.yml, compatibility shim patterns, API review checklist, Canvas-specific API additions beyond Bukkit/Paper (CRS scheduler, region data, etc.), and documentation requirements for API changes. Triggers on "API", "deprecate", "breaking change", "compatibility", "version", "Bukkit API", "Canvas API", "api-version", "shim", "stability guarantee", "API review".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas API Evolution

Canvas extends the Bukkit/Paper API with region-threading primitives
(CRS schedulers, region data access, entity scheduling). Managing API
changes requires: stability guarantees, a deprecation timeline, breaking
change detection, and compatibility shims. This skill covers the
policies and patterns for evolving the Canvas API without breaking the
plugin ecosystem.

Sources: DeepWiki `CraftCanvasMC/Canvas` + `PaperMC/Paper`; local
`canvas-api/paper-patches/`, `canvas-api/src/main/java/`,
`io.canvasmc.canvas.api.*`.

## When to Use

Invoke this skill when the user mentions:
- "API", "deprecate", "breaking change", "compatibility"
- "version", "Bukkit API", "Canvas API"
- "api-version", "shim", "stability guarantee", "API review"

## API Stability Guarantees

Canvas's API surface has three tiers with different stability promises:

| Tier | Surface | Stability | Example |
|------|---------|-----------|---------|
| Stable | Bukkit/Paper API (inherited) | High — matches Paper guarantees | `Bukkit.getPlayer`, `Location` |
| Stable | Canvas API (documented) | High — deprecation cycle required | `RegionScheduler`, `EntityScheduler` |
| Experimental | Canvas API (marked `@ApiStatus.Experimental`) | Low — may break without warning | New scheduler features, region data internals |

- **Stable API** — changes require a deprecation cycle (see below).
  Breaking changes need a major version bump + migration guide.
- **Experimental API** — annotated with
  `@org.jetbrains.annotations.ApiStatus.Experimental`. Plugins using
  these opt into breakage. No deprecation cycle required.
- **Internal API** — package-private or `@ApiStatus.Internal`. Not for
  plugin use. May change freely.

```bash
# Find experimental/internal API markers
grep -rn "@ApiStatus.Experimental\|@ApiStatus.Internal" canvas-api/paper-patches/ canvas-api/src/main/java/ 2>/dev/null
```

## Deprecation Timeline

Three-phase deprecation cycle for stable API:

1. **Deprecate (version N)** — mark `@Deprecated(since = "N", forRemoval = true)`.
   The method still works. Javadoc links to the replacement.
2. **Warn (version N+1)** — the deprecated method logs a warning on
   first call (once per plugin, not per call — avoid log spam). The
   method still works.
3. **Remove (version N+2)** — the method is removed. Plugins using it
   fail to compile/load. Migration guide published in N.

```java
// Phase 1: Deprecate
@Deprecated(since = "26.2", forRemoval = true)
public void oldSchedule(Location loc, Runnable task) {
    Bukkit.getLogger().warning("oldSchedule is deprecated, use RegionScheduler.execute");
    // forward to new API
    Bukkit.getRegionScheduler().execute(loc, task);
}
```

- **Never skip phases** — removing without a deprecation cycle breaks
  plugins silently.
- **`forRemoval = true`** signals intent to remove; plugins scanning
  annotations can prepare.
- **Javadoc** — every deprecated method must have
  `@deprecated use {@link #newMethod}` linking the replacement.

## Breaking Change Detection

A change is **breaking** if it:
- Removes or renames a public method/class in stable API.
- Changes a method signature (parameter types, return type, order).
- Changes behavior in a way plugins could depend on (e.g., sync →
  async, or throwing where it didn't before).
- Removes a config key (see `/canvas-config-system`).
- Changes a scheduler's thread affinity contract (e.g.,
  `RegionScheduler` now runs on a different thread).

**Detection workflow**:
1. Diff the API: `git diff canvas-api/paper-patches/` or
   `git diff canvas-api/src/main/java/`.
2. Check for removed public methods: `javap` on old vs new jars, or
   grep for method signatures that disappeared.
3. Check for signature changes: parameter types, return types.
4. Check for behavioral changes: read the patch, assess if plugins
   could depend on the old behavior.

```bash
# Diff the API patches
git diff canvas-api/paper-patches/
# Find removed public methods (compare old vs new)
git diff canvas-api/src/main/java/ | grep -E "^-.*public "
```

## Plugin API Versioning

Plugins declare compatibility via `plugin.yml`:

```yaml
name: MyPlugin
version: 1.0
api-version: '26.2'   # MC/Canvas API version
```

- **`api-version`** — Bukkit/Paper convention. Canvas honors it. A
  plugin with `api-version: '26.2'` expects the 26.2 API surface.
- **Canvas-specific versioning** — Canvas may add its own version
  marker (e.g., `canvas-api-version` in `paper-plugin.yml`) for
  Canvas-only APIs. Check current source for the field name.
- **Backward compat** — a plugin compiled against 26.1 should load on
  26.2 if it only uses stable API. Breaking changes require the
  plugin to update `api-version`.

```bash
grep -rn "api-version\|canvas-api-version\|paper-plugin" canvas-api/paper-patches/ canvas-server/minecraft-patches/ 2>/dev/null
```

## Compatibility Shim Patterns

Keep old methods working with new internals:

- **Forwarding shim** — old method delegates to new:
  ```java
  @Deprecated(since = "26.2", forRemoval = true)
  public void oldMethod() { newMethod(); }
  ```
- **Adapter shim** — old signature converts to new:
  ```java
  @Deprecated
  public void scheduleAt(Location loc, Runnable task) {
      Bukkit.getRegionScheduler().execute(loc, task);  // new API
  }
  ```
- **Behavioral shim** — preserve old behavior if new differs (e.g., block on async future for sync compat).
- **Warning shim** — log deprecation on first use (volatile flag to avoid log spam).

## API Review Checklist (10 items)

Run for every PR touching `canvas-api/`:

1. [ ] **Stability tier** — new API is marked `@ApiStatus.Experimental` or stable (documented). No accidental stable API.
2. [ ] **No silent removal** — removed methods went through the deprecation cycle (deprecate → warn → remove).
3. [ ] **`@Deprecated` has `since` + `forRemoval`** — and Javadoc `@deprecated` linking the replacement.
4. [ ] **No behavioral change without deprecation** — if behavior changes, deprecate the old method + add a new one.
5. [ ] **Thread affinity documented** — scheduler methods document which thread they run on (region tick, global tick, async).
6. [ ] **Nullability annotations** — `@NotNull` / `@Nullable` on parameters and returns (Paper convention).
7. [ ] **No NMS leaks** — public API doesn't expose NMS types (`net.minecraft.*`). Use Bukkit/Canvas wrappers.
8. [ ] **Config keys documented** — if the API reads config, the config key is documented in `global.yml` comments.
9. [ ] **Migration guide** — if breaking, a migration guide is in the PR description or `roadmap.md`.
10. [ ] **`api-version` bump** — if the API surface changed materially, bump `apiVersion` in `gradle.properties`.

## Canvas-Specific API Additions

Canvas adds APIs beyond Bukkit/Paper:

- **CRS (Canvas Region Scheduler)** — `RegionScheduler` (by location), `EntityScheduler` (follows entity), `GlobalRegionScheduler` (global tick), `AsyncScheduler` (off-tick, no world access). See `/canvas-region-threading`.
- **Region data access** — APIs to read region-owned data safely (must run on the owning tick thread). `TickThread.isTickThreadFor` / `ensureTickThread` are the guards.
- **AFFINITY scheduler config** — `region.scheduler.type`, `steal-threshold`, thread count. See `/canvas-affinity-scheduler`.
- **Per-world config API** — programmatic access to per-world config values. See `/canvas-config-system`.
- **Spark profiler API** — `/spark profiler --region` extension. See `/canvas-region-profiling`.

```bash
grep -rn "RegionScheduler\|EntityScheduler\|GlobalRegionScheduler\|AsyncScheduler" canvas-api/paper-patches/ canvas-api/src/main/java/ 2>/dev/null
grep -rn "TickThread\|isTickThreadFor\|ensureTickThread" canvas-api/paper-patches/ 2>/dev/null
```

## Documentation Requirements for API Changes

Every stable API change must include:

- **Javadoc** — method/class Javadoc explaining purpose, thread
  affinity, nullability, and (if deprecated) the replacement.
- **Changelog entry** — in the PR description or `roadmap.md`.
- **Migration guide** — for breaking changes: old → new signature,
  before/after code examples, deadline for removal.
- **Config docs** — if the API touches config, update `global.yml`
  comments and `/canvas-config-system` references.

## API Evolution Workflow

1. **Identify the change** — new API, deprecation, breaking change?
2. **Pick the stability tier** — stable, experimental, internal.
3. **If breaking stable API** — start the deprecation cycle (phase 1).
4. **Write the shim** — old method forwards to new.
5. **Document** — Javadoc, migration guide, changelog.
6. **Review** — run the 10-item API review checklist.
7. **Verify** — `./gradlew applyAllPatches` → compile API + server →
   `./gradlew test` → `runDev` with a test plugin using the old API
   (confirm shim works).
8. **Rebuild patches** — `./rbp.sh`.

## Verification

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-api:compileJava
./gradlew :canvas-server:compileJava
./gradlew test
./gradlew runDev
# Load a plugin using the deprecated API → confirm shim + warning works
```

## Cross-References

- `/canvas-migration-patterns` — version-to-version migration; this skill covers the API policy that migration follows.
- `/canvas-plugin-compat` — plugin compatibility, scheduler migration, `folia-supported` flag.
- `/canvas-code-review` — general review; this skill adds the API lens (10-item checklist).
- `/canvas-region-threading` — CRS scheduler API, `TickThread` guards.
- `/canvas-config-system` — config keys are part of the API surface; config changes need the same deprecation discipline.
- `/canvas-upstream-sync` — upstream Paper API changes flow through the same evolution pipeline.

## Pitfalls

1. **Silent behavioral changes** — changing what a method *does* without renaming it breaks plugins. Deprecate + add new instead.
2. **Removing without a cycle** — skip the deprecation timeline and plugins break on upgrade with no warning.
3. **NMS leaks in public API** — exposing `net.minecraft.*` types ties the API to NMS internals, which change every MC version. Use wrappers.
4. **Experimental API treated as stable** — plugins depend on it, then it breaks. Clearly mark `@ApiStatus.Experimental`.
5. **Missing thread-affinity docs** — a plugin calls `RegionScheduler.execute` expecting async; it runs on the region thread and blocks. Document the thread.
6. **Shim that changes behavior** — the shim must preserve old behavior exactly (or document the change). A shim that silently runs async instead of sync is a breaking change.
7. **Forgetting `api-version` bump** — if the API surface changed, `apiVersion` in `gradle.properties` should reflect it; plugins use it to gate features.
