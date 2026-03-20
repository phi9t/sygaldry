# Prompt: RFC Review, Consolidation, and Revision

Use this prompt with Claude Code (or equivalent) against the Sygaldry repo to produce
an updated, accurate RFC set. Run it from the repo root.

---

## Context you must establish before writing anything

Read these files first — they define the current ground truth:

1. `docs/RFC-INDEX.md` — current index (32 RFCs, last updated 2026-03-18)
2. All 31 `docs/RFC-*.md` files (excluding RFC-INDEX.md itself)
3. `CLAUDE.md` — architecture and env var documentation
4. `temporal/internal/activities/steps.go` — primary activity implementation
5. `temporal/internal/workflows/pipeline.go` — workflow / heartbeat options
6. `temporal/cmd/worker/main.go` — worker startup
7. `temporal/cmd/orchestrate/main.go` — orchestrate CLI
8. `crates/zephyr/src/host/launcher.rs` — Rust container launcher
9. `crates/zephyr/src/config.rs` — Rust config (LaunchMode, paths)
10. `crates/zephyr/src/host/image.rs` — image build logic
11. `container/launch_container.sh` — shell launcher (still active)
12. `tools/agentic/discover_issues.py` — SAIL issue discovery
13. `tools/agentic/improvement_loop.yaml` — SAIL Temporal pipeline

Run these shell commands to establish ground truth before reading any RFC:

```bash
# What log calls remain in steps.go? (RFC-007)
grep -n 'log\.' temporal/internal/activities/steps.go

# Are HF cache dirs still hardcoded? (RFC-024)
grep -n '/opt/hf_cache\|hf_cache' temporal/internal/activities/steps.go

# dead_code suppressions in Rust? (RFC-019)
grep -rn '#\[allow(dead_code)\]' crates/zephyr/src/

# Hardcoded /tmp in rfc_impl.go? (RFC-037)
grep -n '/tmp' temporal/cmd/rfc/rfc_impl.go 2>/dev/null || echo "file not found"

# Commented dead code in Dockerfile? (RFC-039)
grep -n '#.*TODO\|#.*DEAD\|#.*OLD\|#.*REMOVE' container/dev_container.dockerfile

# Is launch_container.sh still the primary launcher? (RFC-020)
head -5 bin/sygaldry && grep -n 'launch_container' container/launch_container.sh | head -3

# Does ContainerJob call the zephyr binary or launch_container.sh? (RFC-028)
grep -n 'zephyr\|launch_container' temporal/internal/activities/steps.go | grep -i container

# Does workflow.GetVersion appear anywhere? (RFC-022)
grep -rn 'GetVersion\|workflow.Version' temporal/

# Do query/signal handlers exist? (RFC-023)
grep -rn 'SetQueryHandler\|SetSignalHandler' temporal/

# What's the current worker shutdown config? (RFC-036 — should be done)
grep -n 'StopTimeout\|DeadlockDetection' temporal/cmd/worker/main.go

# Does steps.go use slog or log? (RFC-007)
grep -n '"log"' temporal/internal/activities/steps.go
grep -n '"log/slog"' temporal/internal/activities/steps.go

# What --sources support exists in discover_issues.py? (RFC-009)
grep -n 'sources\|argparse\|add_argument' tools/agentic/discover_issues.py | head -10

# K3s: what k3s files exist? (RFC-016)
find . -name '*.yaml' -path '*/k3s/*' | head -10
grep -rn 'k3s\|K3s' temporal/ --include='*.go' | head -10
```

---

## What to produce

For **each of the 31 open RFCs**, make one of the following determinations:

### A — Already implemented (close it)
The code changes described in the RFC are present in the codebase. Document:
- What code you found that proves it is done
- Which file/line confirms the implementation
- Output: recommend `git rm docs/RFC-NNN-*.md` and add a row to the Closed table in RFC-INDEX.md

### B — Partially implemented (rewrite in-place)
Some but not all changes are done. Rewrite the RFC to:
- Remove the done sections
- Narrow the title if the remaining scope is smaller
- Bump status to `Draft — v{N+1}`
- Keep only the remaining changes, updated to reflect current code

### C — Stale description (update in-place)
The work is still needed but the RFC description references code that has since
changed (file moved, function renamed, etc.). Update the file paths and function
names to match current reality. Do not change the substance.

### D — Out of scope / N/A
The RFC describes something that no longer applies (deleted code path, decision
reversed, external dependency removed). Recommend deletion.

### E — Valid and accurate (no change needed)
The RFC is an open ticket, the code does not yet contain the fix, and the description
accurately references current file paths and function names. Leave it alone.

---

## Consolidation rules

Apply these consolidation rules after the per-RFC pass:

1. **If two RFCs touch the same single file** and neither is blocked by the other,
   consider merging them. Only merge if the combined RFC is still XS–S effort.
   Never merge if one is High and the other is Low priority.

2. **If an RFC references a file that no longer exists**, either find the replacement
   file or recommend closing the RFC as N/A.

3. **If an RFC in the "Proposed" bucket has no description file** (only an index row),
   either write a stub description file or leave a comment in the index marking it
   as "stub — needs spec".

4. **Do not consolidate Large (L) RFCs** — they are strategic and need separate
   discussion.

---

## RFC-INDEX.md revision

After processing all individual RFCs, rewrite `docs/RFC-INDEX.md` with:

- Updated status for any RFCs revised above
- Corrected Effort/Priority for any that changed
- Updated implementation order (Immediate → High → Medium → Low) based on
  current findings
- Any newly closed RFCs moved to the Closed table
- Date bumped to today

---

## Output format

Produce a **triage report** before making any edits:

```
RFC-NNN  [A/B/C/D/E]  <one-line reason>
RFC-NNN  ...
```

Then ask for confirmation before writing any files. If running non-interactively,
produce the triage report as a markdown block in stdout and then apply all changes.

---

## Constraints

- Do not invent new RFCs. Only revise or close existing ones.
- Do not change the substance of an RFC unless code evidence justifies it.
- Do not merge RFCs with L (large) effort.
- Every claim about current code state must cite a file path and line number.
- After all edits: `cd temporal && go test ./...` must pass. RFCs are docs-only
  so this is just a sanity check that no accidental code edits occurred.
