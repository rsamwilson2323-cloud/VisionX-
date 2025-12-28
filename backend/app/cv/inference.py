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
