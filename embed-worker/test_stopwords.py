from stopwords import STOPWORDS


def test_is_frozenset_of_lowercase_str():
    assert isinstance(STOPWORDS, frozenset)
    assert STOPWORDS
    assert all(isinstance(w, str) and w == w.lower() for w in STOPWORDS)


def test_contains_representative_function_words():
    # English, Russian, Dutch function words must be present
    for w in ["the", "and", "is", "это", "было", "не",
              "de", "het", "een", "moet", "ik"]:
        assert w in STOPWORDS, f"missing stopword: {w!r}"


def test_excludes_real_topic_words():
    # Words that are legitimate standalone topics must NOT be stopped
    for w in ["war", "экономика", "oorlog", "ukraine", "covid",
              "украина", "rusland", "история"]:
        assert w not in STOPWORDS, f"topic word wrongly in STOPWORDS: {w!r}"
