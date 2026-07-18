# Memory Hygiene

**What this is:** a linter for filesystem-markdown agent memory, plus three
write-time and read-time hooks. It is not a memory system. It does not store,
embed, or retrieve anything. It checks that the memory you already have is still
findable, and it records evidence about how that memory is actually used.

It complements runtime memory services (mem0, Letta, Zep) rather than competing
with them. Those answer "what should the agent recall right now?". This answers
"is the corpus on disk still healthy, and how do we know?".

---

## The problem: memory rot

Filesystem memory has a specific failure mode that is invisible from inside a
session. Memory is written by many sessions over months, and read by an index
that the harness loads automatically. Four things go wrong quietly:

| Rot | What happens | Why it is invisible |
|---|---|---|
| **Orphaning** | A memory file is written but never indexed | The file exists, so nothing errors. It is simply never loaded again. |
| **Dead links** | An index points at a file that was renamed or archived | The pointer still looks fine in the index. |
| **Truncation** | The index grows past what the harness loads | No error. The tail of the file, often the standing directives, silently stops arriving. |
| **Staleness** | Finished work stays in the index forever | It costs context on every single session, for knowledge nobody needs. |

None of these produce an error message. They produce a slow decline in how much
the agent knows, and the decline is only noticed when an agent confidently
contradicts something it "learned" months ago.

---

## The seven checks

`dreaming hygiene` sweeps every `<memory-root>/*/memory/` directory that
contains a `MEMORY.md`. It **never mutates**. Hard checks exit 1; advisory
checks print and leave the exit code alone, so exit 0 still means healthy.

| # | Check | Grade | What it catches |
|---|---|---|---|
| 1 | **ORPHAN** | hard | A topic `.md` file not referenced in `MEMORY.md` or any `MEMORY-*.md`. Written but unrecallable. |
| 2 | **BROKEN** | hard | A `(file.md)` link in an index whose target does not exist on disk. |
| 3 | **SIZE** | hard | `MEMORY.md` over the byte budget. Only the auto-loaded index counts; `MEMORY-*.md` sub-indexes are on demand. |
| 4 | **LONGLINE** | hard | Index entries over the per-line character budget. An index entry is a pointer, not the content. |
| 5 | **NEARING** | advisory | `MEMORY.md` past the warn threshold. Fires before truncation, not after. |
| 6 | **RETIRE** | advisory | A stale topic file whose index line reads as finished work. Candidates only. |
| 7 | **ROT** | advisory | A `reference`-type file citing an absolute path that no longer exists. The memory is describing something that has gone. |

Two exemptions in the RETIRE check are deliberate and worth stating plainly:

- **Standing directives never age out.** A topic file whose frontmatter declares
  `type: feedback` or `type: user` is never offered for retirement, however old
  it is and however finished its index line looks. A standing instruction is not
  less true for being six months old.
- **A keep-guard beats a completion marker.** An index line containing phrases
  like `canonical`, `source of truth`, `mandatory`, or `do not remove` is skipped
  even when it also says `shipped`. Work can be finished and the knowledge about
  it still load-bearing.

Retirement itself is a judgement call, so the linter only ever reports. The
actual move into `_archive/` happens during a dream run, where an LLM can read
the file and decide.

---

## The three ideas worth stealing

Most of this component is unremarkable linting. Three parts are not, and they
are the reason it exists in this shape.

### 1. Duplicate catches are logged as recall misses

`memory-dupe-check.sh` fires when a session writes a **new** memory file that
overlaps an existing one. The obvious framing is bloat control: stop the corpus
filling with four files about the same fact.

The more useful framing is what a duplicate actually proves. The session had
that knowledge already, on disk, in the same directory, and did not find it
before deciding to write it again. That is a **retrieval failure**, not a
discipline failure, and it is one of the few retrieval failures that leaves
physical evidence.

