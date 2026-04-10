FROM python:3.11-slim
WORKDIR /app
COPY keybert-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Pre-download the model so it's baked into the image (no network needed at runtime)
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"
COPY keybert-service/main.py .
EXPOSE 8001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
