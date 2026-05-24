#!/bin/bash
# promote-dream.sh — Review-then-adopt workflow for staged dream output.
# Usage:
#   promote-dream.sh list                        # show all pending across projects
#   promote-dream.sh show <run-id> [-p P]        # show what's pending in a run
#   promote-dream.sh adopt <run-id> [-p P]       # apply staged changes (snapshots first)
#   promote-dream.sh discard <run-id> [-p P]     # remove staged changes
#   promote-dream.sh cleanup [--days N]          # rm staging dirs older than N days (default 30)

set -uo pipefail
IFS=$' \t\n'

: "${HOME:?HOME must be set}"

# DREAMING_HOME is the data root; default ~/.dreaming, falls back to ~/.claude for backward compat
DREAMING_HOME="${DREAMING_HOME:-$HOME/.dreaming}"
if [ ! -d "$DREAMING_HOME/projects" ] && [ -d "$HOME/.claude/projects" ]; then
    DREAMING_HOME="$HOME/.claude"
fi
CLAUDE_HOME="$DREAMING_HOME"
PROJECTS_DIR="$CLAUDE_HOME/projects"
PROMOTE_LOG_DIR="$CLAUDE_HOME/promote-logs"
DREAM_LOCK="$CLAUDE_HOME/.dream.lock.d"
PROMOTE_LOCK="$CLAUDE_HOME/.promote.lock.d"
SELF_LEARN_LOCK="$CLAUDE_HOME/.self-learn.lock.d"
DREAM_LAST_FAILED="$CLAUDE_HOME/.dream-last-failed"

# Default: adopt is dry-run. --commit flips this on. Forces explicit confirmation
# for actual mutation, even after the user passes the run-id.
COMMIT=0
# --auto-adopt-trivial: applies trivial files automatically (no dry-run gate),
# leaves non-trivial files in pending for manual review. Implies --commit for trivial.
AUTO_ADOPT=0

mkdir -p "$PROMOTE_LOG_DIR" 2>/dev/null

# ── Mutex (mkdir is atomic on BSD/macOS) ────────────
acquire_promote_lock() {
  if mkdir "$PROMOTE_LOCK" 2>/dev/null; then
    echo "$$" > "$PROMOTE_LOCK/pid" 2>/dev/null || true
    trap 'rm -rf "$PROMOTE_LOCK" 2>/dev/null' EXIT INT TERM
    return 0
  fi
  return 1
}

require_no_dream() {
  if [ -d "$DREAM_LOCK" ]; then
    echo "ERROR: dream.sh appears to be running ($DREAM_LOCK exists). Try again later." >&2
    exit 1
  fi
  if [ -d "$SELF_LEARN_LOCK" ]; then
    echo "ERROR: self-learn.sh appears to be running ($SELF_LEARN_LOCK exists). Try again later." >&2
    exit 1
  fi
}

# ── Validation ──────────────────────────────────────
validate_run_id() {
  local rid="$1"
  case "$rid" in
    ""|.|..|*[!A-Za-z0-9._-]*)
      echo "ERROR: invalid run-id: '$rid' (must match [A-Za-z0-9._-]+)" >&2
      return 1 ;;
  esac
  return 0
}

