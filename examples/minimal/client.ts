// Quick WS client for smoke-testing dis-engine. Connects to
// ws://localhost:7070/ws/<ns>/<actor>/<key>, sends one message, prints
// replies for a short window.

const url =
  process.env["DIS_CLIENT_URL"] ??
  "ws://localhost:7070/ws/my-app/echo/smoke/user-1";

const ws = new WebSocket(url);

ws.addEventListener("open", () => {
  console.log("[client] open");
  ws.send("hello from client");
});

ws.addEventListener("message", (ev) => {
  const data = typeof ev.data === "string" ? ev.data : "<binary>";
  console.log("[client] <<", data);
});

ws.addEventListener("close", (ev) => {
  console.log(`[client] close code=${ev.code} reason=${ev.reason}`);
  process.exit(0);
});

ws.addEventListener("error", (ev) => {
  console.error("[client] error", ev);
});

setTimeout(() => {
  console.log("[client] done, closing");
  ws.close(1000, "done");
}, 2000);
