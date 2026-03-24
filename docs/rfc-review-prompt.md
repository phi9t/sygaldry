# RFC Review, Consolidation, and Revision

You are reviewing the open RFC files in `docs/` against the current state of
the Sygaldry codebase. Your job is to determine which RFCs are done, which are
stale, which need narrowing, and which are accurate — then apply all changes and
update the index.

---

## Step 1 — Establish ground truth (run all commands first, before reading any RFC)

First, read each open RFC file (any RFC listed as open in `docs/RFC-INDEX.md`)
and extract its key file paths and function names. Then generate targeted
`grep` and `wc -l` commands specific to those RFCs to verify current state.

Always run this general health scan regardless of which RFCs are open:

```bash
# ── General codebase health scan ──────────────────────────────────────────────

# File sizes (flag files >500 lines for decomposition review)
# Use xargs to tolerate missing files instead of failing the whole command.
ls temporal/cmd/orchestrate/main.go \
   temporal/internal/workflows/rfc_impl.go \
   temporal/internal/activities/steps.go \
   temporal/cmd/worker/main.go \
   tools/agentic/sail_supervisor.py \
   crates/zephyr/src/config.rs \
   crates/zephyr/src/host/docker_args.rs \
   2>/dev/null | xargs wc -l 2>/dev/null

# Go: TODO/FIXME/HACK (excluding tests)
grep -rn 'TODO\|FIXME\|HACK\|XXX' temporal/ --include='*.go' | grep -v '_test.go' | head -20

# Go: swallowed errors
grep -rn '_ = \|_ =' temporal/ --include='*.go' | grep -v '_test.go\|//.*_ =' | head -20

# Go: hardcoded Temporal defaults (should be env-overridable)
grep -rn '"localhost:7233\|"default"\|"orchestration"' temporal/ --include='*.go' | grep -v '_test.go' | head -20

# Go: duplicated function definitions across cmd/ packages
grep -rn '^func envOr\b\|^func envOrInt\b' temporal/ --include='*.go' | head -10

# Go: repeated Temporal client.Dial (flag if >2 definitions)
grep -rn 'client\.Dial(' temporal/ --include='*.go' | grep -v '_test.go' | head -10

# Go: fmt.Printf / fmt.Println in internal/ packages (should be slog)
grep -rn 'fmt\.Printf\|fmt\.Println' temporal/internal/ --include='*.go' | grep -v '_test.go' | head -10

# Go: bare "log" import in cmd/ (should be "log/slog")
grep -rn '"log"' temporal/cmd/ --include='*.go' | grep -v '_test.go' | head -10

# Rust: dead-code allow annotations
grep -rn '#\[allow(' crates/zephyr/src/ --include='*.rs' | grep -v target | head -20

# Rust: TODO/FIXME
grep -rn 'TODO\|FIXME\|HACK' crates/zephyr/src/ --include='*.rs' | grep -v target | head -20

# Rust: unit test count
grep -rn '^#\[test\]' crates/zephyr/src/ --include='*.rs' | grep -v target | wc -l

# Rust: unwrap() in non-test production code (test code is OK)
grep -rn '\.unwrap()' crates/zephyr/src/ --include='*.rs' | grep -v target \
  | grep -v 'fn test_\|#\[test\]\|#\[cfg(test)\]' | head -10

# Go: unit test count
grep -rn '^func Test' temporal/ --include='*_test.go' | wc -l

# Python: SAIL tool sizes (look for files >200 lines with no corresponding test file)
wc -l tools/agentic/*.py | sort -n | tail -15

# Python: missing test files for large Python tools
# Note: tests may be split across multiple files (e.g. test_discover_issues_todos.py),
# so check whether any test file imports or references the module name, not just exact filename.
for f in tools/agentic/*.py; do
  base=$(basename "${f%.py}")
  lines=$(wc -l < "$f" 2>/dev/null)
  [[ $lines -le 100 ]] && continue
  if ! grep -rl "${base}" tools/agentic/tests/ --include="*.py" >/dev/null 2>&1; then
    echo "NO TESTS: $f (${lines} lines)"
  fi
done

# Shell: shellcheck on all agentic scripts
shellcheck -s bash -S warning tools/agentic/*.sh 2>&1 | head -40

# Shell: shellcheck on other key scripts
shellcheck -s bash -S warning bin/sygaldry validate_all.sh 2>&1 | head -20

# Shell: check for global SC2034 suppression in validate_all.sh (should be empty after RFC-050 lands)
grep 'SC2034' validate_all.sh

# CI coverage: check validate_all.sh covers all primary languages
grep -i 'cargo\|rust' validate_all.sh | head -5
```

For each open RFC, also run the RFC-specific commands derived from reading its
Problem section (file paths, function names, grep patterns mentioned in the RFC).

**Negative assertions:** A `grep` command that returns no output is valid evidence
that the thing being searched for does not exist. Record `(empty)` as the result.

---

## Step 2 — Triage each RFC

For **each open RFC**, assign one label based on what the ground-truth
commands showed:

| Label | Meaning | Action |
|-------|---------|--------|
| **A** | Already implemented | `git rm` the file; add to Closed table in index |
| **B** | Partially implemented | Rewrite the file; remove done sections; bump version |
| **C** | Stale references only | Update file paths / function names; do not change substance |
| **D** | Out of scope / N/A | `git rm` the file; add to Closed table in index |
| **E** | Accurate, still open | No change needed |
| **F** | Blocked / On Hold | Update Status field; note the blocker |

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