So every catch appends a line to `$DREAMING_HOME/memory-dupe-log.jsonl`. Over
months that file becomes a measured miss rate for filename-and-title matching
against a growing corpus. It answers a question that is otherwise pure vibes:
**do we need vector search yet?** A flat miss rate says the current approach is
holding. A rising one says the corpus has outgrown lexical matching, and now
there is a number to point at rather than an intuition. Building the embedding
layer before that signal appears is solving a problem you have not got.

The check is deliberately naive: Jaccard overlap of tokens from the filename,
the frontmatter description, and the title line. Naive is the point. A clever
matcher would hide the very signal being measured.

Only newly created files are checked, so updating an existing memory, which is
exactly the right behaviour, is never warned about.

### 2. Read counts make retirement evidence-based

Both the RETIRE check and the retire step in a dream run grade memories by
**age**, because age is the only signal lying around. Age is a poor proxy. A
file untouched for six months may be the one that saves the next session, and a
file written last week may never be opened again.

`memory-usage-tally.sh` records one JSONL line per read of a memory file. After
a few weeks, `--report` distinguishes the memories that are actually recalled
from the ones that merely exist. Retirement can then be argued from read counts
instead of from mtimes.

The tally deliberately ignores index files. Indexes load through the harness
rather than through a read tool, so a zero count against `MEMORY.md` means
nothing at all.

This is the slowest-burning part of the toolkit. It is worth nothing on day one
and quite a lot on day ninety, which is an argument for wiring it up early.

### 3. Rebalance against the ceiling instead of compressing harder

When an auto-loaded index outgrows what the harness loads, the instinct is to
compress: shorter entries, tighter phrasing, more abbreviations. That works
twice. After that the index is dense, hard to read, and still growing.

The ceiling is the real constraint, and it does not move. `memory-rebalance.py`
treats it as fixed and moves whole sections out of the auto-loaded `MEMORY.md`
into a load-on-demand `MEMORY-extended.md`, lowest priority first, until the
core fits. Nothing is deleted. Nothing is summarised. The knowledge stays, it
just stops being loaded on every single session.

The priority order is the whole design decision, so it is configuration rather
than a default. What must survive truncation is usually the standing directives,
which in an append-only index tend to sit at the bottom, which is exactly what
gets cut first.

Three safety properties matter more than the packing logic:

- It **counts entries before and after** and aborts on any mismatch. A rebalance
  that loses a line is worse than no rebalance.
- It is **dry-run by default** and backs both files up before writing.
- When it **cannot** fix the problem, it says so and exits 2 rather than
  half-fixing. An index that is over budget with no section structure needs
  archiving, not a section move, and it says that instead of pretending.

---

## Usage

```bash
dreaming hygiene                          # sweep every project, exit 1 on hard issues
dreaming hygiene --project myproj         # one project (case-insensitive substring)

dreaming rebalance --dir <memory-dir>          # dry-run: report what would move
dreaming rebalance --dir <memory-dir> --apply  # back up, then move

bash hooks/memory-usage-tally.sh --report      # most-read and never-read memories
bash hooks/memory-dupe-check.sh --scan <dir> [threshold]   # calibrate the threshold
```

`dreaming hygiene` is a good step 0 for a dream run: it tells the LLM which
directories need attention before it starts reading.

**Exit codes.** Hygiene: 0 healthy (advisories may still print), 1 hard issues.
Rebalance: 0 healthy or applied, 1 aborted on entry mismatch or bad arguments,
2 cannot auto-fix.

---

## Wiring the hooks

