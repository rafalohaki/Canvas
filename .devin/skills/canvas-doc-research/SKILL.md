---
name: canvas-doc-research
description: Use whenever needing to ground an answer in current Canvas/Paper/Folia/Weaver documentation or source — routes to DeepWiki (CraftCanvasMC/Canvas, PaperMC/Paper, PaperMC/Folia, CraftCanvasMC/weaver), canvasmc.io docs, or local source grep before writing code. MC 26.2 APIs change between versions — never guess from training data. Triggers on "how does X work in Canvas", "what's the signature of", "is this deprecated", "Canvas docs", "Paper docs", "Folia docs", "Weaver docs", "check the API", "ground in docs", "DeepWiki", "ask DeepWiki", "wiki structure".
triggers:
  - user
  - model
subagent: true
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - web_search
  - webfetch
  - deepwiki_ask_question
  - deepwiki_read_wiki_structure
  - deepwiki_read_wiki_contents
---

# Canvas Doc Research

MC 26.2 APIs change between versions. **Never guess from training data.** Always
ground answers in current source or documentation before writing code.

This skill is research-heavy — runs as a subagent to keep the parent context
clean. Merges the former `/canvas-deepwiki-usage` skill.

## Research Flow (DeepWiki first for architecture → local source for exact signatures → cite both)

1. **Architecture / design questions** → DeepWiki (AI-grounded in GitHub source)
2. **Exact signatures / current code** → local source grep (most accurate for this commit)
3. **Official docs** → canvasmc.io / Paper docs via `webfetch`
4. **Cite both**: DeepWiki page for design, `file:line` for exact code

## DeepWiki MCP Tools (devin/deepwiki server)

### `deepwiki_ask_question`
Ask a natural-language question grounded in a repo's source + generated wiki.
```
deepwiki_ask_question(
  repoName: "CraftCanvasMC/Canvas",   # or array: ["CraftCanvasMC/Canvas", "PaperMC/Paper"]
  question: "How does the CRS scheduler handle task pinning and work stealing?"
)
```
- `repoName` accepts a single string or array of strings (multi-repo compare).
- Best for: "how does X work", "what's the design of Y", "best practices for Z".

### `deepwiki_read_wiki_structure`
List the table of contents / topic tree for a repo.
```
deepwiki_read_wiki_structure(repoName: "PaperMC/Paper")
```
- Use first to discover what topics are indexed before asking narrow questions.

### `deepwiki_read_wiki_contents`
Read full generated documentation for a specific topic/page.
```
deepwiki_read_wiki_contents(repoName: "CraftCanvasMC/Canvas", pageName: "Patch System")
```
- Use when you need the full page, not a Q&A summary.

### Tracked Repos
| Repo | Use for |
|------|---------|
| `CraftCanvasMC/Canvas` | Canvas architecture, CRS scheduler, patch layering, Weaver integration |
| `PaperMC/Paper` | Paper upstream APIs, patch best practices, `dev/26.2` changes |
| `PaperMC/Folia` | Region threading origin (Canvas absorbed its patches — reference only) |
| `CraftCanvasMC/weaver` | Weaver patcher internals (Paperweight fork, patch application) |

## Research Order (most authoritative first)

### 1. Local source (most accurate for this exact version)
```bash
# Grep the applied source
grep -rn "TargetClass\|targetMethod" canvas-server/src/minecraft/java/ 2>/dev/null

# Grep the patches (if source not applied yet)
grep -rn "TargetClass" canvas-server/minecraft-patches/sources/ 2>/dev/null
grep -rn "TargetClass" canvas-server/minecraft-patches/base/ 2>/dev/null

# Check ATs
grep "TargetClass" build-data/canvas.at
```

### 2. DeepWiki (AI-powered, grounded in GitHub source)
Use the tools above. Best for: "how does the patch system work", "what's the
region threading model", "how does Weaver apply patches", "best practices for X".

### 3. Canvas official docs
- **https://docs.canvasmc.io** — official documentation
- **https://docs.canvasmc.io/canvas/developers/contributing/canvas/** — contributing guide
- Use `webfetch` to read specific pages

