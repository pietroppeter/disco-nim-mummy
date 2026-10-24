// Live sync: the server pushes the count to every open tab over a WebSocket.
// Without a connection the form still works as a plain POST.
const n = document.getElementById("n"), s = document.getElementById("s");
let ws, timer, delay = 500;
function connect() {
  ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
  ws.onopen = () => { delay = 500; s.textContent = "live"; s.className = "s on"; };
  ws.onmessage = (e) => { n.textContent = e.data; };
  ws.onclose = () => {
    s.textContent = "reconnecting"; s.className = "s";
    timer = setTimeout(connect, delay); delay = Math.min(delay * 2, 10000);
  };
}
document.getElementById("f").onsubmit = (e) => {
  if (ws && ws.readyState === WebSocket.OPEN) { e.preventDefault(); ws.send("inc"); }
};
// Phones drop sockets in the background: reconnect as soon as the tab is visible.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && ws.readyState === WebSocket.CLOSED) { clearTimeout(timer); delay = 500; connect(); }
});
connect();
