"""Offline experiment: cluster BGE-M3 topic-string embeddings across a grid.

Run via scripts/topic-cluster-experiment.sh (sets DATABASE_URL, venv).
Phase 1 of docs/superpowers/specs/2026-05-16-topic-clustering-design.md.
NO production code: read-only against the DB, writes only to experiment-output/.
"""
from __future__ import annotations


def pick_label(members: list[str], counts: dict[str, int]) -> str:
    """Canonical label = member with max global episode count.
    Deterministic tie-break: highest count, then shortest string, then
    lexicographic. Keeps labels stable across nightly runs.
    """
    return min(members, key=lambda m: (-counts.get(m, 0), len(m), m))


def groups_from_labels(topics: list[str], labels: list[int]) -> dict[int, list[str]]:
    """Bucket topic strings by their assigned cluster id (sklearn .labels_)."""
    out: dict[int, list[str]] = {}
    for topic, cid in zip(topics, labels):
        out.setdefault(int(cid), []).append(topic)
    return out
