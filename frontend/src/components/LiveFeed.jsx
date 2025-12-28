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
