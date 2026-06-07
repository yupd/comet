#!/bin/bash
# Comet Archive — automates the archive phase in one command
# Usage: comet-archive.sh <change-name> [--dry-run]
# Exit 0 = archive complete, exit 1 = fatal error

set -euo pipefail

COMET_BASH="${COMET_BASH:-${BASH:-bash}}"

red() { echo -e "\033[31m$1\033[0m" >&2; }
green() { echo -e "\033[32m$1\033[0m" >&2; }
yellow() { echo -e "\033[33m$1\033[0m" >&2; }

DRY_RUN=0
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

# Input validation
validate_change_name() {
  local name="$1"
  if [ -z "$name" ]; then
    red "FATAL: Change name cannot be empty"
    exit 1
  fi
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    red "FATAL: Invalid change name: '$name'"
    red "Valid characters: a-z, A-Z, 0-9, -, _"
    exit 1
  fi
  if [[ "$name" =~ \.\. ]]; then
    red "FATAL: Change name cannot contain '..'"
    exit 1
  fi
}

CHANGE="$1"
validate_change_name "$CHANGE"

CHANGE_DIR="openspec/changes/$CHANGE"
YAML="$CHANGE_DIR/.comet.yaml"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")" 2>/dev/null || dirname "$0")" && pwd)"
STATE_SH="$SCRIPT_DIR/comet-state.sh"
TODAY=$(date +%Y-%m-%d)
ARCHIVE_NAME="${TODAY}-${CHANGE}"
ARCHIVE_DIR="openspec/changes/archive/${ARCHIVE_NAME}"

STEPS_OK=0
STEPS_TOTAL=0

step_ok() {
  green "  [OK] $1"
  STEPS_OK=$((STEPS_OK + 1))
  STEPS_TOTAL=$((STEPS_TOTAL + 1))
}

step_fail() {
  red "  [FAIL] $1"
  STEPS_TOTAL=$((STEPS_TOTAL + 1))
}

step_dry_run() {
  yellow "  [DRY-RUN] $1"
  STEPS_OK=$((STEPS_OK + 1))
  STEPS_TOTAL=$((STEPS_TOTAL + 1))
}

echo "=== Comet Archive: $CHANGE ===" >&2

# --- Step 1: Read .comet.yaml, extract paths ---

yaml_field() {
  local field="$1"
  if [ -f "$STATE_SH" ]; then
    "$COMET_BASH" "$STATE_SH" get "$CHANGE" "$field" 2>/dev/null
  else
    if [ -f "$YAML" ]; then
      local value
      value=$(grep "^${field}:" "$YAML" 2>/dev/null | sed "s/^${field}: *//" || true)
      value=$(strip_inline_comment "$value")
      strip_wrapping_quotes "$value"
    fi
  fi
}

strip_inline_comment() {
  local value="$1"
  printf '%s\n' "$value" | awk -v squote="'" '
    {
      out = ""
      quote = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (quote == "") {
          if (c == "\"" || c == squote) {
            quote = c
          } else if (c == "#" && (i == 1 || substr($0, i - 1, 1) ~ /[[:space:]]/)) {
            sub(/[[:space:]]+$/, "", out)
            print out
            next
          }
        } else if (c == quote) {
          quote = ""
        }
        out = out c
      }
      print out
    }
  '
}