# Returns the canonical absolute path on success; rejects anything escaping the memory tree.
validate_in_memory_tree() {
  local memory_root="$1" rel="$2" kind="${3:-path}"
  case "$rel" in
    "")
      echo "  REFUSE: $kind is empty" >&2; return 1 ;;
    /*)
      echo "  REFUSE: $kind is absolute: $rel" >&2; return 1 ;;
    *' '*)
      echo "  REFUSE: $kind contains spaces: '$rel'" >&2; return 1 ;;
  esac
  # Bash 3.2 doesn't reliably handle $'\n' in case patterns — use grep instead.
  if printf '%s' "$rel" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo "  REFUSE: $kind contains control chars" >&2; return 1
  fi
  case "/$rel/" in
    */../*|*'/./'*)
      echo "  REFUSE: $kind contains traversal: $rel" >&2; return 1 ;;
  esac
  case "$rel" in
    */*)
      echo "  REFUSE: $kind contains slash (memory layout is flat): $rel" >&2; return 1 ;;
    *.md) ;;
    *)
      echo "  REFUSE: $kind not a .md file: $rel" >&2; return 1 ;;
  esac

  # Canonicalise via parent dir (target may not exist yet)
  local canon_root
  canon_root=$(cd "$memory_root" 2>/dev/null && pwd -P) || {
    echo "  REFUSE: cannot resolve memory_root: $memory_root" >&2; return 1
  }
  local candidate_path="$memory_root/$rel"
  local parent_dir base_name canon_parent canon_path
  parent_dir=$(dirname -- "$candidate_path")
  base_name=$(basename -- "$candidate_path")
  canon_parent=$(cd "$parent_dir" 2>/dev/null && pwd -P) || {
    echo "  REFUSE: parent dir does not resolve: $parent_dir" >&2; return 1
  }
  canon_path="$canon_parent/$base_name"

  case "$canon_path/" in
    "$canon_root"/*) ;;
    *)
      echo "  REFUSE: $kind escapes memory tree: $canon_path (root=$canon_root)" >&2
      return 1 ;;
  esac

  if [ -L "$candidate_path" ]; then
    echo "  REFUSE: $kind is a symlink (refusing to follow): $rel" >&2; return 1
  fi

  printf '%s' "$canon_path"
  return 0
}

# Returns a sorted, NUL-separated list of symlink paths inside the memory tree
# (excluding _archive/). Caller compares per-staged-file resolved path against
# this list and skips the offending file rather than freezing the whole pipeline.
list_symlinks_in_tree() {
  local memory_root="$1"
  find "$memory_root" -mindepth 1 -type l -not -path '*/_archive/*' 2>/dev/null
}

# Returns 0 if `target_path` (or any of its parent dirs under memory_root) is a symlink.
path_traverses_symlink() {
  local memory_root="$1" target_relpath="$2"
  # Walk up from target's parent dir checking each component
  local current="$memory_root/$target_relpath"
  while [ "$current" != "$memory_root" ] && [ "$current" != "/" ]; do
    if [ -L "$current" ]; then
      return 0
    fi
    current=$(dirname "$current")
  done
  return 1
}

# ── Frontmatter parsing ─────────────────────────────
get_fm_value() {
  # Robust: matches `key:` with optional whitespace, with or without space after colon.
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    {
      if (match($0, "^"k"[[:space:]]*:[[:space:]]*")) {
        v = substr($0, RLENGTH+1)
        # trim trailing whitespace
        sub(/[[:space:]]+$/, "", v)
        # strip surrounding single/double quotes
        if (v ~ /^".*"$/) { v = substr(v, 2, length(v)-2) }
        else if (v ~ /^'\''.*'\''$/) { v = substr(v, 2, length(v)-2) }
        print v
        exit
      }
    }
  ' "$file"
}

get_fm_list() {
  # Track indentation of the key, only collect list items at expected child indent.
  # Stops on any non-blank line at indent <= key indent (next sibling or end of mapping).
  local file="$1" key="$2"
  awk -v k="$key:" '
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    {
      # Line indent
      match($0, /^[[:space:]]*/); indent = RLENGTH
      content = substr($0, RLENGTH+1)
    }
    !in_list {
      # Looking for the key at any indent
      if (content ~ "^"k"[[:space:]]*$" || content ~ "^"k"[[:space:]]*$") {
        key_indent = indent
        in_list = 1
        item_indent = -1
        next
      }
      next
    }
    in_list {
      # Blank line — keep scanning
      if (content == "") next
      # Sibling key at same or shallower indent ends the list
      if (indent <= key_indent && content !~ /^- /) {
        in_list = 0
        item_indent = -1
        # Re-process this line as potential next key
        if (content ~ "^"k"[[:space:]]*$") {
          key_indent = indent; in_list = 1; item_indent = -1
        }
        next
      }
      # List item — must be at item_indent (set on first item)
      if (content ~ /^- /) {
        if (item_indent < 0) item_indent = indent
        if (indent == item_indent) {
          val = substr(content, 3)
          sub(/^[[:space:]]+/, "", val)
          sub(/[[:space:]]+$/, "", val)
          # strip surrounding quotes
          if (val ~ /^".*"$/) { val = substr(val, 2, length(val)-2) }
          else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val)-2) }
          if (val != "") print val
        }
      }
    }
  ' "$file"
}

strip_frontmatter() {
  awk '
    BEGIN { fm = 0 }
    /^---$/ { fm++; next }
    fm >= 2 { print }
  ' "$1"
}

