#!/usr/bin/env bash
set -e

# Run from the root of your local repo (VisionX-)
# This script will write the scaffold files into the current directory.

echo "Creating directories..."
mkdir -p backend/app/cv backend/app/scripts frontend/src/components frontend/src

echo "Writing .gitignore..."
cat > .gitignore <<'EOF'
# .gitignore
# Python
__pycache__/
*.pyc
*.pyo
*.pyd
venv/
env/
.env

# Node
node_modules/
dist/
build/

# Docker
*.log
*.sqlite3

# VSCode
.vscode/

# Mac
.DS_Store
EOF

echo "Writing .env.example..."
cat > .env.example <<'EOF'
# .env.example
# Copy to .env and edit
SECRET_KEY=change-me-to-a-secure-random-string
DATABASE_URL=sqlite:///./visionx.db
JWT_EXPIRATION_SECONDS=3600
REDIS_URL=redis://redis:6379/0
BACKEND_HOST=0.0.0.0
BACKEND_PORT=8000
FRONTEND_PORT=3000
EOF

echo "Writing docker-compose.yml..."
cat > docker-compose.yml <<'EOF'
version: "3.8"
services:
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    ports:
      - "6379:6379"

  backend:
    build:
      context: ./backend
    env_file:
      - ./.env
    volumes:
      - ./backend/app:/app/app
    ports:
      - "8000:8000"
    depends_on:
      - redis

  worker:
    build:
      context: ./backend
    command: ["python", "worker.py"]
    env_file:
      - ./.env
    volumes:
      - ./backend/app:/app/app
    depends_on:
      - redis
      - backend

  frontend:
    build:
      context: ./frontend
    env_file:
      - ./.env
    ports:
      - "3000:3000"
    volumes:
      - ./frontend:/usr/src/app
    depends_on:
      - backend
EOF

echo "Writing backend/Dockerfile..."
cat > backend/Dockerfile <<'EOF'
FROM python:3.11-slim

WORKDIR /app

# system deps for opencv
RUN apt-get update && apt-get install -y \
    build-essential \
    libgl1-mesa-glx \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
EOF

echo "Writing backend/requirements.txt..."
cat > backend/requirements.txt <<'EOF'
fastapi==0.95.2
uvicorn[standard]==0.22.0
sqlmodel==0.0.8
passlib[bcrypt]==1.7.4
pyjwt==2.8.0
python-multipart==0.0.6
opencv-python-headless==4.7.0.72
numpy==1.26.4
pillow==10.1.0
redis==5.0.4
rq==1.13.1
aiofiles==23.1.0
python-dotenv==1.0.1
EOF

echo "Writing backend/app/main.py..."
cat > backend/app/main.py <<'EOF'
import os
import base64
import json
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi import APIRouter
from sqlmodel import Session, select
from datetime import datetime
from app.db import engine, init_db, get_session
from app.models import User, Detection, Rule
from app.auth import router as auth_router, get_current_user_optional
from app.cv.inference import detect_faces_from_bytes
from app.worker import enqueue_process_detection
from typing import List

app = FastAPI(title="VisionX Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router, prefix="/api/auth", tags=["auth"])

@app.on_event("startup")
def on_startup():
    init_db()
    # create example admin and sample rule if not present
    from app.scripts.init_db import create_example_data
    create_example_data()

# simple models status endpoint
@app.get("/api/models/status")
def models_status():
    return {"status": "ready", "models": ["haar_face"], "server_time": datetime.utcnow().isoformat()}

# simple logs endpoint
@app.get("/api/logs")
def get_logs(limit: int = 50, session: Session = Depends(get_session)):
    stmt = select(Detection).order_by(Detection.timestamp.desc()).limit(limit)
    items = session.exec(stmt).all()
    return items

# WebSocket manager
class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)

    async def broadcast(self, message: dict):
        rem = []
        for connection in list(self.active_connections):
            try:
                await connection.send_json(message)
            except Exception:
                rem.append(connection)
        for r in rem:
            self.disconnect(r)

manager = ConnectionManager()

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            data = await websocket.receive_text()
            try:
                d = json.loads(data)
            except Exception:
                await websocket.send_json({"error": "invalid json"})
                continue

            # handle frame messages
            if d.get("type") == "frame" and d.get("data"):
                b64 = d["data"].split(",")[-1]
                img_bytes = base64.b64decode(b64)
                detections = detect_faces_from_bytes(img_bytes)
                # store detection
                with Session(engine) as session:
                    det = Detection(timestamp=datetime.utcnow(), metadata=detections)
                    session.add(det)
                    session.commit()
                    session.refresh(det)
                    # enqueue rule processing (background)
                    enqueue_process_detection(det.id)
                # broadcast to all clients
                await manager.broadcast({
                    "type": "detection_event",
                    "detection_id": det.id,
                    "timestamp": det.timestamp.isoformat(),
                    "detections": detections
                })
            else:
                # echo
                await websocket.send_json({"echo": d})
    except WebSocketDisconnect:
        manager.disconnect(websocket)
    except Exception as exc:
        try:
            await websocket.close()
        except:
            pass
        manager.disconnect(websocket)

