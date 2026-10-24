## Minimal counter for Disco: Mummy serves HTTP, SQLite stores the count.
## The database lives at $DB_PATH (default /data/counter.db), which Disco
## mounts as a persistent volume so the count survives redeploys.
## Browsers keep a WebSocket open on /ws and get the new count pushed to them
## whenever anyone increments, so every open tab stays in sync.

import std/[os, strutils, locks, sets]
import mummy, mummy/routers
import db_connector/db_sqlite

let dbPath = getEnv("DB_PATH", "/data/counter.db")
let port = getEnv("PORT", "8000").parseInt

# The browser script lives in client.js and is embedded into the binary at compile time.
const clientJs = staticRead("client.js")

var
  db: DbConn
  dbLock: Lock
  clients: HashSet[WebSocket] # guarded by dbLock too, so pushes stay in order

proc initDb() =
  createDir(dbPath.parentDir)
  db = open(dbPath, "", "", "")
  db.exec(sql"PRAGMA journal_mode=WAL")
  db.exec(sql"PRAGMA busy_timeout=5000")
  db.exec(sql"CREATE TABLE IF NOT EXISTS counter (id INTEGER PRIMARY KEY CHECK (id = 1), value INTEGER NOT NULL)")
  db.exec(sql"INSERT OR IGNORE INTO counter (id, value) VALUES (1, 0)")
  initLock(dbLock)

proc getCount(): int =
  withLock dbLock:
    {.gcsafe.}:
      result = db.getValue(sql"SELECT value FROM counter WHERE id = 1").parseInt

proc pushState(count: int) =
  ## Sends the count and the number of connected browsers to all of them.
  ## Callers must hold dbLock.
  {.gcsafe.}:
    let msg = """{"count":""" & $count & ""","clients":""" & $clients.len & "}"
    for client in clients:
      client.send(msg)

proc increment(): int =
  ## Increments and pushes the new count to every connected browser.
  withLock dbLock:
    {.gcsafe.}:
      result = db.getValue(sql"UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value").parseInt
      pushState(result)

proc page(count: int): string =
  ("""<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nim counter on Disco</title>
<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0}
.c{text-align:center}.n{font-size:5rem;font-weight:700}button{font-size:1.2rem;padding:.6rem 1.6rem;cursor:pointer}
.s{color:#888}.s.on{color:#2a2}</style>
</head><body><div class="c"><div class="n" id="n">$1</div>
<form method="post" action="/increment" id="f"><button>+1</button></form>
<p><small>Nim + Mummy + SQLite, deployed with Disco · <a href="https://github.com/pietroppeter/disco-nim-mummy">source</a></small></p>
<p><small class="s" id="s">offline</small></p></div>
<script>""" % [$count]) & clientJs & "</script></body></html>"

proc indexHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, page(getCount()))

proc incrementHandler(request: Request) =
  discard increment()
  var headers: HttpHeaders
  headers["Location"] = "/"
  request.respond(303, headers)

proc apiCountHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"count":""" & $getCount() & "}")

proc apiIncrementHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"count":""" & $increment() & "}")

proc healthHandler(request: Request) =
  request.respond(200, emptyHttpHeaders(), "ok")

proc wsUpgradeHandler(request: Request) =
  discard request.upgradeToWebSocket()

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent, message: Message) =
  case event
  of OpenEvent:
    # Register and push the state in one step, so a (re)connecting tab catches
    # up without missing or reordering an increment, and every other tab sees
    # the new number of connected clients.
    withLock dbLock:
      {.gcsafe.}:
        clients.incl(websocket)
        pushState(db.getValue(sql"SELECT value FROM counter WHERE id = 1").parseInt)
  of MessageEvent:
    if message.kind == TextMessage and message.data == "inc":
      discard increment()
  of ErrorEvent:
    discard
  of CloseEvent:
    withLock dbLock:
      {.gcsafe.}:
        clients.excl(websocket)
        pushState(db.getValue(sql"SELECT value FROM counter WHERE id = 1").parseInt)

proc heartbeat() {.thread.} =
  # Ping every client periodically so idle connections are not dropped by
  # proxies or mobile networks along the way.
  while true:
    sleep(25_000)
    withLock dbLock:
      {.gcsafe.}:
        for client in clients:
          client.send("", Ping)

when isMainModule:
  initDb()
  var router: Router
  router.get("/", indexHandler)
  router.post("/increment", incrementHandler)
  router.get("/api/count", apiCountHandler)
  router.post("/api/increment", apiIncrementHandler)
  router.get("/health", healthHandler)
  router.get("/ws", wsUpgradeHandler)

  var heartbeatThread: Thread[void]
  createThread(heartbeatThread, heartbeat)

  let server = newServer(router, websocketHandler)
  echo "Serving on 0.0.0.0:", port, " with database ", dbPath
  server.serve(Port(port), "0.0.0.0")
