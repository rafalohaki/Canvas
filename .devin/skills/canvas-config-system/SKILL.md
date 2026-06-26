---
name: canvas-config-system
description: Use whenever working with Canvas configuration — per-world Canvas configs, global.yml threaded-regions section, config option adding/removing, config defaults, the 96+ config files system, config validation, or config migration on version bump. Triggers on "config", "configuration", "global.yml", "threaded-regions", "per-world config", "config option", "add config", "Canvas config", "config file", "config validation", "config migration".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - edit
argument-hint: "[config-name]"
---

# Canvas Config System

Canvas provides extensive, fully-documented configuration options (96+ config
files) including per-world Canvas configs and the `global.yml` →
`threaded-regions` section for region threading tuning.

## Argument

`[config-name]` — optional. A config key, file name, or section to focus on
(e.g. `threaded-regions`, `keepalive`, `per-world`). When omitted, provides
general config guidance.

## Config Locations

```bash
# Find all config files in source
grep -rl "config\|Config" canvas-server/src/minecraft/java/ 2>/dev/null | grep -i "config" | head -30

# Per-world configs (base patch 0010)
grep -rl "Per-world\|perWorld\|worldConfig" canvas-server/src/minecraft/java/ 2>/dev/null

# global.yml threaded-regions
grep -rn "threaded-regions\|threadedRegions" canvas-server/src/minecraft/java/ 2>/dev/null
```

**Always grep current source** — config keys and file locations shift between
versions. MC 26.2 APIs change; never guess from training data.

## Key Config Areas

### global.yml → threaded-regions
Region threading core config (see `/canvas-affinity-scheduler` for details):
- `threads` — tick pool worker count (`-1` = auto)
- `gridExponent` — region size (`2^n` chunks per side, default `4` = 16x16)
- `scheduler` — `EDF` or `FIFO`

### Per-world Canvas configs (base patch 0010)
Per-world overrides for Canvas-specific settings. Each world can have its own
Canvas config file. World-specific behavior must use the per-world config, not
global.

### Feature configs (feature patches)
- `0001-Purpur-Alternative-Keepalive` — alternative keepalive behavior
- `0002-Disable-Criterion-Trigger-Config` — criterion trigger toggle

## Adding a New Config Option

1. **Find the config class** — grep for an existing similar option:
   ```bash
   grep -rn "existingOption" canvas-server/src/minecraft/java/
   ```
2. **Add the field** — field + getter + default value, following existing
   style. Default must be sensible for most servers.
3. **Add to config file template** — find the `.yml` template in source
   patches, add with a comment explaining what it does. Canvas requires
   documented config; undocumented options fail review.
4. **Wire into logic** — read the config where the behavior is implemented.
   Never hardcode the default in logic — always read from config to avoid
   duplication.
5. **Rebuild patches**: `./rbp.sh`
6. **Test**: `./gradlew runDev`, change the config, verify behavior changes

## Config Defaults

- Sensible for most servers out of the box
- Documented in the template comment
- Matched between the config field default and the template value (no drift)
- Per-world where it makes sense — world-specific behavior uses per-world
  config, not global

## Config Validation

- Validate values on load — reject out-of-range values with a clear log
  message and fall back to the default. Do not crash the server on a bad
  config.
- For numeric ranges (e.g. `threads`, `gridExponent`), clamp or reject with a
  warning.
- For enum-like values (e.g. `scheduler: EDF|FIFO`), validate against the
  allowed set.
- Log the effective value at startup so operators can confirm their config
  was parsed.

## Config Migration on Version Bump

When a Canvas version changes config keys, defaults, or structure:
1. **Detect old keys** — on load, check for removed/renamed keys and log a
   migration warning (not an error).
2. **Rename mapping** — if a key was renamed, read the old key as a fallback
   and write the new key on next save.
3. **Default changes** — if a default changed, do not override an existing
   user value; only apply the new default to missing keys.
4. **Document migrations** — note in the PR description and changelog which
   keys changed and how.
5. **Backward compat** — if the option may exist in deployed configs, log a
   warning rather than crashing on unknown keys.

## When Removing a Config Option

1. **Check if anything reads it** — `grep -rn "optionName" canvas-server/src/minecraft/java/`
2. **Remove the reader first**, then the config field
3. **Remove from template** — the `.yml` template in source patches
4. **Keep backward compat** — if the option may exist in deployed configs, log
   a warning rather than crashing
5. **Rebuild + test**

