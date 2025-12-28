from sqlmodel import SQLModel, Field, JSON
from typing import Optional
from datetime import datetime

class User(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    username: str = Field(index=True, unique=True)
    hashed_password: str
    role: str = "viewer"

class Detection(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    timestamp: datetime
    metadata: dict = Field(sa_column_kwargs={"type_": "JSON"})

class Rule(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    name: str
    condition: dict = Field(sa_column_kwargs={"type_": "JSON"})
    action: dict = Field(sa_column_kwargs={"type_": "JSON"})
    enabled: bool = True
