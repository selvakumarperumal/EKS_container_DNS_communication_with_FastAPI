import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, HTTPException, Query, UploadFile
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

import cache
import s3
from config import settings
from database import get_session, init_db
from models import (
    FileRecord,
    FileRecordRead,
    Item,
    ItemCreate,
    ItemRead,
    ItemUpdate,
)

# ---------------------------------------------------------------------------
# OpenTelemetry setup
# ---------------------------------------------------------------------------
resource = Resource.create({"service.name": settings.otel_service_name})
provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint=settings.otel_exporter_otlp_endpoint, insecure=True)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    await init_db()
    yield
    await cache.close()


app = FastAPI(title="FastAPI EKS App", lifespan=lifespan)

# Prometheus /metrics endpoint
Instrumentator().instrument(app).expose(app)

# OpenTelemetry auto-instrumentation for FastAPI
FastAPIInstrumentor.instrument_app(app)


@app.get("/health")
async def health():
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Items CRUD (with Redis caching)
# ---------------------------------------------------------------------------
@app.post("/items", response_model=ItemRead)
async def create_item(data: ItemCreate, session: AsyncSession = Depends(get_session)):
    item = Item.model_validate(data)
    session.add(item)
    await session.commit()
    await session.refresh(item)
    await cache.invalidate_pattern("items:list:*")
    return item


@app.get("/items", response_model=list[ItemRead])
async def list_items(
    offset: int = Query(0, ge=0),
    limit: int = Query(20, ge=1, le=100),
    session: AsyncSession = Depends(get_session),
):
    cache_key = f"items:list:{offset}:{limit}"
    cached = await cache.get(cache_key)
    if cached is not None:
        return cached
    result = await session.exec(select(Item).offset(offset).limit(limit))
    items = [ItemRead.model_validate(i) for i in result.all()]
    await cache.set(cache_key, [i.model_dump() for i in items])
    return items


@app.get("/items/{item_id}", response_model=ItemRead)
async def get_item(item_id: uuid.UUID, session: AsyncSession = Depends(get_session)):
    cache_key = f"items:{item_id}"
    cached = await cache.get(cache_key)
    if cached is not None:
        return cached
    item = await session.get(Item, item_id)
    if not item:
        raise HTTPException(status_code=404, detail="Item not found")
    await cache.set(cache_key, ItemRead.model_validate(item).model_dump())
    return item


@app.patch("/items/{item_id}", response_model=ItemRead)
async def update_item(
    item_id: uuid.UUID,
    data: ItemUpdate,
    session: AsyncSession = Depends(get_session),
):
    item = await session.get(Item, item_id)
    if not item:
        raise HTTPException(status_code=404, detail="Item not found")
    for key, value in data.model_dump(exclude_unset=True).items():
        setattr(item, key, value)
    item.updated_at = datetime.now(timezone.utc)
    session.add(item)
    await session.commit()
    await session.refresh(item)
    await cache.delete(f"items:{item_id}")
    await cache.invalidate_pattern("items:list:*")
    return item


@app.delete("/items/{item_id}", status_code=204)
async def delete_item(item_id: uuid.UUID, session: AsyncSession = Depends(get_session)):
    item = await session.get(Item, item_id)
    if not item:
        raise HTTPException(status_code=404, detail="Item not found")
    await session.delete(item)
    await session.commit()
    await cache.delete(f"items:{item_id}")
    await cache.invalidate_pattern("items:list:*")


# ---------------------------------------------------------------------------
# Files (S3)
# ---------------------------------------------------------------------------
@app.post("/files", response_model=FileRecordRead)
async def upload_file(file: UploadFile, session: AsyncSession = Depends(get_session)):
    content = await file.read()
    key = f"uploads/{uuid.uuid4()}/{file.filename}"
    await s3.upload(content, key, file.content_type or "application/octet-stream")
    record = FileRecord(
        filename=file.filename,
        s3_key=key,
        content_type=file.content_type,
        size=len(content),
    )
    session.add(record)
    await session.commit()
    await session.refresh(record)
    return record


@app.get("/files", response_model=list[FileRecordRead])
async def list_files(
    offset: int = Query(0, ge=0),
    limit: int = Query(20, ge=1, le=100),
    session: AsyncSession = Depends(get_session),
):
    result = await session.exec(select(FileRecord).offset(offset).limit(limit))
    return result.all()


@app.get("/files/{file_id}")
async def get_file(file_id: uuid.UUID, session: AsyncSession = Depends(get_session)):
    record = await session.get(FileRecord, file_id)
    if not record:
        raise HTTPException(status_code=404, detail="File not found")
    return {
        **record.model_dump(),
        "download_url": s3.presigned_url(record.s3_key),
    }


@app.delete("/files/{file_id}", status_code=204)
async def delete_file(file_id: uuid.UUID, session: AsyncSession = Depends(get_session)):
    record = await session.get(FileRecord, file_id)
    if not record:
        raise HTTPException(status_code=404, detail="File not found")
    await s3.delete(record.s3_key)
    await session.delete(record)
    await session.commit()
