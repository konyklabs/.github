"""Idempotency key store."""

import time

WINDOW_SECONDS = 24 * 60 * 60

_seen = {}


def remember(key: str, response: dict) -> None:
    _seen[key] = (time.time(), response)


def replay(key: str):
    entry = _seen.get(key)
    if not entry:
        return None
    stored_at, response = entry
    if time.time() - stored_at > WINDOW_SECONDS:
        del _seen[key]
        return None
    return response
