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
