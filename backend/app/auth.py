from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel
from sqlmodel import Session, select
from app.db import get_session
from app.models import User
from passlib.context import CryptContext
import os
from datetime import datetime, timedelta
import jwt

router = APIRouter()
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
SECRET_KEY = os.getenv("SECRET_KEY", "change-me")
JWT_EXP_SECONDS = int(os.getenv("JWT_EXPIRATION_SECONDS", 3600))

class UserIn(BaseModel):
    username: str
    password: str

class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"

def get_password_hash(password):
    return pwd_context.hash(password)

def verify_password(plain, hashed):
    return pwd_context.verify(plain, hashed)

@router.post("/register")
def register(user: UserIn, session: Session = Depends(get_session)):
    stmt = select(User).where(User.username == user.username)
    existing = session.exec(stmt).first()
    if existing:
        raise HTTPException(status_code=400, detail="User exists")
    u = User(username=user.username, hashed_password=get_password_hash(user.password), role="admin")
    session.add(u)
    session.commit()
    session.refresh(u)
    return {"id": u.id, "username": u.username}

@router.post("/login", response_model=TokenOut)
def login(user: UserIn, session: Session = Depends(get_session)):
    stmt = select(User).where(User.username == user.username)
    u = session.exec(stmt).first()
    if not u or not verify_password(user.password, u.hashed_password):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    payload = {"sub": u.username, "exp": datetime.utcnow() + timedelta(seconds=JWT_EXP_SECONDS)}
    token = jwt.encode(payload, SECRET_KEY, algorithm="HS256")
    return {"access_token": token}
