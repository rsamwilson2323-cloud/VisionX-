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
