from cluster_job import is_noise_topic


def test_filters_pure_date_number_noise():
    for s in ["03", "05", "00 00", "20 03", "13 03", "2026", "2026 07",
              "26 2026", "03 2026", "  12  05 ", "2026 год", "2026 году",
              "04 26", "00 01", "2026 14"]:
        assert is_noise_topic(s), f"should be noise: {s!r}"


def test_keeps_real_topics():
    for s in ["war", "экономика", "ukraine", "oorlog", "covid 19",
              "9 мая", "g7", "iran war", "блокировки telegram"]:
        assert not is_noise_topic(s), f"should be kept: {s!r}"
