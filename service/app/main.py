import os
import socket

from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def root():
    return {
        "app": os.getenv("APP_NAME", "demo-app"),
        "version": os.getenv("VERSION", "1.0.0"),
        "pod": socket.gethostname()
    }


@app.get("/healthz")
def health():
    return {"status": "healthy"}