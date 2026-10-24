## Minimal counter for Disco: Mummy serves HTTP, SQLite stores the count.
## The database lives at $DB_PATH (default /data/counter.db), which Disco
## mounts as a persistent volume so the count survives redeploys.

import std/[os, strutils, locks]
import mummy, mummy/routers
import db_connector/db_sqlite

let dbPath = getEnv("DB_PATH", "/data/counter.db")
let port = getEnv("PORT", "8000").parseInt

var
  db: DbConn
  dbLock: Lock

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

proc increment(): int =
  withLock dbLock:
    {.gcsafe.}:
      result = db.getValue(sql"UPDATE counter SET value = value + 1 WHERE id = 1 RETURNING value").parseInt

proc page(count: int): string =
  """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nim counter on Disco</title>
<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0}
.c{text-align:center}.n{font-size:5rem;font-weight:700}button{font-size:1.2rem;padding:.6rem 1.6rem;cursor:pointer}</style>
</head><body><div class="c"><div class="n">$1</div>
<form method="post" action="/increment"><button>+1</button></form>
<p><small>Nim + Mummy + SQLite, deployed with Disco</small></p></div></body></html>""" % [$count]

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

when isMainModule:
  initDb()
  var router: Router
  router.get("/", indexHandler)
  router.post("/increment", incrementHandler)
  router.get("/api/count", apiCountHandler)
  router.post("/api/increment", apiIncrementHandler)
  router.get("/health", healthHandler)

  let server = newServer(router)
  echo "Serving on 0.0.0.0:", port, " with database ", dbPath
  server.serve(Port(port), "0.0.0.0")
