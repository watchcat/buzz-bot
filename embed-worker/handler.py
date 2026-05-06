# embed-worker/handler.py
import os
import runpod
import requests
import numpy as np
from sentence_transformers import SentenceTransformer
from keybert import KeyBERT

MODEL_NAME = os.environ.get("MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
MAX_TOKENS = 512
OVERLAP_TOKENS = 50

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


def chunk_text(text: str, max_tokens: int = MAX_TOKENS, overlap: int = OVERLAP_TOKENS) -> list[str]:
    """Split text into overlapping chunks by whitespace-approximated tokens."""
    words = text.split()
    if len(words) <= max_tokens:
        return [text]
    chunks = []
    start = 0
    while start < len(words):
        end = start + max_tokens
        chunk = " ".join(words[start:end])
        chunks.append(chunk)
        start = end - overlap
    return chunks


def embed_episode(episode: dict, title_prefix: str = "") -> list[float]:
    """Embed a single episode text, chunking and mean-pooling if needed."""
    m = get_model()
    text = episode["text"]
    if title_prefix and not text.startswith(title_prefix):
        text = f"{title_prefix}\n\n{text}"

    chunks = chunk_text(text)
    embeddings = m.encode(chunks, normalize_embeddings=True)

    if len(embeddings) == 1:
        return embeddings[0].tolist()

    # Mean-pool all chunk embeddings
    mean_vec = np.mean(embeddings, axis=0)
    # L2-normalize the mean vector
    norm = np.linalg.norm(mean_vec)
    if norm > 0:
        mean_vec = mean_vec / norm
    return mean_vec.tolist()


def extract_topics(text: str, top_n: int = 10) -> list[str]:
    """Extract diverse keyphrases from text using KeyBERT + MMR."""
    if not text or not text.strip():
        return []
    km = get_kw_model()
    keywords = km.extract_keywords(
        text,
        keyphrase_ngram_range=(1, 2),
        top_n=top_n,
        use_mmr=True,
        diversity=0.3,
    )
    return [kw for kw, _score in keywords]


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


runpod.serverless.start({"handler": handler})
