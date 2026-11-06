
import os
import socket
from pathlib import Path

from fastapi import FastAPI

app = FastAPI()

CONFIG_DIR = Path("/etc/demo-config")


def get_config(key, default):
    config_file = CONFIG_DIR / key

    if config_file.exists():
        return config_file.read_text().strip()

    return os.getenv(key, default)


@app.get("/")
def root():
    return {
        "app": get_config("APP_NAME", "demo-app"),
        "version": get_config("VERSION", "1.0.0"),
        "pod": socket.gethostname()
    }


@app.get("/healthz")
def health():
    return {"status": "healthy"}
