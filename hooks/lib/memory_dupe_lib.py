# memory_dupe_lib.py: shared tokeniser/similarity for memory-dupe-check.sh
# (exec'd by the bash wrapper; kept separate so hook mode and --scan mode
# can't drift apart). Threshold tuned against a ~400-file memory corpus.
import re as _re

# Type prefixes + glue words carry no meaning for "is this the same fact?"
_STOP = {
    "feedback", "project", "reference", "user", "audit", "memory", "memories",
    "the", "and", "for", "not", "with", "via", "into", "from", "this", "that",
    "always", "never", "dont", "don", "before", "after", "when", "use", "using",
    "are", "was", "were", "has", "have", "its", "one", "per", "all", "any",
    "detail", "inside", "see",
}


def _tokens(text):
    words = _re.split(r"[^a-z0-9]+", text.lower())
    out = set()
    for w in words:
        if len(w) < 3 or w.isdigit() or w in _STOP:
            continue
        if w.endswith("s") and len(w) > 3:  # naive plural-strip: deploy/deploys must match
            w = w[:-1]
        out.add(w)
    return out


def signature(path):
    """Token set from filename + frontmatter description (+ title line)."""
    import os
    toks = _tokens(os.path.basename(path).rsplit(".", 1)[0])
    try:
        with open(path, errors="ignore") as f:
            head = f.read(2000)
        m = _re.search(r"^description:\s*(.+)$", head, _re.M)
        if m:
            toks |= _tokens(m.group(1))
        m = _re.search(r"^#\s+(.+)$", head, _re.M)
        if m:
            toks |= _tokens(m.group(1))
    except OSError:
        pass
    return toks


def jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)
