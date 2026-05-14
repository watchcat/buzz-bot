# embed-sidecar/handler.py
import os
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

MODEL_NAME = os.environ.get("MODEL_NAME", "BAAI/bge-m3")

app = FastAPI()
model = None


def get_model():
    global model
    if model is None:
        model = SentenceTransformer(MODEL_NAME)
    return model


class EmbedRequest(BaseModel):
    text: str


class EmbedResponse(BaseModel):
    vector: list[float]


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest):
    m = get_model()
    vec = m.encode([req.text], normalize_embeddings=True)[0]
    return EmbedResponse(vector=vec.tolist())


@app.get("/health")
def health():
    return {"ok": True}
