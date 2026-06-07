---
name: comet-archive
description: "Comet Phase 5: Archive. Invoke with /comet-archive. Sync delta spec to main spec, archive change."
---

# Comet Phase 5: Archive (Archive)

## Prerequisites

- Verification passed (Phase 4 complete)
- Branch handled
- `verify_result: pass` in `openspec/changes/<name>/.comet.yaml`

## Steps

### 0. Entry State Verification (Entry Check)

Execute entry verification:

```bash
COMET_ENV="${COMET_ENV:-$(find . "$HOME"/.*/skills "$HOME/.config" "$HOME/.gemini" -path '*/comet/scripts/comet-env.sh' -type f -print -quit 2>/dev/null)}"
if [ -z "$COMET_ENV" ]; then
  echo "ERROR: comet-env.sh not found. Ensure the comet skill is installed." >&2
  exit 1
fi
. "$COMET_ENV"
"$COMET_BASH" "$COMET_STATE" check <change-name> archive
```

Proceed to Step 1 after verification passes. The script outputs specific failure reasons when verification fails.

### 0a. Output Language Constraint

Archive summaries and lifecycle closure notes must use the language of the user request that triggered this workflow. Script output can remain as emitted, but the agent's explanation of archive results, diff previews, and next state must use that language; if existing artifacts have a different dominant language, preserve the artifact language unless the user explicitly asks to switch.

### 1. Execute Archive

Run the archive script to automatically complete all steps:

```bash
COMET_ENV="${COMET_ENV:-$(find . "$HOME"/.*/skills "$HOME/.config" "$HOME/.gemini" -path '*/comet/scripts/comet-env.sh' -type f -print -quit 2>/dev/null)}"
if [ -z "$COMET_ENV" ]; then
  echo "ERROR: comet-env.sh not found. Ensure the comet skill is installed." >&2
  exit 1
fi
. "$COMET_ENV"
"$COMET_BASH" "$COMET_ARCHIVE" "<change-name>"
```

The script automatically executes:
1. Entry state validation (phase=archive, verify_result=pass, archived=false)
2. Delta spec semantic merge to main spec (by ADDED/MODIFIED/REMOVED/RENAMED semantics)
3. Post-merge global guard: scan all main specs for delta-only section headers
4. Design doc frontmatter annotation (archived-with, status)
5. Plan frontmatter annotation (archived-with)
6. Move change to archive directory
7. Update `archived: true` through `comet-state transition <archive-name> archived`

If script returns non-zero exit code, report error and stop.
If script returns zero exit code, archive is complete.
The summary `X/Y steps succeeded` counts real executed steps and does not double-count delta spec merge or document annotation.

Delta spec merge is an **intelligent merge, not a file copy**:
- New capability: creates main spec from delta spec, automatically strips `REMOVED` / `RENAMED` sections, converts `ADDED` / `MODIFIED` headers to standard `## Requirements`
- Existing capability: parses the four semantic sections of delta spec, performing append (ADDED), replace (MODIFIED), remove (REMOVED), rename (RENAMED) respectively, preserving all main spec content not mentioned by delta

When a delta spec differs from an existing main spec, the script prints a unified diff preview before merge to help confirm archive sync content.

Use `--dry-run` flag to preview without executing.

### 2. Lifecycle Closed Loop

Spec lifecycle completes here:
```
brainstorming → delta spec → implementation → verification → main spec semantic merge → design doc annotation → archive
```

## Context Compression Recovery

Archive phase may trigger context compression. On recovery, run first:

```bash
"$COMET_BASH" "$COMET_STATE" check <change-name> archive --recover
```

The script outputs structured recovery context (phase, verify_result, archived state, recovery action). Determine the next step based on the Recovery action output.

If archive has not yet executed (archived is not true), continue to Step 1 archive script. If archive is complete (archived: true), directly confirm exit conditions and finish.

## Exit Conditions

- Archive script executed successfully (exit code 0)
- Archive directory `openspec/changes/archive/YYYY-MM-DD-<change-name>/` exists
- Archived `.comet.yaml` contains `archived: true`

The archive script moves `openspec/changes/<change-name>/` to `openspec/changes/archive/YYYY-MM-DD-<change-name>/`. After successful archive, verify completeness with:

```bash
test -d "openspec/changes/archive/YYYY-MM-DD-<change-name>"
"$COMET_BASH" "$COMET_STATE" get YYYY-MM-DD-<change-name> archived
```

After successful archive, **do not run** `"$COMET_BASH" "$COMET_GUARD" <change-name> archive` against the old active change name; the active directory no longer exists. Archive completeness is determined by script exit code and archived directory state.

## Complete

Comet workflow complete. To start new work, invoke `/comet` or `/comet-open`.
