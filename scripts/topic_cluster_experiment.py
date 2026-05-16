"""Offline experiment: cluster BGE-M3 topic-string embeddings across a grid.

Run via scripts/topic-cluster-experiment.sh (sets DATABASE_URL, venv).
Phase 1 of docs/superpowers/specs/2026-05-16-topic-clustering-design.md.
NO production code: read-only against the DB, writes only to experiment-output/.
"""
from __future__ import annotations


def pick_label(members: list[str], counts: dict[str, int]) -> str:
    """Canonical label = member with max global episode count.

    Deterministic tie-break: highest count, then shortest string, then
    lexicographic (case-sensitive: Python codepoint order, so uppercase
    sorts before lowercase — 'AI' < 'ai'). Keeps labels stable across
    nightly runs.

    Precondition: `members` must be non-empty (min() raises ValueError on []).
    Callers cluster real members, so this always holds in practice.
    """
    return min(members, key=lambda m: (-counts.get(m, 0), len(m), m))


def groups_from_labels(topics: list[str], labels: list[int]) -> dict[int, list[str]]:
    """Bucket topic strings by their assigned cluster id (sklearn .labels_)."""
    out: dict[int, list[str]] = {}
    for topic, cid in zip(topics, labels):
        out.setdefault(int(cid), []).append(topic)
    return out


import os
import sys
import itertools
import pathlib

import numpy as np
import psycopg2
from sentence_transformers import SentenceTransformer
from sklearn.cluster import AgglomerativeClustering

OUT_DIR = pathlib.Path(__file__).parent / "experiment-output"
LINKAGES = ["single", "average", "complete"]
THRESHOLDS = [0.20, 0.25, 0.30, 0.35, 0.40]  # cosine distance
PREFILTERS = [2, 3, 5]                        # min distinct episodes (K)


def fetch_topics(dsn: str) -> dict[str, int]:
    """topic string -> global distinct-episode count, across ALL episodes."""
    sql = (
        "SELECT t, COUNT(DISTINCT episode_id)::int "
        "FROM episode_embeddings, unnest(topics) AS t "
        "GROUP BY t"
    )
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        cur.execute(sql)
        return {row[0]: row[1] for row in cur.fetchall()}


def cluster(vectors: np.ndarray, linkage: str, threshold: float) -> list[int]:
    model = AgglomerativeClustering(
        n_clusters=None,
        metric="cosine",
        linkage=linkage,
        distance_threshold=threshold,
    )
    return model.fit_predict(vectors).tolist()


def write_report(path: pathlib.Path, topics: list[str], counts: dict[str, int],
                 labels: list[int]) -> None:
    groups = groups_from_labels(topics, labels)
    multi = {c: m for c, m in groups.items() if len(m) > 1}
    singletons = len(groups) - len(multi)
    total = len(topics)
    in_multi = sum(len(m) for m in multi.values())
    lines = [
        f"distinct_topics={total}  clusters={len(groups)}  "
        f"multi_member={len(multi)}  singletons={singletons}  "
        f"pct_in_multi={100*in_multi/total:.1f}%",
        f"largest_cluster={max((len(m) for m in groups.values()), default=0)}",
        "",
    ]
    for cid, members in sorted(multi.items(), key=lambda kv: -len(kv[1])):
        label = pick_label(members, counts)
        lines.append(f"[{len(members)}] LABEL={label!r}")
        for m in sorted(members, key=lambda x: -counts.get(x, 0)):
            lines.append(f"    {counts.get(m,0):>5}  {m}")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    dsn = os.environ["DATABASE_URL"]
    OUT_DIR.mkdir(exist_ok=True)
    counts = fetch_topics(dsn)
    print(f"fetched {len(counts)} distinct topics", file=sys.stderr)

    model = SentenceTransformer("BAAI/bge-m3")
    for k in PREFILTERS:
        topics = sorted([t for t, c in counts.items() if c >= k])
        if len(topics) < 3:
            print(f"K={k}: only {len(topics)} topics, skipping", file=sys.stderr)
            continue
        vecs = np.asarray(model.encode(topics, normalize_embeddings=True))
        for linkage, thr in itertools.product(LINKAGES, THRESHOLDS):
            labels = cluster(vecs, linkage, thr)
            fn = OUT_DIR / f"{linkage}_T{thr:.2f}_K{k}.txt"
            write_report(fn, topics, counts, labels)
            print(f"wrote {fn.name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
