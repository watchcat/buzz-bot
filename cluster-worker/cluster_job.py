"""Nightly global topic clustering (sklearn). mechanism = python-sklearn.
Reads DATABASE_URL and embeds via the in-cluster BGE-M3 sidecar.
Gate decision: complete linkage, cosine-distance 0.30, K=3.
"""
import os
import re
import numpy as np
import psycopg2
import requests
from sklearn.cluster import AgglomerativeClustering

LINKAGE = os.environ.get("CLUSTER_LINKAGE", "complete")
THRESHOLD = float(os.environ.get("TOPIC_CLUSTER_DISTANCE", "0.30"))
K = int(os.environ.get("TOPIC_CLUSTER_MIN_COUNT", "3"))
SIDECAR = os.environ.get("EMBED_SIDECAR_URL", "http://embed-sidecar:8000")

# Gate amendment: drop date/number/timestamp fragments KeyBERT extracts from
# episode dates & timestamped show-notes. Without this they form the largest
# clusters and would dominate the tag cloud. Deterministic; unit-tested.
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


def pick_label(members, counts):
    return min(members, key=lambda m: (-counts.get(m, 0), len(m), m))


def normalize_dsn(url):
    # buzz-bot's DATABASE_URL carries non-standard params (auth_methods, options)
    # that libpq/psycopg2 reject. psycopg2 sends SNI, so ?sslmode=require is
    # sufficient for Neon. Same strip embed-progress.sh applies for psql.
    return re.sub(r"\?.*$", "?sslmode=require", url)


def main():
    dsn = normalize_dsn(os.environ["DATABASE_URL"])
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()
    cur.execute(
        "SELECT t, COUNT(DISTINCT episode_id)::int "
        "FROM episode_embeddings, unnest(topics) AS t "
        "GROUP BY t HAVING COUNT(DISTINCT episode_id) >= %s", (K,))
    counts = {r[0]: r[1] for r in cur.fetchall()}
    # Gate amendment: strip date/number noise before embed/cluster/label.
    counts = {t: c for t, c in counts.items() if not is_noise_topic(t)}
    topics = sorted(counts)
    if len(topics) < 3:
        print(f"only {len(topics)} topics >= K={K}, nothing to do")
        return

    # Embed via sidecar; cache into topic_vectors.
    cur.execute("SELECT topic FROM topic_vectors")
    cached = {r[0] for r in cur.fetchall()}
    for t in topics:
        if t in cached:
            continue
        v = requests.post(f"{SIDECAR}/embed", json={"text": t}, timeout=60)
        v.raise_for_status()
        vec = v.json()["vector"]
        cur.execute(
            "INSERT INTO topic_vectors (topic, embedding, updated_at) "
            "VALUES (%s, %s::vector, now()) "
            "ON CONFLICT (topic) DO UPDATE SET embedding = EXCLUDED.embedding, "
            "updated_at = now()",
            (t, "[" + ",".join(map(str, vec)) + "]"))
    conn.commit()

    # Load all vectors for qualifying topics, in topic order.
    cur.execute(
        "SELECT topic, embedding FROM topic_vectors WHERE topic = ANY(%s) "
        "ORDER BY topic", (topics,))
    rows = cur.fetchall()
    ordered = [r[0] for r in rows]
    vecs = np.asarray(
        [[float(x) for x in r[1].strip("[]").split(",")] for r in rows])

    labels = AgglomerativeClustering(
        n_clusters=None, metric="cosine", linkage=LINKAGE,
        distance_threshold=THRESHOLD).fit_predict(vecs)

    groups = {}
    for topic, cid in zip(ordered, labels):
        groups.setdefault(int(cid), []).append(topic)

    # psycopg2 autocommit is off: TRUNCATE + all INSERTs commit as one atomic
    # transaction, so the tag cloud never sees a half-rebuilt clustering.
    cur.execute("TRUNCATE topic_clusters")
    for cid, members in groups.items():
        lbl = pick_label(members, counts)
        for t in members:
            cur.execute(
                "INSERT INTO topic_clusters (topic, cluster_id, label, updated_at) "
                "VALUES (%s, %s, %s, now())", (t, cid, lbl))
    conn.commit()
    print(f"clustered {len(ordered)} topics into {len(groups)} clusters")


if __name__ == "__main__":
    main()
