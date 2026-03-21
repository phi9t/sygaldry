# RFC Review, Consolidation, and Revision

You are reviewing the 7 open RFC files in `docs/` against the current state of
the Sygaldry codebase. Your job is to determine which RFCs are done, which are
stale, which need narrowing, and which are accurate — then apply all changes and
update the index.

---

## Step 1 — Establish ground truth (run all commands first, before reading any RFC)

Run these commands and record their output. Do not read RFC bodies until you have
the ground-truth output in context.

```bash
# ── Temporal: steps.go ────────────────────────────────────────────────────────
# RFC-007: log.* still present? slog imported?
grep -n '"log"' temporal/internal/activities/steps.go
grep -n '"log/slog"' temporal/internal/activities/steps.go
grep -n 'log\.' temporal/internal/activities/steps.go | wc -l

# RFC-024: HF cache dir hardcoded?
grep -n '/opt/hf_cache\|"hf_cache"' temporal/internal/activities/steps.go

# RFC-008 / RFC-020: launcher resolution state
grep -n 'LauncherPath\|resolveContainerLauncher\|launch_container.sh\|K8sJob' temporal/internal/activities/steps.go | head -10

# ── Temporal: pipeline.go ────────────────────────────────────────────────────
# RFC-022: workflow.GetVersion used?
grep -rn 'GetVersion\|workflow\.Version' temporal/

# RFC-023: query/signal handlers registered?
grep -rn 'SetQueryHandler\|SetSignalHandler' temporal/

# ── Temporal: orchestrate/main.go ─────────────────────────────────────────────
# RFC-012: how large is orchestrate/main.go?
wc -l temporal/cmd/orchestrate/main.go

# RFC-035: which merge* functions lack tests?
grep '^func merge' temporal/cmd/orchestrate/main.go | sed 's/func \(merge[^(]*\).*/\1/' | \
  while read fn; do
    TEST="Test$(echo $fn | sed 's/^m/M/')"
    grep -q "$TEST" temporal/cmd/orchestrate/main_test.go && echo "HAS TEST: $fn" || echo "NO TEST: $fn"
  done

# RFC-037: hardcoded /tmp in rfc_impl.go?
grep -n '/tmp' temporal/internal/workflows/rfc_impl.go

# ── Temporal: worker ──────────────────────────────────────────────────────────
# RFC-003 / RFC-036: worker slog, stop timeout (RFC-036 should be closed — verify)
grep -n 'StopTimeout\|DeadlockDetection\|slog' temporal/cmd/worker/main.go | head -10

# ── SAIL ─────────────────────────────────────────────────────────────────────
# RFC-009: --sources flag present?
grep -n 'sources\|add_argument.*sources' tools/agentic/discover_issues.py | head -10

# RFC-029: does discover_issues.py run cargo test or Rust coverage?
grep -n 'cargo\|rust\|\.rs' tools/agentic/discover_issues.py | head -10

# RFC-004: how complex is improvement_loop.yaml?
wc -l tools/agentic/improvement_loop.yaml
grep -c '^  - id:' tools/agentic/improvement_loop.yaml

# ── Rust: image.rs ────────────────────────────────────────────────────────────
# RFC-017: pub functions in image.rs (are they pub(crate) or pub?)
grep -n '^pub ' crates/zephyr/src/host/image.rs

# RFC-027: should_build_decision inside cfg(test)?
grep -n 'cfg(test)\|should_build_decision' crates/zephyr/src/host/image.rs

# ── Rust: config.rs ───────────────────────────────────────────────────────────
# RFC-040: build_shared_caches returns a tuple?
grep -n 'build_shared_caches\|fn build_shared' crates/zephyr/src/config.rs

# RFC-014: any hardcoded paths or magic strings in config.rs?
grep -n '"/opt\|"/mnt\|"/home\|"/tmp\|"/var' crates/zephyr/src/config.rs | head -15

# ── Rust: docker_args.rs ──────────────────────────────────────────────────────
# RFC-041: detect_user_spec calls docker info every invocation?
grep -n 'detect_user_spec\|docker info\|docker.*info' crates/zephyr/src/host/docker_args.rs

# ── Rust: dead code ───────────────────────────────────────────────────────────
# RFC-019: how many #[allow(dead_code)] remain?
grep -rn '#\[allow(dead_code)\]' crates/zephyr/src/ --include='*.rs' | grep -v target

# ── Rust: testing ─────────────────────────────────────────────────────────────
# RFC-010: test count in crates/
grep -rn '^#\[test\]\|fn test_' crates/zephyr/src/ --include='*.rs' | grep -v target | wc -l

# RFC-006: how many entrypoints exist (shell vs Rust)?
ls container/entrypoints/
grep -rn 'subcommand.*entrypoint\|Entrypoint' crates/zephyr/src/cli.rs 2>/dev/null | head -5

# RFC-002 / RFC-020: is launch_container.sh still the primary runtime path?
# Check if bin/sygaldry is a shell script or binary, and whether ContainerJob calls it
file bin/sygaldry
grep -n 'launch_container\|zephyr.*binary\|zephyr.*bin' temporal/internal/activities/steps.go | head -5

# RFC-020: what does ContainerJob actually invoke?
grep -n -A5 'func ContainerJob\|launcher\|resolveContainer' temporal/internal/activities/steps.go | head -30

# ── Docker / shell ─────────────────────────────────────────────────────────────
# RFC-031: container user sudo scope
grep -n 'NOPASSWD\|sudo\|sudoers' container/dev_container.dockerfile

# RFC-013: Dockerfile layer count (RUN + COPY + FROM directives)
grep -c '^RUN\|^COPY\|^FROM' container/dev_container.dockerfile

# RFC-039: commented-out code blocks in Dockerfile
grep -n '^\s*#' container/dev_container.dockerfile | grep -v '^\s*# ──\|^#!' | tail -30

# RFC-015: validate_all.sh structure
head -60 validate_all.sh

# RFC-016: k3s files / references
find . -name '*.yaml' -path '*/k3s/*' 2>/dev/null | head -10
grep -rn 'k3s\|K3s' temporal/ --include='*.go' | head -10
```

