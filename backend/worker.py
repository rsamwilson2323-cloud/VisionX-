# small wrapper to start RQ worker using app.worker module
from app.worker import redis_conn
from rq import Worker, Queue, Connection

q = Queue(connection=redis_conn)

if __name__ == "__main__":
    with Connection(redis_conn):
        w = Worker([q], connection=redis_conn)
        w.work()