# Hash-at-stage verification: refuse to adopt a staged file whose body was
# modified after dream wrote the sha256 sentinel.
verify_staged_hash() {
  local staged="$1"
  local hash_file="$staged.sha256"
  if [ ! -f "$hash_file" ]; then
    echo "  WARN: no hash sentinel for $(basename "$staged") (older staging? proceeding)"
    return 0
  fi
  local stored expected
  stored=$(awk '{print $1; exit}' "$hash_file")
  expected=$(shasum -a 256 "$staged" 2>/dev/null | awk '{print $1}')
  if [ -z "$stored" ] || [ -z "$expected" ]; then
    echo "  ERROR: could not read hash for $(basename "$staged") — refusing"
    return 1
  fi
  if [ "$stored" != "$expected" ]; then
    echo "  ERROR: hash mismatch on $(basename "$staged") — file modified after staging" >&2
    echo "    stored:   $stored" >&2
    echo "    actual:   $expected" >&2
    return 1
  fi
  return 0
}

read_status() {
  local run_path="$1"
  local status_file="$run_path/.status"
  [ -f "$status_file" ] || { echo "pending"; return; }
  awk 'NF{print; exit}' "$status_file" 2>/dev/null | head -1
}

# Returns 0 if a staged file is "trivial" — safe for auto-adoption.
# Criteria (ALL must hold):
#   - target file does NOT exist in live memory yet (no overwrite)
#   - all sources (if any) mtime > 30 days (no churn)
#   - target name not referenced by ANY CLAUDE.md anywhere on disk (low blast radius)
#   - provenance is NOT pure assistant_stream (lower injection risk)
#   - hash sentinel verifies (no tampering)
is_trivial_for_auto_adopt() {
  local proj_dir="$1" staged="$2"
  local memory_root="$proj_dir/memory"
  local target provenance op
  op=$(get_fm_value "$staged" operation)
  target=$(normalise "$(get_fm_value "$staged" target)")
  provenance=$(get_fm_value "$staged" provenance)

  # Reject if target already exists (would overwrite)
  [ -f "$memory_root/$target" ] && return 1
  # Reject pure assistant-stream provenance (highest injection risk)
  case "$provenance" in
    assistant_stream) return 1 ;;
  esac
  # Verify hash sentinel
  verify_staged_hash "$staged" >/dev/null 2>&1 || return 1
  # Reject if any source is recent (churn risk for merges)
  if [ "$op" = "merge" ]; then
    local sources_str s_norm src_path s_age
    sources_str=$(get_fm_list "$staged" sources)
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      s_norm=$(normalise "$src")
      [ -z "$s_norm" ] && continue
      src_path="$memory_root/$s_norm"
      [ -f "$src_path" ] || continue
      s_age=$(( $(date +%s) - $(stat -f %m "$src_path" 2>/dev/null || echo 0) ))
      [ "$s_age" -lt $((30 * 86400)) ] && return 1
    done <<< "$sources_str"
  fi
  # Reject if target name appears in any project CLAUDE.md (load-bearing reference)
  if grep -rl --include='CLAUDE.md' -F "$target" "$HOME/.dreaming" "$HOME/.claude" "$HOME/Projects" 2>/dev/null | head -1 | grep -q .; then
    return 1
  fi
  return 0
}

write_status() {
  local run_path="$1" new_status="$2"
  printf '%s\n' "$new_status" > "$run_path/.status.tmp" && mv "$run_path/.status.tmp" "$run_path/.status"
}

