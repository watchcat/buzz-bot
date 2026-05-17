from topic_clean import is_noise_topic, clean_topic_input


def test_filters_pure_date_number_noise():
    for s in ["03", "05", "00 00", "20 03", "13 03", "2026", "2026 07",
              "26 2026", "03 2026", "  12  05 ", "2026 год", "2026 году",
              "04 26", "00 01", "2026 14"]:
        assert is_noise_topic(s), f"should be noise: {s!r}"


def test_keeps_real_topics():
    for s in ["war", "экономика", "ukraine", "oorlog", "covid 19",
              "9 мая", "g7", "iran war", "блокировки telegram"]:
        assert not is_noise_topic(s), f"should be kept: {s!r}"


def test_strips_leading_chapter_timestamps_keeps_labels():
    src = "00:00 — Introduction\n1:23:45 — Future of gaming\n12:30 - Blizzard"
    assert clean_topic_input(src) == "Introduction\nFuture of gaming\nBlizzard"


def test_blanks_inline_time_and_date_strings():
    out = clean_topic_input("recorded 10:15:30 on 17.05.2026 about gaming")
    assert "10:15:30" not in out and "17.05.2026" not in out
    assert "recorded" in out and "gaming" in out


def test_preserves_number_bearing_real_topics():
    src = "9 мая is Victory Day\nnotes on covid 19 and gpt 4"
    out = clean_topic_input(src)
    assert "9 мая" in out and "covid 19" in out and "gpt 4" in out


def test_safe_on_empty_and_none():
    assert clean_topic_input("") == ""
    assert clean_topic_input(None) == ""
    assert clean_topic_input("   ") == ""


def test_non_timestamp_numeric_lines_survive():
    # "1." is not MM:SS — must NOT be treated as a timestamp prefix
    assert clean_topic_input("1. First real topic") == "1. First real topic"


import os
import pytest


@pytest.mark.skipif(
    os.environ.get("RUN_MODEL_TESTS") != "1",
    reason="set RUN_MODEL_TESTS=1 to run the heavy KeyBERT/BGE-M3 test",
)
def test_extract_topics_drops_noise_keeps_real():
    from handler import extract_topics  # heavy import (torch/keybert)
    text = (
        "#493 Jeff Kaplan: World of Warcraft\n"
        "00:00 — Introduction\n"
        "03:12 — Early career at Blizzard\n"
        "1:23:45 — Future of gaming and esports\n"
        "26:30 — World of Warcraft design\n"
        "это было обсуждение про экономику\n"
    )
    topics = extract_topics(text, top_n=10)
    assert len(topics) <= 10
    from topic_clean import is_noise_topic
    assert not any(is_noise_topic(t) for t in topics), topics
    # leading timestamps must not produce numeric tags
    assert not any(t.strip() in {"00", "00 00", "03", "493", "2026"} for t in topics), topics
    blob = " ".join(topics).lower()
    assert "blizzard" in blob or "warcraft" in blob or "gaming" in blob, topics
