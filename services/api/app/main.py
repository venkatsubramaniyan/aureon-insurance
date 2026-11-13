
from fastapi import FastAPI

app = FastAPI(title="Aureon Insurance API")


@app.get("/health")
def health_check():
    return {"status": "healthy"}
