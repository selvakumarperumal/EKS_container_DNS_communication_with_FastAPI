import uuid
from datetime import datetime, timezone
from typing import Optional

from sqlmodel import Field, SQLModel


# ---------------------------------------------------------------------------
# Item
# ---------------------------------------------------------------------------
class ItemBase(SQLModel):
    name: str = Field(max_length=255)
    description: Optional[str] = Field(default=None, max_length=1000)
    price: float = Field(ge=0)
    is_active: bool = True


class ItemCreate(ItemBase):
    pass


class ItemUpdate(SQLModel):
    name: Optional[str] = Field(default=None, max_length=255)
    description: Optional[str] = Field(default=None, max_length=1000)
    price: Optional[float] = Field(default=None, ge=0)
    is_active: Optional[bool] = None


class Item(ItemBase, table=True):
    __tablename__ = "items"
    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class ItemRead(ItemBase):
    id: uuid.UUID
    created_at: datetime
    updated_at: datetime


# ---------------------------------------------------------------------------
# FileRecord
# ---------------------------------------------------------------------------
class FileRecordBase(SQLModel):
    filename: str
    s3_key: str = Field(unique=True)
    content_type: Optional[str] = None
    size: int = 0


class FileRecord(FileRecordBase, table=True):
    __tablename__ = "file_records"
    id: uuid.UUID = Field(default_factory=uuid.uuid4, primary_key=True)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class FileRecordRead(FileRecordBase):
    id: uuid.UUID
    created_at: datetime