# small API to get rules
@app.get("/api/rules")
def list_rules(session: Session = Depends(get_session)):
    stmt = select(Rule)
    return session.exec(stmt).all()
EOF

echo "Writing backend/app/db.py..."
cat > backend/app/db.py <<'EOF'
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
EOF

echo "Writing backend/app/models.py..."
cat > backend/app/models.py <<'EOF'
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
EOF

echo "Writing backend/app/auth.py..."
cat > backend/app/auth.py <<'EOF'
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
EOF

echo "Writing backend/app/cv/inference.py..."
cat > backend/app/cv/inference.py <<'EOF'
import cv2
import numpy as np
import tempfile
import os
from typing import List, Dict
from io import BytesIO

# Try to load OpenCV's haarcascade — fallback: rely on cv2.data.haarcascades
CASCADE_PATH = os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml")

if not os.path.exists(CASCADE_PATH):
    raise RuntimeError("Could not find Haar cascade at %s. Ensure OpenCV installed correctly." % CASCADE_PATH)

face_cascade = cv2.CascadeClassifier(CASCADE_PATH)

def detect_faces_from_bytes(img_bytes: bytes) -> List[Dict]:
    # read image bytes to numpy array
    nparr = np.frombuffer(img_bytes, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
    if img is None:
        return []
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    faces = face_cascade.detectMultiScale(gray, 1.1, 5)
    results = []
    for (x, y, w, h) in faces:
        results.append({"label": "face", "bbox": [int(x), int(y), int(w), int(h)], "score": 0.9})
    return results
EOF

echo "Writing backend/app/worker.py..."
cat > backend/app/worker.py <<'EOF'
"""
worker.py

Run this as the worker container entrypoint.
It will register RQ workers and also exposes task functions for enqueueing.
"""
import os
from redis import Redis
from rq import Queue, Worker, Connection
from app.db import engine, get_session
from app.models import Rule, Detection
import time
import json

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

redis_conn = Redis.from_url(REDIS_URL)
q = Queue(connection=redis_conn)

def process_detection_task(detection_id: int):
    # simple rule processing: load detection and check rules
    from sqlmodel import Session, select
    from app.models import Rule, Detection
    with Session(engine) as session:
        det = session.get(Detection, detection_id)
        if not det:
            print("Detection not found:", detection_id)
            return
        # naive rule check: if any rule enabled with condition {"label":"face","min_count":n}
        stmt = select(Rule).where(Rule.enabled == True)
        rules = session.exec(stmt).all()
        for r in rules:
            cond = r.condition or {}
            if cond.get("label") and cond.get("min_count"):
                label = cond["label"]
                min_count = int(cond["min_count"])
                count = sum(1 for item in det.metadata if item.get("label") == label)
                if count >= min_count:
                    # perform action (naive: print or call webhook)
                    action = r.action or {}
                    print(f"[RULE TRIGGER] Rule '{r.name}' triggered by detection {detection_id}. Action: {action}")
                    # you can add HTTP webhook or email sending here
    return True

def enqueue_process_detection(detection_id: int):
    q.enqueue("app.worker.process_detection_task", detection_id)

if __name__ == "__main__":
    # start an RQ worker listening to default queue
    with Connection(redis_conn):
        worker = Worker(list(q.queue_name for q in [q]), connection=redis_conn)
        worker.work()
EOF

echo "Writing backend/app/scripts/init_db.py..."
cat > backend/app/scripts/init_db.py <<'EOF'
from app.db import get_session, init_db
from app.models import User, Rule
from app.auth import get_password_hash
from sqlmodel import select

def create_example_data():
    init_db()
    session = get_session()
    try:
        stmt = select(User)
        u = session.exec(stmt).first()
        if not u:
            admin = User(username="admin", hashed_password=get_password_hash("admin"), role="admin")
            session.add(admin)
            session.commit()
        # add a sample rule: if >=1 face detected, print action
        stmt = select(Rule)
        r = session.exec(stmt).first()
        if not r:
            rule = Rule(name="FaceAlert", condition={"label": "face", "min_count": 1}, action={"type": "log", "message": "Face detected!"}, enabled=True)
            session.add(rule)
            session.commit()
    finally:
        session.close()
EOF

echo "Writing backend/worker.py (wrapper)..."
cat > backend/worker.py <<'EOF'
# small wrapper to start RQ worker using app.worker module
from app.worker import redis_conn
from rq import Worker, Queue, Connection

q = Queue(connection=redis_conn)

if __name__ == "__main__":
    with Connection(redis_conn):
        w = Worker([q], connection=redis_conn)
        w.work()
EOF

echo "Writing frontend/Dockerfile..."
cat > frontend/Dockerfile <<'EOF'
FROM node:20-alpine

WORKDIR /usr/src/app

COPY package.json package-lock.json* ./

RUN npm install

COPY . .

EXPOSE 3000

CMD ["npm", "run", "dev"]
EOF

echo "Writing frontend/package.json..."
cat > frontend/package.json <<'EOF'
{
  "name": "visionx-frontend",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "chart.js": "^4.4.0"
  },
  "devDependencies": {
    "vite": "^5.0.0",
    "@vitejs/plugin-react": "^4.0.0"
  }
}
EOF

