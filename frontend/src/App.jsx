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
