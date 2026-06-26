---
name: canvas-plugin-compat
description: Use whenever working on plugin compatibility for Canvas — folia-supported declaration, paper-plugin.yml format, scheduler migration for plugins (RegionScheduler/EntityScheduler/GlobalRegionScheduler/AsyncScheduler API usage), testing plugins with runDev, plugin compatibility layers, and common plugin migration patterns. Triggers on "plugin compat", "folia-supported", "paper-plugin.yml", "plugin scheduler", "plugin migration", "runDev plugin", "plugin yml", "folia supported", "plugin test".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
argument-hint: "[plugin-name]"
---

# Canvas Plugin Compatibility

Canvas is **not** a drop-in replacement for Paper/Purpur. It uses region
threading (Folia-level), so plugins must declare `folia-supported: true` and
use the region schedulers instead of `Bukkit.getScheduler()`.

## Argument

`[plugin-name]` — optional. The plugin to migrate or audit. When given, grep
for that plugin's scheduler usage and produce a migration diff. When omitted,
provides general plugin-compat guidance.

## folia-supported Declaration

In `paper-plugin.yml` (or `plugin.yml`):
```yaml
folia-supported: true
```

Canvas's build system auto-sets this for `-debug` / `-plugin` projects:
```kotlin
// build.gradle.kts (root, subprojects block)
extensions.configure<xyz.jpenilla.resourcefactory.paper.PaperPluginYaml> {
    apiVersion.set(providers.gradleProperty("apiVersion"))
    version = "SNAPSHOT-DEV"
    authors = listOf("CanvasMC")
    foliaSupported = true
}
```