strip_wrapping_quotes() {
  local value="$1"
  case "$value" in
    \"*\") printf '%s\n' "${value:1:${#value}-2}" ;;
    \'*\') printf '%s\n' "${value:1:${#value}-2}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

if [ ! -f "$YAML" ]; then
  red "FATAL: .comet.yaml not found in $CHANGE_DIR/"
  exit 1
fi

DESIGN_DOC=$(yaml_field "design_doc")
PLAN_PATH=$(yaml_field "plan")

# --- Step 2: Validate entry state ---

PHASE_VAL=$(yaml_field "phase")
VERIFY_VAL=$(yaml_field "verify_result")
ARCHIVED_VAL=$(yaml_field "archived")

if [ "$PHASE_VAL" != "archive" ]; then
  red "FATAL: phase is '$PHASE_VAL', expected 'archive'"
  exit 1
fi

if [ "$VERIFY_VAL" != "pass" ]; then
  red "FATAL: verify_result is '$VERIFY_VAL', expected 'pass'. Run comet-verify first."
  exit 1
fi

if [ "$ARCHIVED_VAL" = "true" ]; then
  red "FATAL: change already archived"
  exit 1
fi

step_ok "Entry state verified"

# --- Step 3: Check archive target ---

if [ -d "$ARCHIVE_DIR" ]; then
  red "FATAL: archive target already exists: $ARCHIVE_DIR"
  exit 1
fi

step_ok "Archive target available"

# --- Step 4: Sync delta specs → main specs ---

merge_delta_to_main() {
  local delta_spec="$1"
  local main_spec="$2"

  # --- Guard: reject if delta spec has no recognizable sections ---
  if ! grep -qE '^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements' "$delta_spec"; then
    red "  [MERGE-ERROR] Delta spec is missing expected section headers (ADDED/MODIFIED/REMOVED/RENAMED)" >&2
    red "  Delta spec: $delta_spec" >&2
    return 1
  fi

  # --- Case 1: New capability — no existing main spec ---
  if [ ! -f "$main_spec" ]; then
    mkdir -p "$(dirname "$main_spec")"
    awk '
      BEGIN { skip = 0 }
      /^## REMOVED /  { skip = 1; next }
      /^## RENAMED /  { skip = 1; next }
      /^## [A-Z]/     { if (skip) skip = 0 }
      skip            { next }
      /^## ADDED /    { print "## Requirements"; next }
      /^## MODIFIED / { print "## Requirements"; next }
      { print }
    ' "$delta_spec" > "$main_spec"
    return 0
  fi

  # --- Case 2: Existing main spec — intelligent merge ---
  local tmpdir
  tmpdir=$(mktemp -d)

  # Extract delta sections into temp files
  awk '
    BEGIN { s = "" }
    /^## ADDED /       { s = "added";      next }
    /^## MODIFIED /    { s = "modified";   next }
    /^## REMOVED /     { s = "removed";    next }
    /^## RENAMED /     { s = "renamed";    next }
    /^## [A-Z]/        { s = "";           next }
    s == "added"       { print >> "'"$tmpdir"'/added" }
    s == "modified"    { print >> "'"$tmpdir"'/modified" }
    s == "removed"     {
      if ($0 ~ /^### Requirement:/) {
        name = $0; sub(/^### Requirement: /, "", name)
        print name >> "'"$tmpdir"'/removed_names"
      }
    }
    s == "renamed"     { print >> "'"$tmpdir"'/renamed" }
  ' "$delta_spec"

  # Apply merge to main spec
  awk -v added_f="$tmpdir/added" \
      -v modified_f="$tmpdir/modified" \
      -v removed_f="$tmpdir/removed_names" \
      -v renamed_f="$tmpdir/renamed" '
    BEGIN {
      # Read removed requirement names
      while ((getline < removed_f) > 0) { removed[$0] = 1 }
      close(removed_f)

      # Read renamed map (format: "Old Name → New Name" or "Old Name")
      while ((getline < renamed_f) > 0) {
        line = $0
        if (line ~ /^### Requirement:/) {
          sub(/^### Requirement: /, "", line)
        }
        if (match(line, /^(.+) → (.+)$/, m)) {
          rename_map[m[1]] = m[2]
        }
      }
      close(renamed_f)

      # Read modified blocks keyed by requirement name
      mod_name = ""; mod_block = ""
      while ((getline < modified_f) > 0) {
        if ($0 ~ /^### Requirement:/) {
          if (mod_name != "") modified[mod_name] = mod_block
          mod_name = $0; sub(/^### Requirement: /, "", mod_name)
          mod_block = $0 "\n"
        } else {
          mod_block = mod_block $0 "\n"
        }
      }
      if (mod_name != "") modified[mod_name] = mod_block
      close(modified_f)

      # Read added blocks as raw text
      added_text = ""
      while ((getline < added_f) > 0) { added_text = added_text $0 "\n" }
      close(added_f)

      in_req = 0; current_name = ""; skip_mode = 0; added_done = 0
    }

    # --- Track requirement context ---
    /^### Requirement:/ {
      in_req = 1
      current_name = $0
      sub(/^### Requirement: /, "", current_name)

      # REMOVE: skip this requirement and its block
      if (current_name in removed) {
        skip_mode = 1
        next
      }

      # RENAME: update the header
      if (current_name in rename_map) {
        new_name = rename_map[current_name]
        sub(current_name, new_name)
        current_name = new_name
      }

      # MODIFIED: replace with modified block
      if (current_name in modified) {
        printf "%s", modified[current_name]
        skip_mode = 2
        next
      }

      skip_mode = 0
    }

    # Still inside a removed requirement block — skip
    skip_mode == 1 { next }

    # Still inside a modified requirement replacement — skip original lines
    /^### Requirement:/ && skip_mode == 2 { skip_mode = 0 }
    skip_mode == 2 { next }

    # Before next major section, insert added requirements
    !added_done && /^## / && !/^## Requirements/ {
      printf "%s", added_text
      added_done = 1
    }

    { print }

    END {
      if (!added_done) printf "%s", added_text
    }
  ' "$main_spec" > "$tmpdir/merged"

  # Validate merged result
  if grep -qE '^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements' "$tmpdir/merged"; then
    red "  [MERGE-ERROR] Main spec still contains delta-only section headers after merge" >&2
    grep -nE '^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements' "$tmpdir/merged" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  mv "$tmpdir/merged" "$main_spec"
  rm -rf "$tmpdir"
  return 0
}

sync_delta_specs() {
  local delta_root="$CHANGE_DIR/specs"
  if [ ! -d "$delta_root" ]; then
    return 0
  fi

  for delta_spec_dir in "$delta_root"/*/; do
    [ -d "$delta_spec_dir" ] || continue
    local capability
    capability=$(basename "$delta_spec_dir")
    local delta_spec="$delta_spec_dir/spec.md"
    local main_spec="openspec/specs/$capability/spec.md"

    if [ ! -f "$delta_spec" ]; then
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      step_dry_run "Would merge: $capability → $main_spec"
      continue
    fi

    if [ -f "$main_spec" ] && ! cmp -s "$main_spec" "$delta_spec"; then
      yellow "  [DIFF] Delta spec differs from main spec before merge: $capability"
      diff -u "$main_spec" "$delta_spec" >&2 || true
    fi

    if merge_delta_to_main "$delta_spec" "$main_spec"; then
      step_ok "Delta spec merged: $capability → openspec/specs/$capability/spec.md"
    else
      step_fail "Delta spec merge failed: $capability"
      return 1
    fi
  done
}

sync_delta_specs

# --- Step 4b: Post-merge global guard — scan all main specs for delta-only headers ---

validate_main_specs() {
  local violations=0
  if [ -d "openspec/specs" ]; then
    while IFS= read -r spec_file; do
      if grep -qE '^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements' "$spec_file"; then
        red "  [GUARD] Main spec contains delta-only section header: $spec_file" >&2
        grep -nE '^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements' "$spec_file" >&2
        violations=$((violations + 1))
      fi
    done < <(find "openspec/specs" -name "spec.md" -type f 2>/dev/null)
  fi
  if [ "$violations" -gt 0 ]; then
    red "  [GUARD] Found $violations main spec(s) with delta-only headers — archive blocked" >&2
    return 1
  fi
  return 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  step_dry_run "Would validate main specs for delta-only headers"
elif validate_main_specs; then
  step_ok "Main spec validation passed (no delta-only headers)"
else
  step_fail "Main spec validation failed (delta-only headers detected)"
  exit 1
fi

# --- Step 5: Annotate design doc frontmatter ---

annotate_frontmatter() {
  local file="$1"
  local extra_fields="$2"

  if [ ! -f "$file" ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    step_dry_run "Would annotate: $file"
    return 0
  fi

  if head -1 "$file" | grep -q '^---'; then
    local tmp_file
    tmp_file=$(mktemp)
    awk -v archive="$ARCHIVE_NAME" -v extra="$extra_fields" '
      /^archived-with:/ { next }
      NR==1 && /^---/ { print; next }
      /^---/ && NR>1 {
        print "archived-with: " archive
        if (extra != "") print extra
        print; next
      }
      { print }
    ' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
  else
    local tmp_file
    tmp_file=$(mktemp)
    {
      echo "---"
      echo "archived-with: $ARCHIVE_NAME"
      if [ -n "$extra_fields" ]; then
        echo "$extra_fields"
      fi
      echo "status: final"
      echo "---"
      cat "$file"
    } > "$tmp_file"
    mv "$tmp_file" "$file"
  fi

  step_ok "Annotated: $file"
}

if [ -n "$DESIGN_DOC" ] && [ "$DESIGN_DOC" != "null" ]; then
  annotate_frontmatter "$DESIGN_DOC" "status: final"
fi

# --- Step 6: Annotate plan frontmatter ---

if [ -n "$PLAN_PATH" ] && [ "$PLAN_PATH" != "null" ]; then
  annotate_frontmatter "$PLAN_PATH" ""
fi

# --- Step 7: Move change to archive ---

if [ "$DRY_RUN" -eq 1 ]; then
  step_dry_run "Would move: $CHANGE_DIR → $ARCHIVE_DIR"
else
  mkdir -p "openspec/changes/archive"
  mv "$CHANGE_DIR" "$ARCHIVE_DIR"
  step_ok "Moved to: $ARCHIVE_DIR"
fi

# --- Step 8: Mark archived via comet-state transition ---

ARCHIVE_YAML="$ARCHIVE_DIR/.comet.yaml"

if [ "$DRY_RUN" -eq 1 ]; then
  step_dry_run "Would set archived: true in $ARCHIVE_YAML"
else
  if [ -f "$ARCHIVE_YAML" ]; then
    "$COMET_BASH" "$STATE_SH" transition "$ARCHIVE_NAME" archived >/dev/null
    step_ok "archived: true"
  else
    step_fail "archived: true (.comet.yaml not found after move)"
  fi
fi

# --- Step 9: Print summary ---

echo "" >&2
if [ "$DRY_RUN" -eq 1 ]; then
  yellow "Dry run complete. $STEPS_OK/$STEPS_TOTAL steps would succeed."
else
  green "Archive complete. $STEPS_OK/$STEPS_TOTAL steps succeeded."
fi

if [ "$STEPS_OK" -lt "$STEPS_TOTAL" ]; then
  exit 1
fi

exit 0
