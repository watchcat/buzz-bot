from topic_cluster_experiment import pick_label, groups_from_labels


def test_pick_label_prefers_highest_count():
    members = ["ml", "machine learning", "машинное обучение"]
    counts = {"ml": 5, "machine learning": 12, "машинное обучение": 7}
    assert pick_label(members, counts) == "machine learning"


def test_pick_label_tiebreak_shortest_then_lexicographic():
    members = ["bbb", "aa", "cc"]
    counts = {"bbb": 4, "aa": 4, "cc": 4}
    # all tie on count -> shortest (len 2) -> lexicographic among {"aa","cc"} -> "aa"
    assert pick_label(members, counts) == "aa"


def test_groups_from_labels_buckets_by_cluster_id():
    topics = ["a", "b", "c", "d"]
    labels = [0, 1, 0, 1]
    assert groups_from_labels(topics, labels) == {0: ["a", "c"], 1: ["b", "d"]}
