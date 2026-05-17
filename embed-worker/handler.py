# embed-worker/handler.py
import os
import runpod
import requests
from sentence_transformers import SentenceTransformer
from keybert import KeyBERT
from sklearn.feature_extraction.text import CountVectorizer
from topic_clean import clean_topic_input, is_noise_topic
from stopwords import STOPWORDS

_STOPWORDS_LIST = sorted(STOPWORDS)

MODEL_NAME = os.environ.get("MODEL_NAME", "BAAI/bge-m3")

model = None
kw_model = None

def get_model():
    global model
    if model is None:
        model = SentenceTransformer(MODEL_NAME)
    return model


def get_kw_model():
    global kw_model
    if kw_model is None:
        kw_model = KeyBERT(model=get_model())
    return kw_model


def embed_episode(episode: dict, title_prefix: str = "") -> list[float]:
    """Embed episode text in a single pass (BGE-M3 handles up to 8192 tokens)."""
    m = get_model()
    text = episode["text"]
    if title_prefix and not text.startswith(title_prefix):
        text = f"{title_prefix}\n\n{text}"

    vec = m.encode(text, normalize_embeddings=True)
    return vec.tolist()


def extract_topics(text: str, top_n: int = 10) -> list[str]:
    """Extract diverse keyphrases via KeyBERT + MMR, source-cleaned.

    Pipeline: strip timestamps/dates -> KeyBERT with a multilingual-stopword
    CountVectorizer (over-fetch) -> drop entirely-numeric/date keyphrases ->
    de-dupe (case-insensitive) -> first `top_n`.
    """
    cleaned = clean_topic_input(text)
    if not cleaned:
        return []
    km = get_kw_model()
    # Custom vectorizer: ngram_range MUST be set here (KeyBERT ignores
    # keyphrase_ngram_range when a vectorizer is passed). No custom
    # token_pattern — keep sklearn default so 'covid 19'/'gpt 4' n-grams form;
    # entirely-numeric phrases are rejected at the keyphrase level below.
    vectorizer = CountVectorizer(ngram_range=(1, 2), stop_words=_STOPWORDS_LIST)
    try:
        keywords = km.extract_keywords(
            cleaned,
            vectorizer=vectorizer,
            top_n=15,            # over-fetch; trimmed to top_n after filtering
            use_mmr=True,
            diversity=0.3,
        )
    except ValueError:
        # Empty vocabulary (cleaned text was all stop-words/numbers). Return
        # no topics rather than letting it propagate — handler() runs
        # embed_episode() BEFORE this, so an uncaught raise would discard the
        # already-computed (primary) embedding for this episode too.
        return []
    out: list[str] = []
    seen: set[str] = set()
    for kw, _score in keywords:
        if is_noise_topic(kw):
            continue
        key = kw.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(kw)
        if len(out) >= top_n:
            break
    return out


def handler(job):
    input_data = job["input"]
    episodes = input_data["episodes"]
    callback_url = input_data["callback_url"]
    secret = input_data.get("secret")
    source = input_data.get("source", "description")

    results = []
    for ep in episodes:
        try:
            vector = embed_episode(ep)
            topics = extract_topics(ep["text"])
            results.append({"id": ep["id"], "vector": vector, "topics": topics})
        except Exception as e:
            print(f"Failed to embed episode {ep.get('id')}: {e}")
            continue

    # Post results back to buzz-bot
    headers = {"Content-Type": "application/json"}
    if secret:
        headers["Authorization"] = f"Bearer {secret}"

    payload = {"embeddings": results, "source": source}

    try:
        resp = requests.post(callback_url, json=payload, headers=headers, timeout=30)
        resp.raise_for_status()
    except Exception as e:
        print(f"Callback failed: {e}")
        return {"error": f"Callback failed: {str(e)}"}

    return {"stored": len(results)}


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