normalise() {
  printf '%s' "$1" | sed -E 's|^\./||; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

# ── Listing / inspection ────────────────────────────
list_pending() {
  local found_any=0
  for proj_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$proj_dir" ] || continue
    local proj_name="${proj_dir%/}"; proj_name="${proj_name##*/}"
    local pending="$proj_dir/memory/_pending_review"
    [ -d "$pending" ] || continue
    for run_dir in "$pending"/*/; do
      [ -d "$run_dir" ] || continue
      local run_id="${run_dir%/}"; run_id="${run_id##*/}"
      local count
      count=$(find "$run_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
      printf "%-60s  run=%s  files=%s\n" "$proj_name" "$run_id" "$count"
      found_any=1
    done
  done
  [ "$found_any" -eq 0 ] && echo "No pending dream reviews."
}

show_run() {
  local run_id="$1" filter_proj="${2:-}"
  validate_run_id "$run_id" || exit 2

  for proj_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$proj_dir" ] || continue
    local proj_name="${proj_dir%/}"; proj_name="${proj_name##*/}"
    [ -n "$filter_proj" ] && [ "$filter_proj" != "$proj_name" ] && continue
    local run_path="$proj_dir/memory/_pending_review/$run_id"
    [ -d "$run_path" ] || continue

    echo "════════════════════════════════════════"
    echo "Project: $proj_name"
    echo "Run:     $run_id"
    echo "════════════════════════════════════════"

    for staged in "$run_path"/*.md; do
      [ -f "$staged" ] || continue
      local op target sources rationale provenance
      op=$(get_fm_value "$staged" operation)
      target=$(get_fm_value "$staged" target)
      rationale=$(get_fm_value "$staged" rationale)
      provenance=$(get_fm_value "$staged" provenance)

      echo ""
      echo "── $(basename "$staged") ──"
      echo "  operation: $op"
      echo "  target:    $target"
      [ -n "$rationale" ] && echo "  rationale: $rationale"
      if [ -n "$provenance" ]; then
        case "$provenance" in
          *assistant*) echo "  ⚠️  provenance: $provenance" ;;
          *) echo "  provenance: $provenance" ;;
        esac
      fi

      case "$op" in
        merge)
          local source_files
          source_files=$(get_fm_list "$staged" sources)
          echo "  sources:"
          while IFS= read -r src; do
            [ -z "$src" ] && continue
            echo "    - $src"
          done <<< "$source_files"
          local live_target="$proj_dir/memory/$target"
          if [ -f "$live_target" ]; then
            echo "  diff against current target ($target), first 80 lines:"
            diff -u "$live_target" <(strip_frontmatter "$staged") 2>/dev/null | head -80 | sed 's/^/    /'
          fi
          ;;
        principle|session_derived)
          local live_target="$proj_dir/memory/$target"
          if [ -f "$live_target" ]; then
            echo "  WARNING: target file already exists at $target"
          fi
          local total_lines body_preview
          total_lines=$(strip_frontmatter "$staged" | wc -l | tr -d ' ')
          echo "  proposed body (first 80 of $total_lines lines):"
          strip_frontmatter "$staged" | head -80 | sed 's/^/    /'
          [ "$total_lines" -gt 80 ] && echo "    ... ($((total_lines - 80)) more lines hidden — open the file directly to see all)"
          ;;
        *)
          echo "  (unknown operation '$op' — manual review needed)"
          ;;
      esac
    done
    echo ""
  done
}

# ── Adoption helpers ────────────────────────────────
update_memory_index_for_merge() {
  local proj_dir="$1" target="$2"; shift 2
  local mem_index="$proj_dir/memory/MEMORY.md"
  [ -f "$mem_index" ] || return 0
  # Drop lines that link to any of the archived sources (passed as remaining args)
  local tmp="$mem_index.tmp.$$"
  cp "$mem_index" "$tmp" || return 1
  local s
  for s in "$@"; do
    [ "$s" = "$target" ] && continue
    # Remove markdown lines that reference $s as a link target; conservative — only drops list items
    grep -v -E "^\s*-\s*\[[^]]+\]\(\s*${s}\s*\)" "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
  done
  mv "$tmp" "$mem_index"
}

apply_merge() {
  local proj_dir="$1" staged="$2"
  local memory_root="$proj_dir/memory"
  local target sources_str
  target=$(normalise "$(get_fm_value "$staged" target)")
  validate_in_memory_tree "$memory_root" "$target" "target" >/dev/null || return 1
  verify_staged_hash "$staged" || return 1

  sources_str=$(get_fm_list "$staged" sources)

  if [ "$COMMIT" -ne 1 ]; then
    local count=0
    while IFS= read -r src; do [ -n "$(normalise "$src")" ] && count=$((count + 1)); done <<< "$sources_str"
    echo "  [DRY RUN] merge → $target (would archive ~$count sources, replace target body)"
    return 0
  fi
  # Validate every source first; refuse the whole merge if any escapes.
  local s_norm
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    s_norm=$(normalise "$src")
    [ -z "$s_norm" ] && continue
    [ "$s_norm" = "$target" ] && continue
    validate_in_memory_tree "$memory_root" "$s_norm" "source" >/dev/null || return 1
  done <<< "$sources_str"

  local live_target="$memory_root/$target"
  local archive_dir="$memory_root/_archive/$(date +%Y-%m-%d)"
  mkdir -p "$archive_dir" || { echo "  FAIL: cannot create $archive_dir"; return 1; }

  # Replace target with merged body atomically
  if ! strip_frontmatter "$staged" > "$live_target.tmp"; then
    echo "  FAIL: strip_frontmatter failed for $staged"
    rm -f "$live_target.tmp"
    return 1
  fi
  if ! mv "$live_target.tmp" "$live_target"; then
    echo "  FAIL: mv $live_target.tmp -> $live_target"
    rm -f "$live_target.tmp"
    return 1
  fi

  # Archive sources
  local archived_sources=()
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    s_norm=$(normalise "$src")
    [ -z "$s_norm" ] && continue
    [ "$s_norm" = "$target" ] && continue
    local src_path="$memory_root/$s_norm"
    if [ -f "$src_path" ]; then
      if mv "$src_path" "$archive_dir/"; then
        archived_sources+=("$s_norm")
      else
        echo "  WARN: could not archive $s_norm"
      fi
    fi
  done <<< "$sources_str"

  # Defence-in-depth: rewrite [[wiki-links]] in the surviving target that
  # point at files we just archived. Dream's prompt now forbids these in
  # the first place, but if the prompt drifts or a hand-crafted merge
  # slips one in, this is the safety net. We strip the broken link
  # (drop `[[X]]` to just `X`) rather than rewriting to the archive path
  # — the reader is on the surviving target; the source's content already
  # lives there (that's what a merge is) so a redirect to the tombstone
  # adds confusion.
  if [ ${#archived_sources[@]} -gt 0 ] && [ -f "$live_target" ]; then
    local rewrite_tmp
    rewrite_tmp=$(mktemp)
    cp "$live_target" "$rewrite_tmp"
    for archived in "${archived_sources[@]}"; do
      # Strip the .md suffix for the wiki-link form
      local base="${archived%.md}"
      # In-place rewrite via sed (BSD-compatible: -i ''). Drops the
      # [[…]] fences, leaves the inner text so prose still reads.
      sed -i '' "s/\[\[${base}\]\]/${base}/g" "$rewrite_tmp" 2>/dev/null || true
    done
    if ! cmp -s "$rewrite_tmp" "$live_target"; then
      mv "$rewrite_tmp" "$live_target" && \
        echo "  ✓ rewrote ${#archived_sources[@]} wiki-link(s) to archived sources"
    else
      rm -f "$rewrite_tmp"
    fi
  fi

  # Update MEMORY.md to drop archived-source links.
  # ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty —
  # safe under `set -u` which would otherwise reject "${arr[@]}" with
  # "unbound variable" if no sources got archived (target was the only
  # source, or all sources were already missing).
  update_memory_index_for_merge "$proj_dir" "$target" ${archived_sources[@]+"${archived_sources[@]}"} || \
    echo "  WARN: MEMORY.md index update failed (manual review recommended)"

  echo "  ✓ merged → $target (${#archived_sources[@]} sources archived)"
  return 0
}

apply_principle() {
  local proj_dir="$1" staged="$2"
  local memory_root="$proj_dir/memory"
  local target add_footer
  target=$(normalise "$(get_fm_value "$staged" target)")
  validate_in_memory_tree "$memory_root" "$target" "target" >/dev/null || return 1
  verify_staged_hash "$staged" || return 1
  add_footer=$(get_fm_value "$staged" add_related_footer_to_sources)

  local live_target="$memory_root/$target"
  if [ -f "$live_target" ]; then
    echo "  WARN: $target already exists, skipping (resolve manually)"
    return 1
  fi

  if [ "$COMMIT" -ne 1 ]; then
    echo "  [DRY RUN] principle → $target (would create new file, footer=$add_footer)"
    return 0
  fi

  # Strip frontmatter when copying — staging metadata doesn't belong in live memory
  if ! strip_frontmatter "$staged" > "$live_target.tmp"; then
    echo "  FAIL: strip_frontmatter failed for $staged"
    rm -f "$live_target.tmp"
    return 1
  fi
  if ! mv "$live_target.tmp" "$live_target"; then
    echo "  FAIL: mv $live_target.tmp -> $live_target"
    rm -f "$live_target.tmp"
    return 1
  fi

  # Optional: add Related-principle footers to validated source files
  if [ "$add_footer" = "true" ]; then
    local sources_str s_norm
    sources_str=$(get_fm_list "$staged" sources)
    while IFS= read -r src; do
      [ -z "$src" ] && continue
      s_norm=$(normalise "$src")
      [ -z "$s_norm" ] && continue
      validate_in_memory_tree "$memory_root" "$s_norm" "source" >/dev/null || continue
      local src_path="$memory_root/$s_norm"
      if [ -f "$src_path" ] && ! grep -q -F "Related principle: [$target]" "$src_path" 2>/dev/null; then
        printf "\n\n*Related principle: [%s](%s)*\n" "$target" "$target" >> "$src_path"
      fi
    done <<< "$sources_str"
  fi

  # Update MEMORY.md if the index has an "Open principles" section (best effort)
  local mem_index="$proj_dir/memory/MEMORY.md"
  if [ -f "$mem_index" ] && ! grep -q -F "[$target]" "$mem_index" 2>/dev/null; then
    printf "\n- [%s](%s) — added by /promote-dream %s\n" "$target" "$target" "$(date +%Y-%m-%d)" >> "$mem_index"
  fi

  echo "  ✓ principle adopted → $target"
  return 0
}

apply_session_derived() {
  local proj_dir="$1" staged="$2"
  local memory_root="$proj_dir/memory"
  local target provenance
  target=$(normalise "$(get_fm_value "$staged" target)")
  validate_in_memory_tree "$memory_root" "$target" "target" >/dev/null || return 1
  verify_staged_hash "$staged" || return 1
  provenance=$(get_fm_value "$staged" provenance)

  local live_target="$memory_root/$target"
  if [ -f "$live_target" ]; then
    echo "  WARN: $target already exists, skipping"
    return 1
  fi

  if [ "$COMMIT" -ne 1 ]; then
    local prov_warn=""
    case "$provenance" in *assistant*) prov_warn=" ⚠️  ASSISTANT-STREAM" ;; esac
    echo "  [DRY RUN] session_derived → $target (provenance=${provenance:-unknown}$prov_warn)"
    return 0
  fi

  if ! strip_frontmatter "$staged" > "$live_target.tmp"; then
    echo "  FAIL: strip_frontmatter failed for $staged"
    rm -f "$live_target.tmp"
    return 1
  fi
  if ! mv "$live_target.tmp" "$live_target"; then
    echo "  FAIL: mv $live_target.tmp -> $live_target"
    rm -f "$live_target.tmp"
    return 1
  fi

  local mem_index="$proj_dir/memory/MEMORY.md"
  if [ -f "$mem_index" ] && ! grep -q -F "[$target]" "$mem_index" 2>/dev/null; then
    printf "\n- [%s](%s) — added by /promote-dream (session-derived) %s\n" "$target" "$target" "$(date +%Y-%m-%d)" >> "$mem_index"
  fi

  echo "  ✓ session-derived adopted → $target"
  return 0
}

# ── Adopt / discard / cleanup ───────────────────────
adopt_run() {
  local run_id="$1" filter_proj="${2:-}"
  validate_run_id "$run_id" || exit 2
  require_no_dream
  acquire_promote_lock || { echo "ERROR: another promote-dream is running" >&2; exit 1; }

  # Refuse if last dream run failed and we don't know if staged files are intact
  if [ -f "$DREAM_LAST_FAILED" ]; then
    echo "ERROR: dream.sh last run failed (see $DREAM_LAST_FAILED)." >&2
    echo "  Inspect logs and either fix-and-retry dream OR \`rm $DREAM_LAST_FAILED\` to override." >&2
    exit 3
  fi

  if [ "$COMMIT" -ne 1 ]; then
    echo "🔍 DRY RUN — no files will be modified. Pass --commit to actually apply."
    echo ""
  fi

  local snapshot_root="$PROMOTE_LOG_DIR/snapshots/$(date +%Y-%m-%dT%H-%M-%S)-$$"
  if [ "$COMMIT" -eq 1 ]; then
    mkdir -p "$snapshot_root" || { echo "ERROR: cannot create snapshot dir"; exit 1; }
  fi
  local any_applied=0

  for proj_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$proj_dir" ] || continue
    local proj_name="${proj_dir%/}"; proj_name="${proj_name##*/}"
    [ -n "$filter_proj" ] && [ "$filter_proj" != "$proj_name" ] && continue
    local run_path="$proj_dir/memory/_pending_review/$run_id"
    [ -d "$run_path" ] || continue

    echo "Project: $proj_name"

    # Defence-in-depth: warn on symlinks present in tree but don't freeze the
    # entire project — apply_* functions individually reject symlinked targets.
    local symlink_warn
    symlink_warn=$(list_symlinks_in_tree "$proj_dir/memory" | head -3)
    if [ -n "$symlink_warn" ]; then
      echo "  ⚠️  Symlinks present in memory tree (will skip per-file if target traverses):"
      echo "$symlink_warn" | sed 's/^/    /'
    fi

    # Snapshot before applying (commit mode only)
    local applied_dir=""
    if [ "$COMMIT" -eq 1 ]; then
      if ! cp -R "$proj_dir/memory" "$snapshot_root/$proj_name.before"; then
        echo "  ERROR: snapshot failed; refusing to apply"
        continue
      fi
      applied_dir="$snapshot_root/$proj_name.applied"
      mkdir -p "$applied_dir"
    fi

    for staged in "$run_path"/*.md; do
      [ -f "$staged" ] || continue
      local op
      op=$(get_fm_value "$staged" operation)
      local applied_this=0
      # Auto-adopt path: skip non-trivial files, force apply for trivial
      if [ "$AUTO_ADOPT" -eq 1 ]; then
        if is_trivial_for_auto_adopt "$proj_dir" "$staged"; then
          echo "  [AUTO-ADOPT] $(basename "$staged") qualifies (target absent, sources >30d, no CLAUDE.md ref, hash valid)"
          # COMMIT is already 1 globally because --auto-adopt-trivial implies --commit
        else
          echo "  [SKIP] $(basename "$staged") not auto-adopt-trivial (manual review required)"
          continue
        fi
      fi
      case "$op" in
        merge) apply_merge "$proj_dir" "$staged" && applied_this=1 ;;
        principle) apply_principle "$proj_dir" "$staged" && applied_this=1 ;;
        session_derived) apply_session_derived "$proj_dir" "$staged" && applied_this=1 ;;
        *) echo "  SKIP: unknown or empty operation '$op' in $(basename "$staged")" ;;
      esac
      if [ "$applied_this" -eq 1 ]; then
        any_applied=1
        if [ "$COMMIT" -eq 1 ] && [ -n "$applied_dir" ]; then
          mv "$staged" "$applied_dir/" 2>/dev/null || \
            echo "  WARN: could not move applied staged file $(basename "$staged") to history"
          # Also move the .sha256 sentinel alongside
          [ -f "$staged.sha256" ] && mv "$staged.sha256" "$applied_dir/" 2>/dev/null
        fi
      fi
    done

    if [ "$COMMIT" -eq 1 ]; then
      # Move .status sentinel into applied history if present
      [ -f "$run_path/.status" ] && mv "$run_path/.status" "$applied_dir/" 2>/dev/null
      # Remove run_path only if all files were applied (it's empty of .md)
      if [ -z "$(ls -A "$run_path" 2>/dev/null)" ]; then
        rmdir "$run_path" 2>/dev/null
        echo "  All files in $run_id adopted."
      else
        echo "  Some files left in _pending_review/$run_id (not applied — re-run after fixing)."
      fi
    fi
    echo ""
  done

  if [ "$any_applied" -eq 0 ]; then
    echo "Nothing to adopt for run-id $run_id."
    [ "$COMMIT" -eq 1 ] && rm -rf "$snapshot_root" 2>/dev/null
  elif [ "$COMMIT" -eq 1 ]; then
    echo "✓ Adoption complete. Snapshot at: $snapshot_root"
  else
    echo ""
    echo "Dry run complete. To actually apply: $0 adopt $run_id${filter_proj:+ -p $filter_proj} --commit"
  fi
}

# ── Status (defer / mark reviewed) ──────────────────
set_run_status() {
  local cmd="$1" run_id="$2" filter_proj="${3:-}"
  validate_run_id "$run_id" || exit 2
  local new_status
  case "$cmd" in
    defer) new_status="deferred" ;;
    reviewed) new_status="reviewed_no_action" ;;
    *) echo "ERROR: unknown status command '$cmd'"; exit 2 ;;
  esac
  local found=0
  for proj_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$proj_dir" ] || continue
    local proj_name="${proj_dir%/}"; proj_name="${proj_name##*/}"
    [ -n "$filter_proj" ] && [ "$filter_proj" != "$proj_name" ] && continue
    local run_path="$proj_dir/memory/_pending_review/$run_id"
    [ -d "$run_path" ] || continue
    write_status "$run_path" "$new_status"
    echo "Marked $proj_name/$run_id as: $new_status"
    found=1
  done
  [ "$found" -eq 0 ] && echo "No matching pending dirs."
}

