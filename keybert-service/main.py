from keybert import KeyBERT
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()
model = KeyBERT('all-MiniLM-L6-v2')  # loaded once at startup


class ExtractRequest(BaseModel):
    text: str
    top_n: int = 10
    max_ngram: int = 3


@app.post("/extract")
def extract(req: ExtractRequest):
    keywords = model.extract_keywords(
        req.text, keyphrase_ngram_range=(1, req.max_ngram),
        stop_words='english', top_n=req.top_n
    )
    return [{"phrase": kw, "score": score} for kw, score in keywords]
