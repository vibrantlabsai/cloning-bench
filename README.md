# cloning-bench

A benchmark for evaluating how well autonomous AI agents can clone websites.
Each agent is given a reference recording of a real website and tasked with
building a React frontend that visually matches it. Agents run unattended in
isolated Docker containers with access to browser automation, visual testing
tools, and the reference material. Results are measured using SSIM (Structural
Similarity Index) against the original screenshots.

## Quick start

### With Nix (recommended)

```bash
# 1. Enter the dev shell (provides Python, Node.js, uv, and all CLI tools)
nix develop

# 2. Build and run an agent container
nix build .#claude-container
docker load < result
docker run -e AWS_BEARER_TOKEN_BEDROCK \
  -v ./recordings:/bench/recordings:ro \
  -v ./workspace:/bench/workspace \
  cloning-bench-claude:latest
```

### Without Nix

```bash
# Requires Python 3.12+ and uv
uv sync

# The CLI tools (site-test, site-test-diff, lookatdiff) are now available
site-test ./recordings/1 http://localhost:5173
```

## How it works

```
cloning-bench/
│
├── recordings/              Reference recordings (screenshots, DOM, assets)
│
├── agents/
│   ├── claude/              Claude agent harness (Anthropic)
│   ├── codex/               Codex agent harness (OpenAI)
│   ├── gemini/              Gemini agent harness (Google)
│   └── glm/                 GLM agent harness
│
├── packages/
│   ├── test/                site-test: visual compliance testing framework
│   └── lookatdiff/          LLM-powered diff analysis tool
│
└── flake.nix                Nix flake for reproducible containers and dev env
```

Each agent runs in a Docker container built with Nix. The container includes:

- **Node.js 24** and **Chromium** for building and previewing the React app
- **Python 3.12** with the visual testing tools
- **agent-browser** for headless browser automation (1280x720 viewport)
- **Git** for version control within the workspace
- The agent's own CLI (Claude Code, Codex CLI, Gemini CLI, or GLM/Pi CLI)

The agent reads the recording data, builds a Vite + React project, and enters
an infinite test-fix loop:

1. Study the reference (DOM snapshots, accessibility trees, computed styles, assets)
2. Build or improve React components
3. Run `site-test` to capture screenshots and compare against the reference
4. Analyze visual diffs to identify remaining differences
5. Fix the differences and repeat

Agents are killed externally when time is up. There is no "done" state — the
goal is to maximize SSIM scores in the time available.

## Recording structure

Each recording captures a browsing session with one or more assertion points:

```
recordings/<index>/
├── video.mp4                   Full session video
├── screenplay.json             Test script with actions and assertions
├── screenshots/
│   ├── 0/                      Per-assertion directory
│   │   ├── screenshot.png      Reference screenshot (1280x720)
│   │   ├── dom.html            Full HTML snapshot
│   │   ├── manifest.json       Asset URL -> SHA256 hash mapping
│   │   ├── full/
│   │   │   ├── axtree.txt      Accessibility tree
│   │   │   └── styles.json     Computed CSS values
│   │   └── viewport/
│   │       ├── axtree.txt      Viewport-scoped accessibility tree
│   │       └── styles.json     Viewport-scoped styles
│   └── 1/, 2/, ...
└── assets/
    └── <sha256-hash>           Deduplicated assets (images, icons, fonts)
```

Agents use `dom.html` and `axtree.txt` to understand page structure,
`styles.json` for CSS values, and `manifest.json` to extract assets. They must
not copy `dom.html` verbatim or use reference screenshots as image sources —
the UI must be rewritten as proper React components.

## Visual testing

The benchmark includes two testing tools:

### site-test

Executes the screenplay against a running clone, captures screenshots at each
assertion point, and computes SSIM scores against the reference.

```bash
site-test <recording-dir> <clone-url>
site-test ./recordings/1 http://localhost:5173 --output-dir ./report
```

Output is a timestamped report folder containing:
- `summary.json` — overall pass/fail, step counts, duration
- `execution-log.json` — per-step results with SSIM scores
- `asserts/<N>/recording.png` — reference screenshot
- `asserts/<N>/subject.png` — clone screenshot
- `asserts/<N>/diff.png` — visual diff overlay

### site-test-diff

Generates a visual diff between any two screenshots with optional LLM-based
dynamic content detection.

```bash
site-test-diff <reference.png> <subject.png> <output.png>
site-test-diff ref.png clone.png diff.png --no-dynamic-detection
```

### Diff color coding

| Color | Meaning | Action |
|-------|---------|--------|
| **Red** | Structural differences | Must be fixed |
| **Blue/Cyan** | Dynamic content (timestamps, ads, counters) | Can be ignored |

### lookatdiff

Uses the Gemini API to analyze what visual differences mean and suggest fixes.

```bash
lookatdiff <subject.png> <diff.png> <actual.png> [-q "What needs fixing?"]
```

Requires `GEMINI_API_KEY` in the environment.

## Agents

Four agents are currently supported:

| Agent | Provider | CLI | Config |
|-------|----------|-----|--------|
| Claude | Anthropic | Claude Code | `agents/claude/CLAUDE.md` |
| Codex | OpenAI | Codex CLI | `agents/codex/AGENTS.md` |
| Gemini | Google | Gemini CLI | `agents/gemini/GEMINI.md` |
| GLM | — | Pi CLI | `agents/glm/AGENTS.md` |

Each agent directory contains:
- Agent-specific instructions (system prompt / markdown config)
- Nix derivation for building the Docker container (`nix/default.nix`)
- Skill definitions for `agent-browser`, `site-test`, and `asset-handling`

### Building containers

```bash
# Build a specific agent container
nix build .#claude-container
nix build .#codex-container
nix build .#gemini-container
nix build .#glm-container

# Load and run
docker load < result
docker run -e AWS_BEARER_TOKEN_BEDROCK \
  -v ./recordings:/bench/recordings:ro \
  -v ./workspace:/bench/workspace \
  cloning-bench-claude:latest
```

## Post-run analysis

After a run completes, use `extract-transcripts` to pull conversation logs,
token usage, and cost data from the workspace:

```bash
extract-transcripts <workspace-dir>
```

This produces:
- Per-agent conversation transcripts (JSONL or JSON)
- Token usage summaries
- A unified `cost-report.json` across all agents
- Screenshot archives showing visual progression over time

## Development

### Nix devshell

```bash
nix develop
```

This provides:
- **Python 3.12** with uv and all project dependencies
- **Node.js 24** for the React build toolchain
- **Chromium** for headless browser automation
- **direnv support** — the `.envrc` activates the devshell automatically

## License

[MIT](LICENSE)
