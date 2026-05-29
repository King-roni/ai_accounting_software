"""Cyprus Bookkeeping SaaS — FastAPI backend.

Entry point: ``cyprus_bookkeeping_api.main:app`` for ASGI servers (uvicorn).
"""


def main() -> None:
    """uvicorn entry point exposed via the ``cyprus-bookkeeping-api`` console script."""
    import uvicorn

    uvicorn.run(
        "cyprus_bookkeeping_api.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
    )
