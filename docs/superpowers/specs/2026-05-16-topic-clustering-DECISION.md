# Topic clustering — gate decision

Reviewed: 2026-05-16
Reviewer: watchcat

distinct_topics (from experiment): K2=3881, K3=1756, K5=894 — all trivially
feasible for sklearn (≤3881² ≈ 120 MB distance matrix).

## Chosen parameters
- linkage: **complete**
- T (cosine distance threshold): **0.30**
- K (global min distinct-episode prefilter): **3**

## Chosen production mechanism
mechanism: **python-sklearn**

Rule applied: single-linkage chained catastrophically (largest cluster
191→694→1349→1619→1708 as T rises at K3), so the in-db-crystal
connected-components path is disqualified. Average/complete linkage is required
→ python-sklearn CronJob (Task 7B). **Task 7A is NOT executed.** Migration 019
(HNSW on topic_vectors) is 7A-only and is therefore **skipped** — the spec
already deferred it as "only if in-db-crystal wins".

## Rationale

At complete/T0.30/K3 BGE-M3 produces excellent cross-lingual + morphological
clusters and discriminates correctly:

- `war` = war · войны · война · oorlog (nl) · wars · войны на
- `economy` = economy · economic · экономика · economie (nl)
- `russia` = russia · россии · russian · по россии · из россии
- "iran war" ↔ "война иране" merge; but "война иране" stays **separate** from
  generic `war`, and `россияне` (the people) stays **separate** from `russia`
  (the country) — correct semantic discrimination.

Threshold sweep (complete, K3): T0.25 under-merges (drops valid variants);
T0.30 captures all valid variants without over-merging distinct concepts;
T0.35 starts loosening. T0.30 is the operating point. Complete linkage chosen
over average because average produces looser/larger blobs (largest real ~47 vs
~7 at complete) with higher risk of merging weakly-related topics.

## Plan amendment — date/number noise filter (NEW, not in original spec)

The topic corpus is heavily polluted with date/timestamp/number fragments
("03 2026", "26 2026", "05", "00 00", "2026 14", "20 03"). These are the
*largest* clusters in every configuration; with clustering summing counts they
would become the biggest tags in the cloud — worse than the fragmentation the
feature fixes. No linkage/threshold choice fixes this (upstream KeyBERT
extraction garbage).

Decision: **filter here + upstream.**
1. **In scope (Task 7B):** add a deterministic, TDD'd `is_noise_topic()` filter
   to the nightly clustering job's topic fetch/prefilter — drop purely
   numeric/date-like topics before embedding/clustering.
2. **Follow-up (out of this plan's scope, tracked separately):** fix KeyBERT
   extraction in `embed-worker` so it stops emitting date/number keywords at
   the source. Separate worker change + redeploy.