discard_run() {
  local run_id="$1" filter_proj="${2:-}"
  validate_run_id "$run_id" || exit 2
  require_no_dream
  acquire_promote_lock || { echo "ERROR: another promote-dream is running" >&2; exit 1; }

  local any_discarded=0
  for proj_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$proj_dir" ] || continue
    local proj_name="${proj_dir%/}"; proj_name="${proj_name##*/}"
    [ -n "$filter_proj" ] && [ "$filter_proj" != "$proj_name" ] && continue
    local run_path="$proj_dir/memory/_pending_review/$run_id"
    [ -d "$run_path" ] || continue
    rm -rf "$run_path"
    echo "Discarded: $proj_name/memory/_pending_review/$run_id"
    any_discarded=1
  done
  [ "$any_discarded" -eq 0 ] && echo "No matching pending dirs to discard."
}

# ── Restore from archive (undo) ─────────────────────
restore_from_archive() {
  local target="$1" filter_proj="${2:-}"
  if [ -z "$target" ]; then
    echo "Usage: $0 restore <filename.md> [-p project]"
    echo "  Restores a single file from any project's memory/_archive/<date>/ back to live memory"
    exit 2
  fi
  case "$target" in
    */*|..|.|*[!a-zA-Z0-9._-]*|"")
      echo "ERROR: invalid filename '$target' — must be a flat .md filename"
      exit 2 ;;
  esac
  require_no_dream
  acquire_promote_lock || { echo "ERROR: another promote-dream is running" >&2; exit 1; }

  local found=0
  for proj_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$proj_dir" ] || continue
    local proj_name="${proj_dir%/}"; proj_name="${proj_name##*/}"
    [ -n "$filter_proj" ] && [ "$filter_proj" != "$proj_name" ] && continue
    # Find newest copy of this filename in any archive date dir
    local archived
    archived=$(find "$proj_dir/memory/_archive" -name "$target" -type f 2>/dev/null | \
      while read -r f; do
        printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || echo 0)" "$f"
      done | sort -rn | head -1 | cut -f2-)
    [ -z "$archived" ] && continue
    local live="$proj_dir/memory/$target"
    if [ -f "$live" ]; then
      echo "  $proj_name: $target already exists in live memory; refusing to overwrite"
      continue
    fi
    if mv "$archived" "$live"; then
      echo "  $proj_name: restored $target from $(dirname "$archived" | sed 's|.*/_archive/||')"
      found=1
    else
      echo "  $proj_name: restore failed for $target"
    fi
  done
  [ "$found" -eq 0 ] && echo "No archived '$target' found across project memories."
}