---

## Step 2 — Triage each RFC

For **each of the 9 open RFCs**, assign one label based on what the ground-truth
commands showed:

| Label | Meaning | Action |
|-------|---------|--------|
| **A** | Already implemented | `git rm` the file; add to Closed table in index |
| **B** | Partially implemented | Rewrite the file; remove done sections; bump version |
| **C** | Stale references only | Update file paths / function names; do not change substance |
| **D** | Out of scope / N/A | `git rm` the file; add to Closed table in index |
| **E** | Accurate, still open | No change needed |

Rules for each label:

**A:** Every numbered change in the RFC must be present in the codebase with a
specific file:line citation. If even one change is absent, use B instead.

**B:** List which changes are done (with file:line) and which remain. Rewrite the
RFC to contain only the remaining changes. Narrow the title if the remaining scope
is smaller than the original. Bump `Draft — v{N}` → `Draft — v{N+1}`.

**C:** The intent is still valid but ≥1 file path or function name in the RFC no
longer matches the codebase. Update references only. Do not rewrite problem/solution
sections.

**D:** The code path the RFC addresses has been deleted, the decision reversed, or
the RFC was never actionable (catalog-only, external-dependency-only). Document
the reason in one sentence in the Closed table.

**E:** All file paths, function names, and problem descriptions match current
code. The fix is not yet present.

Output format for the triage pass (produce this before making any edits):

```
RFC-NNN  [A/B/C/D/E]  <file:line that proves it, or one-line reason>
...
```

---

## Step 3 — Apply consolidation rules

After producing the triage table, apply these rules before writing any files:

1. **Merge candidates:** Two RFCs may be merged into one if ALL of these hold:
   - Both are labeled E or C (neither is being deleted or partially rewritten)
   - Both touch the same single file
   - Combined effort is ≤ S
   - Neither blocks the other
   - They share the same priority tier (Immediate/High/Medium/Low)
   Keep the lower RFC number; delete the higher; update the index.

2. **Missing file reference:** If an RFC references a file that `find . -name`
   cannot locate, relabel that RFC as C and update the path to the current
   location, or relabel D if the feature was removed entirely.

3. **No new RFCs.** Do not invent RFC content that is not already in a file.

---

## Step 4 — Write edits

Apply all triage decisions:
- For A and D: `git rm docs/RFC-NNN-*.md`
- For B: overwrite the RFC file with only the remaining changes
- For C: edit only the stale path/name references
- For merges: overwrite the lower-numbered file; `git rm` the higher-numbered file

Then rewrite `docs/RFC-INDEX.md`:
- Remove A/D rows from the open table; add them to the Closed table with a
  one-sentence reason
- Update Status, Priority, Effort for any B/C RFCs that changed
- Re-derive the implementation order (Immediate → High → Medium → Low) from
  the surviving open RFCs
- Bump the "Last updated" date

---

## Step 5 — Verify

```bash
# Correct file count
ls docs/RFC-*.md | wc -l   # must equal (previous count) minus (A+D closures) minus (merge deletions)

# No closed RFC numbers appear in the open table
# (check manually that the All RFCs table in RFC-INDEX.md contains no rows for closed RFCs)

# No code was changed
cd temporal && go test ./...   # must pass
```

---

## Hard constraints

- Every claim about current code state must cite `file:line`.
- Do not change the substance of an RFC without code evidence.
- Do not merge RFCs with L (Large) effort — they are strategic documents.
- Do not add commentary, rationale, or new requirements to RFC files beyond
  what is needed to make them accurate.
- RFC-INDEX.md is always the last file written.
