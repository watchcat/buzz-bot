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


# Leading chapter-timestamp prefix: "00:00 — ", "1:23:45 - ", "12:30) "
_TS_PREFIX = re.compile(r"^\s*\d{1,2}:\d{2}(?::\d{2})?\s*[—–\-:.)\]]*\s*")
# Standalone time token anywhere: "10:15", "1:23:45"
_TIME_TOKEN = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\b")
# Explicit date string: 17.05.2026 / 2026-05-17 / 05/17/2026
_DATE = re.compile(r"\b\d{1,4}[./-]\d{1,2}[./-]\d{1,4}\b")


def clean_topic_input(text: str | None) -> str:
    """Strip timestamps/dates from the KeyBERT-only input text.

    Removes leading chapter-timestamp prefixes per line (keeping the chapter
    label), and blanks inline time tokens / explicit date strings. Leaves all
    words and number-bearing words intact ('covid 19', '9 мая', 'gpt 4').
    Total function: empty/None/whitespace -> "".
    """
    if not text or not text.strip():
        return ""
    out_lines = []
    for line in text.split("\n"):
        line = _TS_PREFIX.sub("", line, count=1)
        line = _TIME_TOKEN.sub(" ", line)
        line = _DATE.sub(" ", line)
        line = re.sub(r"[ \t]{2,}", " ", line).strip()
        if line:
            out_lines.append(line)
    return "\n".join(out_lines)
