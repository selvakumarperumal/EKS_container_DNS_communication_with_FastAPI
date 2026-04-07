import asyncio

import boto3

from config import settings

_client = boto3.client("s3", region_name=settings.aws_region)


async def upload(content: bytes, key: str, content_type: str) -> None:
    await asyncio.to_thread(
        _client.put_object,
        Bucket=settings.aws_s3_bucket,
        Key=key,
        Body=content,
        ContentType=content_type,
    )


async def delete(key: str) -> None:
    await asyncio.to_thread(
        _client.delete_object,
        Bucket=settings.aws_s3_bucket,
        Key=key,
    )


def presigned_url(key: str, expires_in: int = 3600) -> str:
    return _client.generate_presigned_url(
        "get_object",
        Params={"Bucket": settings.aws_s3_bucket, "Key": key},
        ExpiresIn=expires_in,
    )
