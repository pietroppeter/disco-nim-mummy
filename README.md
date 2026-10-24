# disco-nim-mummy

A minimal [Disco](https://disco.cloud) example: a click counter written in Nim,
served by [Mummy](https://github.com/guzba/mummy), stored in SQLite.

- `GET /` shows the count with a +1 button (`POST /increment`)
- `GET /api/count` and `POST /api/increment` return JSON
- `GET /health` is used by the Disco health check

## How it fits Disco

- `Dockerfile` is multi-stage: it compiles with `nimlang/nim:2.2.4-alpine-regular`
  and runs on `alpine:3.20` (about 17 MB). The SQLite library is copied from the
  build image, so the runtime stage needs no `apk`.
- `disco.json` exposes the `web` service on port 8000 and mounts the Disco volume
  `counter-data` at `/data`, where the database lives (`DB_PATH=/data/counter.db`).
  The count survives redeploys.
- SQLite runs in WAL mode, and a lock serialises access across Mummy's worker threads.

## Run locally

```sh
docker build -t nim-disco-counter .
docker run --rm -p 8000:8000 -v counter-data:/data nim-disco-counter
```

Or without Docker: `nimble build && DB_PATH=./counter.db ./counter`.

## Deploy

Push this folder to a GitHub repo, then add it as a project in Disco
(`disco projects:add`, pointing at the repo and a domain). Disco builds the
Dockerfile on the server and routes the domain to the `web` service.
