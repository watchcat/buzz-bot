"""Pure topic-hygiene helpers for embed-worker KeyBERT extraction.

Dependency-free (only `re`) so it is unit-testable without torch/keybert.
`is_noise_topic` is intentionally identical to cluster-worker's copy and the
Task 9 SQL regex — the shared test assertion table guards against drift.
"""
import re

_NUM_ONLY = re.compile(r"[\d\s:.\-/]+")
_YEAR_WORD = re.compile(r"20\d{2}(\s+(год|году|year|jaar))?", re.IGNORECASE)


def is_noise_topic(t: str) -> bool:
    """True if the topic string is a pure date/number fragment (no real word).
    Conservative: only nukes strings that are ENTIRELY digits/separators, or a
    bare 4-digit year optionally followed by a year-word. Anything containing a
    real word (any language) is kept ('covid 19', '9 мая' survive).
    """
    s = t.strip()
    if not s:
        return True
    if _NUM_ONLY.fullmatch(s):
        return True
    if _YEAR_WORD.fullmatch(s):
        return True
    return False
