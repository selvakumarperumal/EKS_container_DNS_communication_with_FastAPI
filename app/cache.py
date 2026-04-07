import json
import logging

import redis.asyncio as redis

from config import settings

logger = logging.getLogger(__name__)

_pool: redis.Redis | None = None

DEFAULT_TTL = 300  # 5 minutes


async def get_client() -> redis.Redis:
    global _pool
    if _pool is None:
        _pool = redis.from_url(settings.redis_url, decode_responses=True)
    return _pool


async def close():
    global _pool
    if _pool is not None:
        await _pool.aclose()
        _pool = None


async def get(key: str) -> dict | list | None:
    try:
        client = await get_client()
        data = await client.get(key)
        if data is not None:
            return json.loads(data)
    except Exception:
        logger.warning("Redis GET failed for key=%s", key, exc_info=True)
    return None


async def set(key: str, value, ttl: int = DEFAULT_TTL):
    try:
        client = await get_client()
        await client.set(key, json.dumps(value, default=str), ex=ttl)
    except Exception:
        logger.warning("Redis SET failed for key=%s", key, exc_info=True)


async def delete(key: str):
    try:
        client = await get_client()
        await client.delete(key)
    except Exception:
        logger.warning("Redis DELETE failed for key=%s", key, exc_info=True)


async def invalidate_pattern(pattern: str):
    try:
        client = await get_client()
        keys = []
        async for key in client.scan_iter(match=pattern):
            keys.append(key)
        if keys:
            await client.delete(*keys)
    except Exception:
        logger.warning("Redis invalidate failed for pattern=%s", pattern, exc_info=True)