cleanup_old() {
  local days="${1:-30}"
  case "$days" in
    *[!0-9]*|"") echo "ERROR: --days must be a non-negative integer"; exit 2 ;;
  esac
  require_no_dream
  acquire_promote_lock || { echo "ERROR: another promote-dream is running" >&2; exit 1; }

  local audit_log="$PROMOTE_LOG_DIR/cleanup-$(date +%Y-%m-%d).log"
  local removed=0
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    # Only sweep dirs whose status is "pending" (default). Skip deferred / reviewed.
    local status
    status=$(read_status "$dir")
    if [ "$status" != "pending" ]; then
      echo "Skipping (status=$status): $dir"
      continue
    fi
    rm -rf "$dir" 2>/dev/null && {
      echo "$(date '+%H:%M:%S') removed: $dir" >> "$audit_log"
      echo "Removed: $dir"
      removed=$((removed + 1))
    }
  done < <(find "$PROJECTS_DIR" -path '*/_pending_review/*' -type d -mtime "+$days" -prune -print 2>/dev/null)

  [ "$removed" -eq 0 ] && echo "Nothing older than $days days." || \
    echo "Cleaned $removed pending-review dirs. Audit: $audit_log"
}

# ── Argument parsing ────────────────────────────────
cmd="${1:-list}"
shift || true

