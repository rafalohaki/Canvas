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