## Verification

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew runDev
# In console: change the config, reload if supported, verify behavior
# Check config file generation: look in the dev server's config dir
# Confirm validation warnings appear for bad values
```

## Config Schema Validation

Beyond the basic "reject out-of-range values" rule, structured validation at
load time catches misconfiguration before it causes runtime misbehavior.

### Validate at load time

- **Numeric ranges** — clamp or reject with a warning. Log the effective
  value. Example: `threads` must be `-1` (auto) or `>= 1`; `gridExponent`
  must be `>= 0` and typically `<= 10` (regions of 1024+ chunks are
  impractical).
- **Enum-like values** — validate against the allowed set (e.g.
  `scheduler: EDF|WORK_STEALING|AFFINITY`, `guardSeverity:
  SILENT|LOG|THROW`). Reject unknown values with a warning + fallback to
  default.
- **Cross-field constraints** — e.g. CPU affinity requires
  `tickRegionAffinity` to have at least `threads` entries; validate the
  relationship, not just individual fields.
- **Per-world vs global** — a per-world key in the global section (or vice
  versa) should warn, not silently be ignored.

### Validation pattern

```java
// In the config load path
int threads = config.getInt("threaded-regions.threads", -1);
if (threads != -1 && threads < 1) {
    LOGGER.warn("threads={} invalid, falling back to -1 (auto)", threads);
    threads = -1;
}
```

- Log the effective value at startup so operators can confirm parsing.
- Never crash the server on a bad config — warn and fall back.
- Grep current source for existing validation patterns and follow them.

## Config Migration Testing

When a Canvas version changes config keys, defaults, or structure, verify
migrations don't break deployed configs.

### How to test migrations

1. **Keep an old config fixture** — check a representative `global.yml` /
   per-world config from the previous version into a test fixtures dir.
2. **Load with the new code** — start `./gradlew runDev` with the old config
   in place; confirm:
   - Renamed keys are read from the old name as fallback and rewritten to the
     new name on next save.
   - Removed keys log a migration warning (not an error) and are ignored.
   - New keys with changed defaults are applied only if missing (existing
     user values are preserved).
   - Unknown keys log a warning rather than crashing.
3. **Verify effective values** — check the startup log for the effective
   values; confirm they match expectations (old value preserved, or new
   default applied for missing keys).
4. **Round-trip save** — trigger a config save (if supported) and confirm the
   file now uses the new keys with the old values intact.
5. **Document the migration** — note in the PR/changelog which keys changed,
   renamed, or were removed.

### Migration test checklist

- [ ] Old config loads without error on new code
- [ ] Renamed keys: old name still read, new name written on save
- [ ] Removed keys: warning logged, no crash
- [ ] New defaults: applied only to missing keys, existing values preserved
- [ ] Unknown keys: warning, no crash
- [ ] Effective values logged at startup

## Config Performance

Config lookups are not free — in hot paths (per-tick, per-entity, per-block)
they add up. Cache and avoid repeated reads.

### Avoiding config lookups in hot paths

- **Read once, cache in a field** — for per-world or global config read every
  tick, read it at load/world-init time into a `static` or world-scoped field
  and reference the field in the hot path.
- **Invalidate on reload** — if the config can be reloaded at runtime, clear
  the cache and re-read. Use a `volatile` field or a generation counter.
- **Don't read config inside `Entity.tick` / `BlockEntity` loops** — read it
  once before the loop and pass the value down, or cache it on the
  world/region data.

### Caching patterns

```java
// Cached at world init, invalidated on reload
private volatile int cachedGridExponent;

void onLoad() {
    cachedGridExponent = config.getInt("threaded-regions.gridExponent", 4);
}

// Hot path reads the volatile field, not the config
int regionSize = 1 << cachedGridExponent;
```

- **`volatile` for single values** — cheap reads, safe across threads.
- **`AtomicReference` / `AtomicInteger`** — if the value is updated
  concurrently with reads.
- **Generation counter** — if multiple cached values must be invalidated
  together, bump a `volatile int generation` on reload and re-read all when it
  changes.
- **Per-world cache on `CanvasRegionizedWorldData`** — for per-world config,
  cache on the world's regionized data so each region reads the local cache.

### What NOT to do

- Don't call `config.getInt(...)` / `config.getString(...)` inside a per-tick
  loop — even fast map lookups add up at 20 TPS × thousands of entities.
- Don't cache config in a region-owned field without invalidation — a reload
  won't reach cached regions.
- Don't read config from async without caching — config objects may not be
  thread-safe for concurrent reads (verify the implementation; grep source).

## Pitfalls

1. **Config keys are version-specific** — don't assume key names from older
   Canvas versions; grep current source.
2. **Per-world vs global** — putting a per-world option in global config (or
   vice versa) breaks expectations.
3. **Missing template entry** — if you add a field but not the template line,
   the config file won't have it; users can't discover it.
4. **No comment** — Canvas requires documented config; undocumented options
   fail review.
5. **Hardcoded defaults in logic** — always read from config, don't duplicate
   the default in code.
6. **Silent bad values** — a bad config value that crashes or silently
   misbehaves is a bug; validate and warn.