filter_proj=""
days=30
positional=""

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--project) filter_proj="$2"; shift 2 ;;
    --days) days="$2"; shift 2 ;;
    --commit) COMMIT=1; shift ;;
    --auto-adopt-trivial) AUTO_ADOPT=1; COMMIT=1; shift ;;
    -*) echo "Unknown flag: $1"; exit 2 ;;
    *) positional="$1"; shift ;;
  esac
done

case "$cmd" in
  list) list_pending ;;
  show)
    [ -z "$positional" ] && { echo "Usage: $0 show <run-id> [-p project]"; exit 2; }
    show_run "$positional" "$filter_proj" ;;
  adopt)
    [ -z "$positional" ] && { echo "Usage: $0 adopt <run-id> [-p project] [--commit]"; exit 2; }
    adopt_run "$positional" "$filter_proj" ;;
  discard)
    [ -z "$positional" ] && { echo "Usage: $0 discard <run-id> [-p project]"; exit 2; }
    discard_run "$positional" "$filter_proj" ;;
  defer)
    [ -z "$positional" ] && { echo "Usage: $0 defer <run-id> [-p project]"; exit 2; }
    set_run_status defer "$positional" "$filter_proj" ;;
  reviewed)
    [ -z "$positional" ] && { echo "Usage: $0 reviewed <run-id> [-p project]"; exit 2; }
    set_run_status reviewed "$positional" "$filter_proj" ;;
  cleanup) cleanup_old "$days" ;;
  restore)
    [ -z "$positional" ] && { echo "Usage: $0 restore <filename.md> [-p project]"; exit 2; }
    restore_from_archive "$positional" "$filter_proj" ;;
  *)
    echo "Usage: $0 {list|show|adopt|discard|defer|reviewed|cleanup|restore} [<arg>] [-p project] [--days N] [--commit]"
    exit 2 ;;
esac
