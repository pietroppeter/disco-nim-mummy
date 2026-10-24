# disco-nim-mummy

A minimal [Disco](https://disco.cloud) example: a click counter written in [Nim](https://nim-lang.org/),
served by [Mummy](https://github.com/guzba/mummy), stored in SQLite.

Live at <https://counter.pietroppeter.xyz>.

This is an educational project to learn more about how to deploy apps.

- `GET /` shows the count with a +1 button (`POST /increment`)
- `GET /api/count` and `POST /api/increment` return JSON
- `GET /health` is used by the Disco health check
- `GET /ws` is a WebSocket that keeps every open tab in sync (see below)

## How it fits Disco

- `Dockerfile` is multi-stage: it compiles with `nimlang/nim:2.2.4-alpine-regular`
  and runs on `alpine:3.20` (about 17 MB). The SQLite library is copied from the
  build image, so the runtime stage needs no `apk`.
- `disco.json` exposes the `web` service on port 8000 and mounts the Disco volume
  `counter-data` at `/data`, where the database lives (`DB_PATH=/data/counter.db`).
  The count survives redeploys.
- SQLite runs in WAL mode, and a lock serialises access across Mummy's worker threads.
- Disco's Caddy proxy passes WebSockets through with no extra config. Connections
  drop on every redeploy (and when phones background the tab), so the page
  reconnects with backoff and the server resends the current count on connect.
  A ping every 25 s keeps idle connections from being cut by intermediaries.
- Live sync assumes one container. Scaling `web` to several replicas would need
  a shared pub/sub (or polling the DB) so each replica hears the others' increments.

## How live sync works

Plain HTTP only answers requests, so a tab can't learn that another tab clicked.
A WebSocket is a connection the browser keeps open, and either side can send a
message on it at any time.

- On load, the page script (`client.js`) opens a WebSocket to `/ws`. The server
  adds it to a set of connected clients and sends the current count.
- Clicking +1 sends `inc` over the socket instead of submitting the form, so the
  page doesn't reload. Without a connection (or without JavaScript), the form
  still posts to `/increment`.
- Every increment (button, form or API) updates SQLite and sends the new count
  to every connected client. One lock covers the database and the client set,
  so updates arrive in order.
- If the connection drops, the script reconnects with growing delays (0.5 s up
  to 10 s), and right away when a phone tab comes back to the foreground.
- `client.js` is a separate file for editing and syntax highlighting. It is
  embedded into the binary at compile time with `staticRead`, so the app is
  still a single file to deploy.

## Run locally

```sh
docker build -t nim-disco-counter .
docker run --rm -p 8000:8000 -v counter-data:/data nim-disco-counter
```

Or without Docker: `nimble build && DB_PATH=./counter.db ./counter`.

## Deploy

You need a server with SSH access as root, for example a Hetzner CX23
running Ubuntu, and the [Disco CLI](https://github.com/letsdiscodev/cli):

```sh
curl -fsSL https://cli-assets.letsdisco.dev/install.sh | sh
```

1. Install Disco on the server. Using the bare IP gets you a free
   `*.ondis.co` host; use a hostname instead if you have DNS pointing at it.

   ```sh
   disco init root@<server-ip>
   ```

2. Give Disco access to the repo. This opens GitHub in the browser to
   install a GitHub App; pick this repository.

   ```sh
   disco github:apps:add
   ```

3. Add the project. This runs the first deployment. Without `--domain`
   the app is served at `counter.<your disco host>`.

   ```sh
   disco projects:add --name counter --github pietroppeter/disco-nim-mummy
   # or with your own domain (point its DNS A record at the server first):
   disco projects:add --name counter --github pietroppeter/disco-nim-mummy --domain counter.example.com
   ```

From then on, every `git push` to `main` redeploys. Disco builds the
Dockerfile on the server, and the `counter-data` volume keeps the count
across deployments.

Useful afterwards:

```sh
disco logs --project counter          # follow the app logs
disco deploy --project counter        # redeploy the latest commit by hand
disco deploy --project counter --dir . # deploy local files without pushing
```
