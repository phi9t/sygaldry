# RFC-077: Fix Rust Test Count Scan in rfc-review-prompt.md

**Status:** Open
**Date:** 2026-03-25
**Priority:** Medium
**Effort:** XS

---

## Problem

`docs/rfc-review-prompt.md` line ~60 contains:

```bash
grep -rn '^#\[test\]' crates/zephyr/src/ --include='*.rs' | grep -v target | wc -l
```

The `^` anchor requires `#[test]` to start at column 0. In practice, Rust `#[test]`
attributes are always indented inside `mod tests { }` blocks:

```rust
mod tests {
    #[test]          // ← indented, missed by '^'
    fn it_works() {}
}
```

This means the scan returns `0` even when many tests exist, giving a false
"no unit tests" reading.

---

## Solution

Change the grep pattern from `'^#\[test\]'` to `'^\s*#\[test\]'`:

**File:** `docs/rfc-review-prompt.md`
**Change:**
```diff
-grep -rn '^#\[test\]' crates/zephyr/src/ --include='*.rs' | grep -v target | wc -l
+grep -rn '^\s*#\[test\]' crates/zephyr/src/ --include='*.rs' | grep -v target | wc -l
```

---

## Acceptance Criteria

1. `grep -n "'\^#\\\[test\\\]'" docs/rfc-review-prompt.md` returns 0 matches
2. Running the corrected grep against `crates/zephyr/src/` returns a count > 0
