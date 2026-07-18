#!/usr/bin/env python3
"""memory-rebalance: keep a project's core MEMORY.md under the load limit by
moving lower-priority sections into the on-demand MEMORY-extended.md.

WHY: the index grows append-only across many sessions. A harness loads only the
first N KB of MEMORY.md every session, so once it overflows, the tail (often the
standing directives, which sit at the bottom) silently stops loading. Compression
runs out of road well before the growth does; the remaining lever is moving whole
sections to load-on-demand. This tool does that mechanically and reversibly, so
the fix is not a manual rescue every few weeks.

SAFETY: idempotent (no-op when already under budget); backs up both files;
verifies entry conservation and ABORTS on any mismatch; only ever MOVES sections
to the extended file, never deletes. If it CANNOT get core under budget (the
kept core sections are themselves too big), it says so loudly rather than
silently half-fixing. That case needs manual archiving, not a section move.

Usage:
  python3 core/memory-rebalance.py --dir <memory-dir>            # dry-run: report only
  python3 core/memory-rebalance.py --dir <memory-dir> --apply    # back up, then apply

Env:
  DREAMING_MEMORY_DIR             target memory directory (--dir overrides)
  DREAMING_MEMORY_ROOT            projects root, used to resolve a single project
  DREAMING_HOME                   data root (default ~/.dreaming)
  DREAMING_REBALANCE_TARGET_BYTES size to trim the core index down to (default 24000)
  DREAMING_CORE_SECTIONS          section titles, highest priority first, one per
                                  line or comma-separated. Unlisted sections keep
                                  their document order and move out from the bottom.
  DREAMING_PINNED_SECTION         title prefix of the section pinned last in core
                                  (default "More memory")

Exit codes: 0 = healthy or applied, 1 = aborted on entry mismatch, 2 = cannot auto-fix.
"""
import os
import shutil
import sys

DEFAULT_TARGET_BYTES = 24000

# Section header prefixes (after "## ") in PRIORITY order, lowest-priority LAST.
# When core overflows, sections are moved to extended from the BOTTOM of this
# list until core fits, so the highest-priority sections always stay loaded.
#
# This default is deliberately thin. Sections you do not list keep their document
# order and are moved out from the bottom up, which is the sensible behaviour for
# an index that already reads top-down by importance. Set DREAMING_CORE_SECTIONS
# to your own index's section titles when your order differs.
DEFAULT_CORE_SECTIONS = [
    "Standing Directives",
    "Principles",
    "Accounts, IDs & Credentials",
]
DEFAULT_PINNED_LAST = "More memory"  # the load-on-demand pointer always stays last in core


def resolve_memory_dir(argv):
    """--dir wins, then DREAMING_MEMORY_DIR. No implicit project guessing."""
    if "--dir" in argv:
        i = argv.index("--dir")
        if i + 1 >= len(argv):
            sys.stderr.write("memory-rebalance: --dir needs a path\n")
            sys.exit(1)
        return os.path.expanduser(argv[i + 1])
    env_dir = os.environ.get("DREAMING_MEMORY_DIR")
    if env_dir:
        return os.path.expanduser(env_dir)
    return None


def core_sections():
    raw = os.environ.get("DREAMING_CORE_SECTIONS")
    if not raw:
        return list(DEFAULT_CORE_SECTIONS)
    parts = [p.strip() for chunk in raw.splitlines() for p in chunk.split(",")]
    return [p for p in parts if p]


def split_sections(text):
    lines = text.splitlines(keepends=True)
    preamble, sections, cur = [], [], None
    for ln in lines:
        if ln.startswith("## "):
            if cur is not None:
                sections.append(tuple(cur))
            cur = [ln, ""]
        elif cur is None:
            preamble.append(ln)
        else:
            cur[1] += ln
    if cur is not None:
        sections.append(tuple(cur))
    return "".join(preamble), sections


def title(h):
    return h[3:].strip()


def count_entries(body):
    return sum(1 for ln in body.splitlines() if ln.startswith("- "))


