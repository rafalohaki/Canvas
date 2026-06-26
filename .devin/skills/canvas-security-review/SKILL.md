---
name: canvas-security-review
description: Use whenever auditing Canvas security — plugin permission validation, command injection prevention, config file secret handling, network packet validation (size limits, malformed packets), dependency vulnerability scanning for CVEs, Access Transformer security (not exposing sensitive internals), NBT data validation from untrusted chunks/player data, and a 10-item PR security checklist. Triggers on "security", "vulnerability", "audit", "injection", "permission", "secret", "CVE", "packet validation", "NBT validation", "access transformer security", "dependency scan".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Security Review

Canvas inherits Minecraft's attack surface (network packets, player
input, chunk NBT, plugin permissions) and adds region-threading
concerns (cross-region data access, scheduler abuse). Security audits
focus on: untrusted input boundaries, permission enforcement, secret
handling, dependency CVEs, and Access Transformer exposure.

Sources: DeepWiki `CraftCanvasMC/Canvas` + `PaperMC/Paper`; local
`build-data/canvas.at`, `canvas-server/minecraft-patches/`,
`canvas-api/paper-patches/`.

## When to Use

Invoke this skill when the user mentions:
- "security", "vulnerability", "audit", "injection"
- "permission", "secret", "CVE"
- "packet validation", "NBT validation"
- "access transformer security", "dependency scan"

## Plugin Permission Validation

Plugins declare permissions in `plugin.yml`. Canvas (via Paper) honors
these. Audit for:

- **Command permissions** — every command handler must check
  `sender.hasPermission("canvas.xxx")` before acting. Missing checks
  let any player run admin commands.
- **`plugin.yml` permission defaults** — `default: op` is safe;
  `default: true` is dangerous (grants to all). Review any Canvas-bundled
  plugin's `plugin.yml`.
- **Permission attachment bypass** — patches that modify
  `Permissible` / `PermissionAttachment` must not weaken checks.

```bash
# Find permission checks in Canvas patches
grep -rn "hasPermission\|PermissionAttachment" canvas-server/minecraft-patches/ canvas-api/paper-patches/
# Check plugin.yml defaults
find . -name "plugin.yml" -exec grep -l "default: true" {} \;
```

## Command Injection Prevention

Minecraft commands parse user input. Risks:

- **String concatenation into dispatch** — never build command strings
  from user input and pass to `Bukkit.dispatchCommand`. Use
  `String[]` argument arrays.
- **Selector injection** — `@a`, `@e` selectors expand to multiple
  targets. Validate the resulting target list size before acting
  (e.g., a `@e` selector matching 10k entities could DoS a region).
- **Format string injection** — `String.format` with user input is
  safe in Java (no native format string exploits), but
  `String.format(userInput, ...)` can crash on malformed format
  specifiers. Validate first.
- **JSON/NBT injection in commands** — `/tellraw`, `/title` parse
  JSON. User-supplied JSON must be sanitized (no arbitrary SNBT
  payloads that allocate huge objects).

```bash
grep -rn "dispatchCommand\|Bukkit.dispatchCommand" canvas-server/minecraft-patches/
grep -rn "String.format\|String.join" canvas-server/minecraft-patches/sources/ | head -50
```

## Config File Security

Canvas config lives in `global.yml` + per-world configs (96+ files, see
`/canvas-config-system`). Audit for:

- **No secrets in configs** — database passwords, API tokens, RCON
  passwords must not be hardcoded in committed config defaults. Use
  env vars or a separate secrets file excluded from git.
- **Sensitive data handling** — `server.properties` fields like
  `rcon.password`, `level-seed` should not be logged at INFO. Check
  Canvas patches don't add logging that dumps these.
- **Config file permissions** — document that `global.yml` should be
  `chmod 600` on the server. Canvas can't enforce OS perms, but the
  docs should mention it.