echo "Writing frontend/vite.config.js..."
cat > frontend/vite.config.js <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: Number(process.env.FRONTEND_PORT || 3000),
    strictPort: true
  }
})
EOF

echo "Writing frontend/index.html..."
cat > frontend/index.html <<'EOF'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>VisionX</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

echo "Writing frontend/src/main.jsx..."
cat > frontend/src/main.jsx <<'EOF'
import React from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

createRoot(document.getElementById("root")).render(<App />);
EOF

echo "Writing frontend/src/App.jsx..."
cat > frontend/src/App.jsx <<'EOF'
import React, { useState } from "react";
import LiveFeed from "./components/LiveFeed";

export default function App() {
  const [token, setToken] = useState("");
  const [username, setUsername] = useState("admin");
  const [password, setPassword] = useState("admin");

  async function login(e) {
    e.preventDefault();
    try {
      const res = await fetch(`${import.meta.env.VITE_BACKEND_URL || 'http://localhost:8000'}/api/auth/login`, {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({username, password})
      });
      const data = await res.json();
      if (data.access_token) {
        setToken(data.access_token);
      } else {
        alert("Login failed");
      }
    } catch (err) {
      console.error(err);
      alert("Login error");
    }
  }

  return (
    <div className="app">
      <header>
        <h1>VisionX — Demo</h1>
      </header>

      {!token ? (
        <div className="login">
          <form onSubmit={login}>
            <input value={username} onChange={(e) => setUsername(e.target.value)} placeholder="username" />
            <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="password" />
            <button type="submit">Login</button>
          </form>
          <p>Default admin/admin created on first startup.</p>
        </div>
      ) : (
        <div>
          <LiveFeed token={token} />
        </div>
      )}
    </div>
  );
}
EOF

echo "Writing frontend/src/components/LiveFeed.jsx..."
cat > frontend/src/components/LiveFeed.jsx <<'EOF'
import React, { useEffect, useRef, useState } from "react";

export default function LiveFeed({ token }) {
  const videoRef = useRef(null);
  const canvasRef = useRef(null);
  const wsRef = useRef(null);
  const [events, setEvents] = useState([]);

  useEffect(() => {
    async function startCamera() {
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
        videoRef.current.srcObject = stream;
        videoRef.current.play();
      } catch (err) {
        console.error("Camera error:", err);
        alert("Camera access required for demo");
      }
    }
    startCamera();
  }, []);

  useEffect(() => {
    const backend = (import.meta.env.VITE_BACKEND_URL || "http://localhost:8000");
    const wsUrl = backend.replace(/^http/, "ws") + "/ws";
    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;
    ws.onopen = () => console.log("ws open");
    ws.onmessage = (ev) => {
      try {
        const d = JSON.parse(ev.data);
        if (d.type === "detection_event") {
          setEvents((s) => [d, ...s].slice(0, 50));
        }
      } catch (e) {
        // ignore
      }
    };
    ws.onclose = () => console.log("ws closed");
    return () => {
      ws.close();
    };
  }, []);

  useEffect(() => {
    const interval = setInterval(() => {
      captureAndSend();
    }, 800);
    return () => clearInterval(interval);
  }, []);

  function captureAndSend() {
    const video = videoRef.current;
    const canvas = canvasRef.current;
    if (!video || !canvas) return;
    const ctx = canvas.getContext("2d");
    canvas.width = video.videoWidth || 320;
    canvas.height = video.videoHeight || 240;
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    const dataUrl = canvas.toDataURL("image/jpeg", 0.6);
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ type: "frame", data: dataUrl }));
    }
  }

  return (
    <div className="live-feed">
      <div className="video-panel">
        <video ref={videoRef} style={{ width: "640px", height: "480px", border: "1px solid #333" }} />
        <canvas ref={canvasRef} style={{ display: "none" }} />
      </div>
      <div className="events">
        <h3>Recent Detections</h3>
        <ul>
          {events.map((e) => (
            <li key={e.detection_id}>
              {new Date(e.timestamp).toLocaleTimeString()} — {e.detections.length} detections
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
EOF

echo "Writing frontend/src/styles.css..."
cat > frontend/src/styles.css <<'EOF'
body { font-family: system-ui, sans-serif; margin: 0; padding: 20px; background: #f7f9fc; color: #0f172a; }
.app header { margin-bottom: 20px; }
.login { max-width: 360px; }
.login input { display:block; width:100%; padding:8px; margin:6px 0; }
button { padding:8px 12px; }
.live-feed { display:flex; gap:20px; align-items:flex-start; }
.events { max-width:320px; background:white; padding:12px; border-radius:6px; box-shadow: 0 2px 6px rgba(0,0,0,0.08); }
EOF

echo "All files created."