### 4. Paper/Folia/Weaver GitHub source
- **PaperMC/Paper** (`dev/26.2` branch) — upstream source
- **PaperMC/Folia** — region threading origin (Canvas absorbed its patches)
- **CraftCanvasMC/weaver** — patcher plugin source
- Use `webfetch` on GitHub blob URLs, or DeepWiki

### 5. Web search (last resort)
- Use `web_search` for blog posts, forum threads, Stack Overflow
- **Never quote SEO blogs as primary source** for API signatures — use official docs/source

## When to Use Which

| Question | Best source |
|----------|-------------|
| "What's the signature of `TickThread.isTickThreadFor`?" | Local source grep |
| "How does the patch lifecycle work?" | DeepWiki (Canvas) → local verify |
| "How does the CRS scheduler pin tasks?" | DeepWiki (Canvas) → `io.canvasmc.canvas.tick` grep |
| "What config options exist for threaded-regions?" | Local source grep → DeepWiki |
| "How do I write a Canvas patch?" | DeepWiki (Canvas) + `/canvas-patch-lifecycle` + `/canvas-patch-authoring` |
| "What changed in Paper dev/26.2 vs 26.1?" | Paper GitHub + DeepWiki (Paper) |
| "Is this Folia API still in Canvas?" | Local source grep (Folia patches absorbed, rewritten) |
| "Best practices for region threading?" | DeepWiki (Folia + Canvas) |
| "How does Weaver apply base patches?" | DeepWiki (weaver) + `build.gradle.kts` |

## Grounding Discipline

1. **Before writing code** that calls a Canvas/Paper/MC API: grep the local source to confirm the signature exists and is current.
2. **Before answering architecture questions**: check DeepWiki + local source.
3. **Cite sources**: `file:line` for code, URLs for docs, DeepWiki page name for design.
4. **Distinguish code-grounded from docs-grounded conclusions** in your answer.
5. **If you can't find it**: say so, don't guess. Ask the user or search more.

## Common Research Tasks

### "Does Canvas have X?"
```bash
grep -rn "X" canvas-server/src/minecraft/java/ 2>/dev/null
grep -rn "X" canvas-api/ 2>/dev/null
# If not found in applied source, check patches
grep -rn "X" canvas-server/minecraft-patches/ 2>/dev/null
```

### "How does X work?"
```
# DeepWiki first for architecture
deepwiki_ask_question(repoName="CraftCanvasMC/Canvas", question="How does X work?")
# Then verify exact signatures in local source
grep -rn "X" canvas-server/src/minecraft/java/
```

### "What's the Canvas equivalent of Folia's Y?"
```bash
# Canvas absorbed Folia patches — the code is in Canvas source now (possibly rewritten)
grep -rn "Y" canvas-server/src/minecraft/java/ 2>/dev/null
# Check base patch headers for origin (Folia absorbed vs Canvas original)
head -20 canvas-server/minecraft-patches/base/0001-*.patch
```

### "What are Paper's patch best practices?"
```
deepwiki_ask_question(repoName="PaperMC/Paper", question="What are the patch marking and authoring conventions?")
# Key conventions (from Paper):
# - Mark changes with "// Paper start - <desc>" / "// Paper end - <desc>"
# - Canvas equivalent: "// Canvas start - <desc>" / "// Canvas end - <desc>"
# - Prefer fully-qualified imports in vanilla classes
# - Use fixupSourcePatches + rebuildPatches workflow
```

## Pitfalls

1. **Training data is stale** — MC 26.2 APIs differ from 1.20.x/1.21.x. Always verify.
2. **Folia ≠ Canvas** — Canvas absorbed Folia patches but rewrote some (CRS scheduler, chunk system). Check Canvas source, not Folia's.
3. **DeepWiki may lag** — it indexes GitHub repos but may not have the latest commit. Verify in local source.
4. **Blog posts lie** — SEO content about "Folia scheduler" may describe old versions. Use official docs/source.
5. **DeepWiki is for design, not exact signatures** — always confirm signatures in local source at the pinned commit.