The three hooks are Claude Code `PostToolUse` hooks. In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          { "type": "command", "command": "bash ~/Projects/dreaming/hooks/memory-index-drift.sh" },
          { "type": "command", "command": "bash ~/Projects/dreaming/hooks/memory-dupe-check.sh" }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          { "type": "command", "command": "bash ~/Projects/dreaming/hooks/memory-usage-tally.sh" }
        ]
      }
    ]
  }
}
```

On another harness, wire the equivalent post-write and post-read events. Each
hook reads one JSON object on stdin and looks for `.tool_input.file_path`.

Behaviour worth knowing before you wire them in:

| Hook | Event | Exit | Effect |
|---|---|---|---|
| `memory-index-drift.sh` | write | always 0 | Prints to stdout, which the session sees. Never blocks. Also warns when `MEMORY.md` passes the warn threshold. |
| `memory-dupe-check.sh` | write | 2 on match | Exit 2 feeds stderr back to the session. The write has already happened, so this is a prompt to merge, not a block. |
| `memory-usage-tally.sh` | read | always 0 | Appends one line. Silent. |

`memory-index-drift.sh` needs `jq` and exits silently without it. The other two
need `python3`. All three are silent when nothing qualifies, which is most of
the time.

**Kill switch:** `touch $DREAMING_HOME/.memory-index-drift-disabled` stops the
drift hook without editing settings.

---

## Configuration

Everything is an environment variable with a default. The defaults are starting
points, not physics.

| Variable | Default | What it controls |
|---|---|---|
| `DREAMING_MEMORY_ROOT` | `$DREAMING_HOME/projects` | Where the `<project>/memory/` directories live. Falls back to `~/.claude/projects` when `$DREAMING_HOME` is not set up, matching the other hooks. |
| `DREAMING_INDEX_BUDGET_BYTES` | `32768` | Hard ceiling for `MEMORY.md`. Over this, check 3 fails. |
| `DREAMING_INDEX_WARN_PCT` | `80` | Warn at this percentage of the ceiling (check 5). |
| `DREAMING_INDEX_LINE_BUDGET` | `300` | Maximum characters per index entry (check 4). |
| `DREAMING_RETIRE_AGE_DAYS` | `45` | Staleness threshold for retire candidates (check 6). |
| `DREAMING_HOME_PATH_PATTERN` | `$HOME` | Absolute-path prefix the ROT check looks for (check 7). |
| `DREAMING_REBALANCE_TARGET_BYTES` | `24000` | Size the rebalancer trims the core index down to. |
| `DREAMING_CORE_SECTIONS` | see below | Section titles, highest priority first, comma or newline separated. |
| `DREAMING_PINNED_SECTION` | `More memory` | Title prefix of the section pinned last in core. |
| `DREAMING_MEMORY_DIR` | none | Target directory for the rebalancer, if you would rather not pass `--dir`. |
| `MEMORY_DUPE_THRESHOLD` | `0.45` | Jaccard similarity above which a new memory is flagged. |

**On the two size budgets.** The hard ceiling (32768) and the rebalance target
(24000) are separate on purpose. The ceiling is where things break; the target
is where you want to sit, with room to grow before the next rebalance. Trimming
back to exactly the ceiling just means rebalancing again next week.

Both numbers are guesses about someone else's harness. Measure where your own
index actually starts truncating and set them from that. The honest position is
that the tool cannot detect the ceiling for you, so it makes it configurable and
warns early.

**On `DREAMING_CORE_SECTIONS`.** The default is deliberately thin
(`Standing Directives`, `Principles`, `Accounts, IDs & Credentials`). Sections
you do not list keep their document order and move out from the bottom up, which
is the right behaviour for an index that already reads top-down by importance.
Set it explicitly when your order differs.

---

## Tests

```bash
bash tests/run-hygiene-tests.sh
```

51 assertions over synthetic memory directories in a temp dir. Every check is
asserted to fire, the two RETIRE exemptions are asserted to hold, and the linter
is fingerprinted before and after a dirty run to prove it never mutates.

The rebalancer, the only component here that writes, is only ever pointed at
temp fixtures. The fixture sizes are chosen so that some sections fit and others
do not, because a budget below the size of any single section would move
everything and make the priority assertions pass without testing anything.

---

## What this deliberately does not do

- **It does not fix anything automatically.** The linter only reports. The
  rebalancer only moves sections, only when asked, and backs up first.
- **It does not judge quality.** Whether a memory is worth keeping is a
  judgement call for a dream run, not a grep.
- **It does not do retrieval.** No embeddings, no ranking, no recall. The dupe
  check measures how badly lexical matching is doing, which is a different job
  from doing better than lexical matching.
