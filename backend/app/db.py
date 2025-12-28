import os
from sqlmodel import create_engine, Session
from sqlmodel import SQLModel
from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./visionx.db")
if DATABASE_URL.startswith("sqlite"):
    engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
else:
    engine = create_engine(DATABASE_URL)

def init_db():
    from app.models import User, Detection, Rule
    SQLModel.metadata.create_all(engine)

def get_session():
    return Session(engine)