**F:** The RFC is accurate but cannot proceed because of an external dependency,
an unresolved design decision, or a prerequisite RFC that must land first.
Update Status to "On Hold — blocked by RFC-NNN" and add a "Blocked By" column
entry in the index's open table. Note the blocker explicitly.

Output format for the triage pass (produce this before making any edits):

```
RFC-NNN  [A/B/C/D/E/F]  <file:line that proves it, or one-line reason>
...
```

---

## Step 3 — Apply consolidation rules

After producing the triage table, apply these rules before writing any files:

1. **Merge candidates:** Two RFCs may be merged into one if ALL of these hold:
   - Both are labeled E or C (neither is being deleted or partially rewritten)
   - Both touch the same primary file or package (not necessarily the exact same file)
   - Combined effort is ≤ S
   - Neither blocks the other
   - They share the same priority tier (Immediate/High/Medium/Low)
   Keep the lower RFC number; delete the higher; update the index.

2. **Missing file reference:** If an RFC references a file that `find . -name`
   cannot locate, relabel that RFC as C and update the path to the current
   location, or relabel D if the feature was removed entirely.

3. **No new RFCs in this step.** Do not invent RFC content that is not already
   supported by the ground-truth commands. New RFC creation happens in Step 5.

---

## Step 4 — Write edits

Apply all triage decisions:
- For A and D: `git rm docs/RFC-NNN-*.md`
- For B: overwrite the RFC file with only the remaining changes
- For C: edit only the stale path/name references
- For F: update the Status field to "On Hold — blocked by RFC-NNN"
- For merges: overwrite the lower-numbered file; `git rm` the higher-numbered file

Then rewrite `docs/RFC-INDEX.md`:
- Remove A/D rows from the open table; add them to the Closed table with a
  one-sentence reason
- Update Status, Priority, Effort for any B/C RFCs that changed
- Mark F RFCs as "On Hold" in the open table with a "Blocked By" entry
- Re-derive the implementation order using these tie-breaking rules (in priority):
  1. Unblocks other open RFCs (prerequisite RFCs go first)
  2. Correctness/safety > performance > cosmetic
  3. Lower effort wins ties
  4. XS effort + Low priority and **unblocked** → upgrade to Medium priority (quick wins should not sit idle; skip this upgrade for blocked RFCs)
- Bump the "Last updated" date

---

## Step 5 — Create new RFCs

Based on your ground-truth scan, identify **real, actionable** improvements.
For each:
- It must cite a specific file:line
- It must be achievable without external dependencies
- It must not duplicate an existing open RFC

Good candidates come from:
- TODOs/FIXMEs in Go/Rust/Python
- `_ =` swallowed errors in Go (at system boundaries: activity results, git ops, etc.)
- Large files (>500 lines production code, excluding test sections) that mix concerns
- Hardcoded strings repeated in 3+ places that should be constants or shared config
- Missing test coverage for important functions (especially Python helpers with no test file)
- Shell script issues found by shellcheck
- Patterns repeated 3+ times that could be a helper
- `fmt.Printf` / `fmt.Println` in activity or workflow code (should be `slog`)
- `log.Fatal` / `log.Printf` in `cmd/` packages when adjacent packages use `slog`
- CI validation scripts that omit a primary language (e.g., no `cargo` for a Rust crate)
- Identical helper functions defined in sibling packages that both need the same semantics
- Asymmetries between CI (validate_all.sh) and SAIL issue scanner (discover_issues.py) — if
  validate_all.sh suppresses a warning class, discover_issues.py should match or vice versa
- RFC solution code snippets that reference logging APIs (`slog.Warn`) when the target file
  uses `workflow.GetLogger(ctx)` — always verify which logger the file already uses

**Do not create RFCs for:**
- `fmt.Printf` / `fmt.Println` in `cmd/` packages used for user-facing output (e.g., plan
  validation summary, status JSON output) — these are intentional stdout writes, not logging
- Issues that are outside the repository scope (e.g., upstream Spack packages)
- Issues that require an external service or API change

Create RFC files at `docs/RFC-NNN-*.md` using the next available numbers.
Number them sequentially. Each RFC needs:
- Status, Date, Priority, Effort fields
- Problem section with file:line citations
- Solution section that is specific and implementable
- Acceptance criteria (grep-verifiable where possible)

---

## Step 6 — Verify

```bash
# Correct file count
ls docs/RFC-*.md | wc -l
# must be: (previous count) - (A+D closures) - (merge deletions) + (new RFCs)

# No closed RFC numbers appear in the open table
# (verify manually that the Open RFCs table has no rows for closed RFC numbers)

# No code was changed
./validate_all.sh --quick   # must pass
```

Also verify RFC-INDEX.md:
- No closed RFC numbers appear in the open table
- All open RFCs have a file in docs/
- Blocked (F) RFCs are listed in the open table with a non-empty "Blocked By" entry
- The "Last updated" date matches today

---

## Hard constraints

- Every claim about current code state must cite `file:line` or `command → (empty)`.
- Do not change the substance of an RFC without code evidence.
- Do not merge RFCs with L (Large) effort — they are strategic documents.
- Do not add commentary, rationale, or new requirements to RFC files beyond
  what is needed to make them accurate.
- RFC-INDEX.md is always the last file written.
