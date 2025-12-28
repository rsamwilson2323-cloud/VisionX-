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