```bash
grep -rni "password\|secret\|token\|api.key" canvas-server/src/main/java/io/canvasmc/canvas/config/ 2>/dev/null
grep -rni "rcon\|level-seed" canvas-server/minecraft-patches/ | grep -i "log\|print"
```

## Network Packet Validation

Minecraft's protocol is the primary attack surface. Canvas inherits
Paper's packet handling. Audit for:

- **Packet size limits** — `PacketUtils` / the connection handler
  enforces max packet size. Patches that increase the limit or add
  new packet handlers must preserve bounds. A malformed oversized
  packet can OOM the server.
- **Malformed packet handling** — NBT in packets (`Clientbound*`,
  `Serverbound*`) must be read with length prefixes. A truncated NBT
  payload should throw, not loop infinitely.
- **Rate limiting** — player packet rate is limited by Paper's
  `PacketRateLimiter`. Canvas patches that add packet handlers
  should respect the limiter, not bypass it.
- **Login packet validation** — `ServerboundHelloPacket` (login)
  carries username + profile properties. Validate username length,
  charset; don't trust profile properties without signature
  verification (Mojang's signed chat).

```bash
grep -rn "maxPacketSize\|PacketUtils\|PacketRateLimiter" canvas-server/minecraft-patches/
grep -rn "ServerboundHello\|LoginPacket" canvas-server/minecraft-patches/ | head -30
```

## Dependency Vulnerability Scanning

Canvas depends on Paper (which depends on Mojang's bundled Java + libraries). Audit transitive deps for CVEs:

- **Gradle dependency scan** — use `./gradlew dependencies` to list the full tree. Cross-reference high-severity deps against the NVD or GitHub Advisory Database.
- **Known risk areas** — Netty (networking), Guava (collections), Gson/Jackson (JSON parsing), log4j (logging — post-Log4Shell, ensure ≥ 2.17.1). Check `gradle.properties` + `build.gradle.kts` for pinned versions.
- **Mojang bundled libraries** — Minecraft ships its own bundled libs (e.g., Netty, Brigadier). These are pinned to MC's version; CVEs in them require a Paper/Mojang upstream fix, not a Canvas patch.

```bash
./gradlew dependencies --configuration runtimeClasspath 2>/dev/null | grep -i "netty\|log4j\|gson\|guava\|jackson"
```

## Access Transformer Security

Canvas's AT file (`build-data/canvas.at`, 87 lines) widens visibility of NMS fields/methods. Security concern: **exposing sensitive internals to plugins**.

- **Don't expose security-critical fields** — e.g., `PlayerConnection` internals, `MinecraftServer#stop` without guards, raw NBT deserializers. If a plugin can call `NbtIo#read` on untrusted data directly, it bypasses validation.
- **ATs are not a security boundary** — they're a convenience. The real boundary is the plugin sandbox (which Minecraft doesn't really have). Document that ATs expose internals; plugins using them are responsible for safe use.
- **Review AT additions in PRs** — every new line in `canvas.at` should justify why visibility widening is needed and confirm it doesn't
  expose a destructive operation.

```bash
cat build-data/canvas.at
# Review each line: is the widened member safe to expose?
grep -rn "stop\|shutdown\|read.*Nbt\|deserialize" build-data/canvas.at
```

See `/canvas-at-guard` for AT syntax and the POST-AT dependency cycle.

## NBT Data Validation

NBT (Named Binary Tag) is Minecraft's serialization format. Untrusted
NBT arrives via:

- **Chunk data** — loaded from disk or sent by clients (in
  multiplayer sync). A malicious chunk file can contain deeply nested
  or oversized NBT. `NbtIo` has depth/size limits; verify Canvas
  patches don't raise them unsafely.
- **Player data** — `player.dat` files. Same risk as chunks.
- **Item NBT** — items in player inventories carry NBT. A crafted
  item with a huge NBT payload can crash the server when loaded.
- **Entity NBT** — `/summon` with NBT, spawn eggs. Validate the NBT
  structure matches the entity type; reject unknown tags.

Audit checklist for NBT handling:
- [ ] Depth limit enforced (default ~512)
- [ ] Size limit enforced (default ~2MB per tag)
- [ ] Unknown tags rejected or ignored (not stored)
- [ ] No recursive deserialization without depth guard

```bash
grep -rn "NbtIo\|NbtAccounter\|MAX_DEPTH\|maxDepth" canvas-server/minecraft-patches/
grep -rn "NbtAccounter" canvas-server/src/main/java/ 2>/dev/null
```

## Security Checklist for PRs (10 items)

Run this for every PR touching Canvas:

1. [ ] **Permissions** — new commands check `hasPermission`; no
       `default: true` in `plugin.yml`.
2. [ ] **Input validation** — user input (commands, packets, NBT)
       is length/depth/size bounded.
3. [ ] **No secrets** — no hardcoded passwords, tokens, API keys in
       source or config defaults.
4. [ ] **No sensitive logging** — `rcon.password`, `level-seed`,
       player IPs not logged at INFO.
5. [ ] **Packet bounds** — new packet handlers preserve size limits;
       no `maxPacketSize` increase without justification.
6. [ ] **NBT limits** — NBT reads use `NbtAccounter`; no depth/size
       limit removal.
7. [ ] **AT review** — new `canvas.at` lines don't expose destructive
       or security-sensitive members.
8. [ ] **Dependency check** — no new dep with a known CVE; pinned
       versions in `gradle.properties`.
9. [ ] **Region threading** — no off-thread access to region data
       (security-adjacent: a race could leak data across regions).
10. [ ] **No `eval`/reflection on user input** — no
        `Class.forName(userInput)` or scripting engine eval on
        untrusted data.

## Security Audit Workflow

1. **Acquire the diff** — `git diff` or `gh pr diff <N>`.
2. **Run the 10-item checklist** above.
3. **Grep for risky patterns** (commands below).
4. **Check dependencies** — `./gradlew dependencies`, cross-ref CVEs.
5. **Review AT changes** — `git diff build-data/canvas.at`.
6. **Report findings** with severity (`[CRITICAL]` / `[MAJOR]` /
   `[MINOR]`) and `file:line`.

```bash
# Quick risk grep
git diff --staged | grep -E "hasPermission|dispatchCommand|NbtIo|NbtAccounter|maxPacketSize"
git diff --staged | grep -iE "password|secret|token|api.key"
git diff --staged -- build-data/canvas.at
```

## Cross-References

- `/canvas-code-review` — general review workflow; this skill adds the security-specific lens.
- `/canvas-config-system` — config file structure, secret handling in `global.yml`.
- `/canvas-at-guard` — AT syntax, POST-AT dependency, safe AT authoring.
- `/canvas-region-threading` — region data access rules (a threading violation can be a data leak).

## Pitfalls

1. **ATs aren't a sandbox** — widening visibility doesn't grant permission; plugins with AT access can already do anything. Don't treat AT review as the sole security gate.
2. **Mojang bundled libs aren't in Gradle deps** — CVE scanning via `./gradlew dependencies` misses them. Track Mojang's bundled Netty/Brigadier versions separately.
3. **NBT limits in NMS, not Canvas** — `NbtAccounter` is Mojang's. Canvas patches that touch NBT reading must preserve the accounter, not bypass it for "performance".
4. **Signed chat** — post-1.19, chat messages carry cryptographic signatures. Don't strip signature validation in patches; it enables impersonation.
5. **RCON** — `rcon.password` in `server.properties` is plaintext on disk. Document the risk; don't log it.
6. **Plugin sandbox is weak** — Minecraft has no real plugin sandbox. Any loaded plugin can do arbitrary I/O. The threat model is "trusted plugins," not "untrusted plugins." Document this.