def main(argv):
    apply_changes = "--apply" in argv
    mem_dir = resolve_memory_dir(argv)
    if not mem_dir:
        sys.stderr.write(
            "memory-rebalance: no target directory. Pass --dir <memory-dir> "
            "or set DREAMING_MEMORY_DIR.\n"
        )
        return 1

    core = os.path.join(mem_dir, "MEMORY.md")
    ext = os.path.join(mem_dir, "MEMORY-extended.md")
    budget = int(os.environ.get("DREAMING_REBALANCE_TARGET_BYTES", DEFAULT_TARGET_BYTES))
    priority_list = core_sections()
    pinned_last = os.environ.get("DREAMING_PINNED_SECTION", DEFAULT_PINNED_LAST)

    def priority(h):
        t = title(h)
        for i, p in enumerate(priority_list):
            if t.startswith(p):
                return i
        return len(priority_list)  # unknown sections sort just above the pinned section

    if not os.path.exists(core):
        print(f"memory-rebalance: no MEMORY.md at {core}")
        return 0
    with open(core, encoding="utf-8") as fh:
        core_text = fh.read()
    size = len(core_text.encode("utf-8"))
    if size <= budget:
        print(f"memory-rebalance: MEMORY.md is {size} B (<= {budget}), healthy, no-op.")
        return 0

    preamble, sections = split_sections(core_text)
    pinned = [s for s in sections if title(s[0]).startswith(pinned_last)]
    movable = [s for s in sections if not title(s[0]).startswith(pinned_last)]
    # Stable sort: unlisted sections keep their document order.
    movable.sort(key=lambda s: priority(s[0]))

    # Greedily keep highest-priority sections that fit; the rest move out.
    # Everything is measured in bytes, to match the budget the harness applies.
    def nbytes(s):
        return len(s.encode("utf-8"))

    keep, move = [], []
    running = nbytes(preamble) + sum(nbytes(h) + nbytes(b) for h, b in pinned)
    for h, b in movable:
        seclen = nbytes(h) + nbytes(b)
        if running + seclen <= budget:
            keep.append((h, b))
            running += seclen
        else:
            move.append((h, b))

    if not move:
        print(
            f"memory-rebalance: MEMORY.md is {size} B (> {budget}) but NO section "
            f"can be moved: the kept core sections are themselves too big. "
            f"This needs manual archiving (retire shipped/done entries to _archive/), "
            f"NOT a section move. See docs/MEMORY-HYGIENE.md."
        )
        return 2  # honest failure: cannot auto-fix

    keep_in_order = [s for s in sections if s in keep] + pinned
    move_in_order = [s for s in sections if s in move]

    new_core = preamble + "".join(h + b for h, b in keep_in_order)
    moved_titles = ", ".join(title(h) for h, _ in move_in_order)
    moved_block = (
        f"\n\n---\n\n# Moved from core MEMORY.md to stay under the {budget}B load "
        f"limit (load when working these areas)\n\n"
        + "".join(h + b for h, b in move_in_order)
    )
    if os.path.exists(ext):
        with open(ext, encoding="utf-8") as fh:
            ext_text = fh.read()
    else:
        ext_text = "# Memory: Extended (load on demand)\n"
    new_ext = ext_text.rstrip() + "\n" + moved_block

    before = sum(count_entries(b) for _, b in sections)
    after = sum(count_entries(b) for _, b in keep_in_order)
    moved = sum(count_entries(b) for _, b in move_in_order)
    if before != after + moved:
        print(f"memory-rebalance: ABORT: entry mismatch ({before} != {after}+{moved}).")
        return 1

    print(
        f"memory-rebalance: MEMORY.md {size} B -> {len(new_core.encode('utf-8'))} B "
        f"({after} entries kept, {moved} moved to extended)"
    )
    print(f"  moved sections: {moved_titles}")
    if not apply_changes:
        print("  (dry-run: re-run with --apply to write)")
        return 0

    shutil.copy2(core, core + ".bak-rebalance")
    if os.path.exists(ext):
        shutil.copy2(ext, ext + ".bak-rebalance")
    with open(core, "w", encoding="utf-8") as fh:
        fh.write(new_core)
    with open(ext, "w", encoding="utf-8") as fh:
        fh.write(new_ext)
    print("  APPLIED. Backups: MEMORY.md.bak-rebalance, MEMORY-extended.md.bak-rebalance")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