**Without `folia-supported: true`**, Canvas will not load the plugin (it
assumes the plugin isn't thread-safe).

## paper-plugin.yml Format

Canvas uses the Paper plugin format (`paper-plugin.yml`), not the legacy
`plugin.yml`. Key fields:
```yaml
name: MyPlugin
version: 1.0.0
main: com.example.MyPlugin
api-version: '1.21'
folia-supported: true
author: YourName
```
- `folia-supported: true` is the Canvas-specific gate.
- `api-version` should match the Canvas `apiVersion` gradle property (MC 26.2).
- Use `paper-plugin.yml` for new plugins; legacy `plugin.yml` is supported but
  `paper-plugin.yml` is preferred for region-aware plugins.

## Scheduler Migration (Paper plugin → Canvas)

### Legacy Paper (BROKEN on Canvas)
```java
// DON'T — no main thread exists in Canvas
Bukkit.getScheduler().runTask(plugin, () -> { ... });
Bukkit.getScheduler().runTaskLater(plugin, () -> { ... }, 20L);
Bukkit.getScheduler().runTaskTimer(plugin, () -> { ... }, 0L, 20L);
```

### Canvas-compatible equivalents
```java
// By location — use when you know the block/location to tick on
Bukkit.getRegionScheduler().execute(location, () -> { ... });
Bukkit.getRegionScheduler().runDelayed(plugin, task -> { ... }, 20L);

// By entity — follows the entity across regions
entity.getScheduler().execute(plugin, () -> { ... }, null, 1L);
entity.getScheduler().runDelayed(plugin, task -> { ... }, null, 20L);

// Global region — world time, weather, console commands
Bukkit.getGlobalRegionScheduler().runDelayed(plugin, task -> { ... }, 20L);

// Async — no world/entity/block access allowed
Bukkit.getAsyncScheduler().runNow(plugin, task -> { ... });
Bukkit.getAsyncScheduler().runDelayed(plugin, task -> { ... }, 20L, TimeUnit.SECONDS);
```

### API selection guide
| You need to touch... | Use |
|----------------------|-----|
| A block/location | `RegionScheduler` (by location) |
| An entity | `EntityScheduler` (follows entity) |
| Global state (weather, time, console) | `GlobalRegionScheduler` |
| Pure compute, no world data | `AsyncScheduler` |

## Common Plugin Migration Patterns

### Pattern: Repeating task on a location
```java
// Before
Bukkit.getScheduler().runTaskTimer(plugin, () -> doWork(loc), 0L, 20L);
// After
Bukkit.getRegionScheduler().runAtFixedRate(plugin, loc, task -> doWork(loc), 0L, 20L);
```

### Pattern: Delayed task on an entity
```java
// Before
Bukkit.getScheduler().runTaskLater(plugin, () -> entity.doThing(), 20L);
// After
entity.getScheduler().runDelayed(plugin, task -> entity.doThing(), null, 20L);
```

### Pattern: Async work then back to region
```java
// Before
Bukkit.getScheduler().runTaskAsynchronously(plugin, () -> {
    var data = compute();
    Bukkit.getScheduler().runTask(plugin, () -> apply(data));
});
// After
Bukkit.getAsyncScheduler().runNow(plugin, task -> {
    var data = compute();
    Bukkit.getRegionScheduler().execute(loc, () -> apply(data));
});
```

### Pattern: Event handler
- Event handlers run on the region thread that owns the event's data.
- Safe to access the event's world/entity/block. Not safe to reach into other
  regions.
- For cross-region work, schedule on the target region's scheduler.

### Pattern: Command handler
- Commands run on the global region thread.
- For region-specific work, schedule via `RegionScheduler` / `EntityScheduler`.

## Testing Plugins with runDev

Canvas's `runDev` task starts a dev server that auto-loads plugins from
`*-plugin` or `*-debug` directories.

1. Create a `-debug` or `-plugin` subproject (or drop a jar in the load dir)
2. The build system applies `resource-factory-paper-convention` + sets
   `foliaSupported = true`
3. Run: `./gradlew runDev`
4. The plugin loads automatically — test in the dev server
5. Watch the console for:
   - "Plugin X is not supported on Folia" warnings (missing
     `folia-supported: true`)
   - `IllegalStateException` from wrong-thread access
   - Scheduler-related errors

## Plugin Migration Checklist

- [ ] Add `folia-supported: true` to `paper-plugin.yml`
- [ ] Replace all `Bukkit.getScheduler().runTask*` with region schedulers
- [ ] Replace `Bukkit.getScheduler().runTaskAsynchronous` with `AsyncScheduler`
- [ ] Remove `Bukkit.isPrimaryThread()` checks (always false, meaningless)
- [ ] Audit event handlers — ensure they don't access data from other regions
- [ ] Audit commands — schedule region-owned work correctly
- [ ] Audit cached `Entity`/`World` references — may cross regions
- [ ] Test with `./gradlew runDev`

## Common Plugin Pitfalls on Canvas

| Pattern | Problem | Fix |
|---------|---------|-----|
| `Bukkit.getScheduler().runTask(...)` | No main thread | Use `RegionScheduler` / `EntityScheduler` |
| `Bukkit.isPrimaryThread()` | Always false | Remove; use `TickThread.isTickThreadFor(...)` if needed |
| Caching `Entity` references across ticks | Entity may change region | Use `EntityScheduler` |
| Accessing `world` from async | Region-owned data | Schedule on `RegionScheduler` |
| `Player.getLocation()` from async | Region-owned | Schedule on `EntityScheduler` |
| Assuming synchronous chunk load | Chunks load async | Use chunk load callbacks |

## Finding Plugin-Compat Code in Canvas

```bash
# folia-supported handling
grep -rn "foliaSupported\|folia-supported" canvas-server/src/minecraft/java/ 2>/dev/null

# Plugin loading / scheduler API
grep -rn "RegionScheduler\|EntityScheduler\|GlobalRegionScheduler\|AsyncScheduler" canvas-api/ 2>/dev/null

# Plugin yml parsing
grep -rn "paper-plugin\|PaperPluginYaml" canvas-server/src/minecraft/java/ 2>/dev/null
```

## Verification

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew runDev
# Load the plugin, test all features, watch for:
# - "Plugin X is not supported on Folia" warnings
# - IllegalStateException from wrong-thread access
# - Scheduler-related errors
```

## Plugin Audit Tool

A systematic audit determines whether a plugin is region-threading compatible
and what migration work it needs.

### Audit procedure

1. **Check `paper-plugin.yml` / `plugin.yml`** — does it declare
   `folia-supported: true`? If not, Canvas won't load it.
2. **Grep for legacy scheduler calls**:
   ```bash
   grep -rn "Bukkit\.getScheduler\|getScheduler\(\)\.runTask" plugin-src/
   # Every hit must be migrated to a region scheduler
   ```
3. **Grep for main-thread assumptions**:
   ```bash
   grep -rn "isPrimaryThread\|Bukkit\.isPrimaryThread" plugin-src/
   # Every hit is broken — there is no main thread in Canvas
   ```
4. **Grep for async world/entity access**:
   ```bash
   grep -rn "runTaskAsynchronously\|runAsync\|CompletableFuture" plugin-src/
   # Check each: does the async body touch world/entity/block data?
   ```
5. **Grep for cached entity/world references**:
   ```bash
   grep -rn "private.*Entity\|private.*World\|static.*Entity" plugin-src/
   # Cached references may cross region boundaries between uses
   ```
6. **Audit event handlers** — do they access data outside the event's region?
   (e.g. a block-break handler reading a distant chunk.)
7. **Audit commands** — commands run on the global region; region-specific
   work must be scheduled.
8. **Run with `./gradlew runDev`** — load the plugin, watch for
   `IllegalStateException`, `"not supported on Folia"`, scheduler errors.

### Audit report format

Produce a report per plugin:
- **Compatible as-is** — already uses region schedulers, declares
  `folia-supported: true`.
- **Needs migration** — list each broken pattern with file:line and the
  required scheduler replacement.
- **Incompatible** — relies on a single main thread in a way that can't be
  migrated without a rewrite (e.g. global mutable state touched from every
  event).

See `/canvas-plugin-testing` (if created) for automated plugin compatibility
test harnesses.

## Common Plugin Migration Patterns (concrete examples)

Beyond the basic scheduler swaps, these concrete patterns recur across
plugins migrating to Canvas.

### Pattern: Global state cache updated from events

```java
// BEFORE — assumes single thread, no synchronization
private static final Map<UUID, PlayerData> CACHE = new HashMap<>();
@EventHandler void onJoin(PlayerJoinEvent e) { CACHE.put(e.getPlayer().getUniqueId(), load(e.getPlayer())); }
@EventHandler void onQuit(PlayerQuitEvent e) { CACHE.remove(e.getPlayer().getUniqueId()); }
```
**Problem**: `HashMap` touched by multiple region threads (join/quit events
fire on the player's region thread) → `ConcurrentModificationException` /
silent corruption.
**Fix**: Use `ConcurrentHashMap`, or partition the cache per-world/region.
```java
private static final ConcurrentHashMap<UUID, PlayerData> CACHE = new ConcurrentHashMap<>();
```

### Pattern: Scheduled repeating task touching a fixed location

```java
// BEFORE
Bukkit.getScheduler().runTaskTimer(plugin, () -> {
    world.getBlockAt(x, y, z).setType(Material.STONE);
}, 0L, 20L);
```
**Fix**: `RegionScheduler.runAtFixedRate` with the location.
```java
Bukkit.getRegionScheduler().runAtFixedRate(plugin, new Location(world, x, y, z), task -> {
    world.getBlockAt(x, y, z).setType(Material.STONE);
}, 0L, 20L);
```

### Pattern: Async DB query then apply to entity

```java
// BEFORE
Bukkit.getScheduler().runTaskAsynchronously(plugin, () -> {
    var data = db.query(player.getUniqueId());
    Bukkit.getScheduler().runTask(plugin, () -> player.sendMessage(data));
});
```
**Fix**: Async for the query, `EntityScheduler` for the apply (follows the
entity across regions).
```java
Bukkit.getAsyncScheduler().runNow(plugin, task -> {
    var data = db.query(player.getUniqueId());
    player.getScheduler().execute(plugin, () -> player.sendMessage(data), null, 1L);
});
```

### Pattern: Block physics / redstone loop

```java
// BEFORE — runs on main thread, touches blocks across the world
for (Block b : blocks) b.getState().update();
```
**Fix**: Each block update must run on the region owning that block. Group
blocks by region and schedule per-region, or schedule each via
`RegionScheduler.execute(loc, ...)`.
```java
for (Block b : blocks) {
    Bukkit.getRegionScheduler().execute(b.getLocation(), () -> b.getState().update());
}
```

### Pattern: Cross-region teleport with post-teleport work

```java
// BEFORE
player.teleport(loc);
Bukkit.getScheduler().runTaskLater(plugin, () -> player.sendMessage("Arrived!"), 10L);
```
**Fix**: Use `EntityScheduler` for the teleport and the follow-up — the
entity may cross region boundaries on teleport.
```java
player.getScheduler().execute(plugin, () -> player.teleport(loc), null, 1L);
player.getScheduler().runDelayed(plugin, task -> player.sendMessage("Arrived!"), null, 10L);
```

## Pitfalls

1. **`folia-supported: true` is required** — without it, Canvas won't load the
   plugin.
2. **Most Paper plugins need changes** — region threading breaks the
   single-main-thread assumption.
3. **Event handlers run on the region thread** — they can access their
   region's data, but not other regions'.
4. **Commands run on the global region** — use schedulers for region-specific
   work.
5. **Async tasks must not touch world data** — schedule back to a region
   scheduler.
