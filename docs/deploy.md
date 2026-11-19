# Deploying CodeTutor

Status: **Deploy Steps 0 to 4 done; Step 5's files are written and tested on the laptop, not yet
run on a server** (section 10). The whole app runs in containers, on a laptop or a server, with
the same images. It is **not live yet**; see section 5.

## 1. The containers

`compose.prod.yaml` starts five containers from three images (`deploy/`):

| Container | Image | What it does |
|---|---|---|
| `db` | `pgvector/pgvector:pg17` (pinned) | Postgres + pgvector. No port is published: only the other containers reach it |
| `migrate` | `codetutor-app` | Runs once: `alembic upgrade head`, then rebuilds the API's database role (`scripts/db_roles.py`), then copies the problems in. The others wait for it to finish, so only one problem sync ever runs |
| `api` | `codetutor-app` | FastAPI on port 8000 inside the network (127.0.0.1:8010 on the machine); connects as the role `codetutor_api` (no hidden tests); guest sessions only |
| `worker` | `codetutor-app` | Takes queued submissions and grades each one in a fresh `codetutor-sandbox` container |
| `web` | `codetutor-web` | Next.js on port 3000 inside (127.0.0.1:3200 on the machine); forwards `/api/*` to `api` |
| `demo-api` | `codetutor-app` | Profile `demo`: the public teacher view of a **simulated** class (section 7). Read-only, own database, no token |
| `tutor` | `codetutor-app` | Off by default (profile `tutor`) until Deploy Step 4 decides where the model runs |

`codetutor-sandbox` is not a running service. It is the pinned `python:3.12-slim` plus
`runner.py`, and the worker starts one container of it per submission, with the same locks as
before: no network, read-only, `nobody`, all capabilities dropped, memory, CPU and process limits.

**One image, four roles.** `codetutor-app` holds the Python code once. The compose file picks the
command (migrate, api, worker, tutor), so all four always run the same code version.

## 2. Run it on your machine

```bash
cp .env.prod.example .env.prod   # then fill in the three values (openssl rand -hex 24)
make prod-build                  # builds the 3 images (first time ~2.5 min)
make prod-up                     # starts everything and waits until it is healthy
make prod-e2e                    # 9 end-to-end checks over HTTP (no tutor yet)
make prod-down                   # stops it (the database volume is kept)
```

Open http://127.0.0.1:3200. `make prod-ps` shows the containers, and `make prod-logs` follows
their logs. Measured on the laptop (2026-11-09): build 2 min 34 s, start 26 s, first grading
3.6 s. Image sizes: app 421 MB, web 996 MB, sandbox 177 MB.

## 3. Design decisions

- **The runner lives in the grading image.** Locally, `DockerSandbox` bind-mounts `runner.py`
  from the package folder. A worker *inside* a container can't do that: the Docker daemon looks
  up bind-mount paths on the host's disk, where the worker's files don't exist. So the worker uses
  `codetutor-sandbox` (`SANDBOX_IMAGE`), and at start it checks that the image's runner is
  byte-identical to its own. A stale image is refused ("rebuild it: make prod-build"), because
  it would otherwise grade with an old runner without anyone noticing. Same Python, same runner,
  same options, so `GRADER_VERSION` did not change; a test grades fizzbuzz both ways and compares.
- **Pinned and multi-arch.** Every base image is pinned by digest and has amd64 and arm64
  builds. CI builds and runs the whole stack on both (`prod-images` job), because the planned
  server (Oracle Cloud Always Free) is ARM.
- **Least privilege.** The app containers run as uid 10001, the web as `node`, with read-only
  filesystems (only `/tmp` is writable). `.dockerignore` keeps every `.env*` file, `.git`, the
  virtual environment and the lab data out of the build, so a secret can never end up in an image.
- **Build-time vs run-time settings.** Next.js computes the `/api` rewrite when it builds, so the
  web image is built with `CODETUTOR_API_URL=http://api:8000`. Secrets are only read at run
  time from `.env.prod` (git-ignored, and checked by `scripts/check_secrets.py`).
- **Logs rotate** (3 × 10 MB per container), so they can't fill the server's disk.

## 4. The Docker socket (an honest trade-off)

The worker needs `/var/run/docker.sock` to start grading containers. **Whoever can use that
socket is as powerful as root on the machine.** That is true for any process that runs `docker`,
including `make worker` on a laptop. What keeps it acceptable:

- the worker's own code is ours; student code never sees the socket: it runs in the sandbox
  containers, with no network and no host files;
- the socket is mounted only into `worker`, never into `api`, `web` or `tutor`.

Deploy Step 3 added the stronger wall: gVisor (`runsc`) runs each grading container on its own
user-space kernel (section 8).

## 5. What is safe, and what is not yet

| Gap | Status |
|---|---|
| Login | **Done (2a):** guest sessions (random token in an HttpOnly, Secure, SameSite=Lax cookie; only its sha256 stored). Dev login (`X-User-Id`) is off unless `CODETUTOR_DEV_LOGIN=1`, which compose never sets. The web UI uses the guest button + `GET /api/me` (2b); CI drives it in Chrome against the containers |
| The API's database user could read the hidden tests | **Done (2a):** role `codetutor_api`, enforced by Postgres (`db/roles.py`) |
| Request size, per-IP and site-wide limits | **Done (2a):** 413 over 512 KiB; 5 guests/hour per IP; 200 guests/hour, 50 queued submissions, 10 waiting hints in total (docs/api.md §4) |
| The visitor's IP behind the proxies | **Fixed in the files (5), to re-check on the server:** Next.js passes a visitor's own `X-Forwarded-For` through (measured), so `deploy/Caddyfile` replaces that header and `TRUSTED_PROXY_HOPS` stays 1. `deploy/check-proxy-ip.sh` (the spoofed-header test) passed through Caddy and failed without it on the laptop, 2026-11-19 (section 10) |
| The instructor token is one shared secret | **Public demo done (2c):** a separate read-only API on a simulation database, no token needed because no real person is in it. The real teacher routes keep the shared token: fine for one private owner, not for several teachers |
| Grading containers share the host kernel | **Done (3):** gVisor (`SANDBOX_RUNTIME=runsc`, section 8); proven in CI on amd64 and arm64. The server must set it (Step 5) |
| No tutor model on the server | **Launch choice (2026-11-15):** teacher hints only (`TUTOR_MODE=teacher`, section 9), and the UI says so. The AI tutor is one command away (`make prod-tutor-up`) |
| No HTTPS, no server, no backups | **Files ready (5):** Caddy with automatic HTTPS, `deploy/setup-server.sh`, nightly `deploy/backup.sh` (section 10). Backups stay on the server's disk; the server itself is not created yet |

## 6. Known limits

- The web image is large (996 MB: `next` 203 MB, its platform build 93 MB, `monaco-editor`
  105 MB that only the browser needs). Next.js's `output: "standalone"` would shrink it a lot
  (docs/ideas.md).
- The tutor container is untested: on 2026-11-09 the laptop's Ollama was not running, and a
  container could not reach `host.docker.internal:11434`. Step 4 decides.
- `DOCKER_GID` is read from the host's socket by `make`. On Docker Desktop (this laptop) the
  socket's group inside containers matched the host (1001); check it again on the server.

## 7. The public demo (Deploy Step 2c)

Visitors can open `/demo`: the teacher view of the **held-out simulated class** (60 invented
students, 3,076 graded submissions), with skill estimates, early-warning risk and integrity marks.
No login and no token, because nothing in it is a real person. Built so that this can't leak
anything real:

| Layer | What it does |
|---|---|
| Separate database | `codetutor_sim_s1`, built by the real simulation code. The real database is never read |
| Read-only role | `codetutor_demo` may `SELECT` names, problems, the flags and five columns of `submissions` (id, user, problem, time, grade). **No code, output or editor summaries**, and no write of any kind (`db/roles.py`, tested) |
| Separate process | `demo-api` mounts only the four teacher GET routes: no guest, login, submit or hint route exists there (`api/demo.py`, tested) |
| Name guard | the factory refuses a database whose name doesn't contain "sim" |
| Cache | the class is computed once per 5 minutes for all visitors (the fit costs ~0.3 s) |
| Web | the `/demo-api` rewrite points at it; every demo page carries a "Simulated class" banner |

```bash
make prod-demo-data              # once: build + grade + flag the class in the stack (~13 min)
make prod-demo-up                # start demo-api (127.0.0.1:8011), then open /demo
make prod-demo-data DEMO_LIMIT=60   # a tiny class, ~1 min (CI uses this)
```
`prod-demo-data` runs three one-shot containers: `demo-seed` (drop and rebuild only
`codetutor_sim_s1`, queue the cohort, create the role), `demo-grade` (four workers, the same
sandbox as real submissions) and `demo-flags` (the integrity job). Labels (which student is a
cheater) stay in the cohort files and never enter the database.

## 8. gVisor for the grading containers (Deploy Step 3)

Docker containers share the host's kernel. With `SANDBOX_RUNTIME=runsc` the worker starts every
grading container under gVisor instead: a second kernel, in user space, between the code and the
host (docs/grader.md §6). Only the **grading** containers use it; api, worker and db stay on
runc (the worker needs the Docker socket and is our own code).

```bash
sudo deploy/install-gvisor.sh     # pinned release 20261019.0 + SHA-512 per CPU type; registers "runsc"
echo "SANDBOX_RUNTIME=runsc" >> .env.prod
```
- **Fail closed:** if the variable is set and Docker lacks the runtime, the worker refuses to start.
- **CI proof:** the `gvisor` job runs the 38 hostile-code tests under `runsc` on amd64 and arm64;
  the `prod-images` jobs grade the whole stack (e2e, demo class, browser run) under it.
- **Cost:** about +100 ms per submission (GitHub runner measurement). A fork bomb ends as
  `crashed` instead of "accepted with STARTED=62".
- **Not on the laptop:** Docker Desktop's VM has no `runsc`; leave `SANDBOX_RUNTIME` empty there
  (plain Docker, fine for your own code, not for strangers').
- **Step 5 must** run the install script on the server and set the variable.

## 9. The AI tutor in the stack (Deploy Step 4)

`make prod-tutor-up` starts Ollama (no published port), pulls `TUTOR_MODEL` and
`nomic-embed-text` into a volume, embeds the course notes, and starts the tutor worker. The
worker has no Docker socket. The model was chosen by a rule written before the measurement
(docs/tutor.md §6): 1.5B on the CPU. `make prod-e2e-hints` runs the full 11 end-to-end checks
with a real hint (a CPU hint takes 20-40 s). Needs about 2 GB of RAM for the 1.5B.

### Teacher hints only (the launch setting)

Without the AI tutor, the default stack (`make prod-up`) still answers hints: the `tutor`
worker runs with `TUTOR_MODE=teacher`, loads no model and needs no Ollama, and answers each
request with the problem's own hint for that level (saved as `source = reference`; no note
search, no model attempts in the trace). The web container gets the same `TUTOR_MODE`, so the
hint panel says "The AI tutor is off in this demo" and hides the question box (a teacher's hint
can't answer a question). Measured on the laptop 2026-11-15: a hint in 1.1 s, `make prod-e2e`
11/11 and `make prod-web-e2e` 9/9 with the hint steps on.

| Command | Hints |
|---|---|
| `make prod-up` | the teacher's (`TUTOR_MODE=teacher`, the compose default) |
| `make prod-tutor-up` | the AI tutor's (recreates `tutor` and `web` with `TUTOR_MODE=ai`) |
| `make prod-tutor-down` | back to the teacher's (Ollama stopped, its models kept) |

Leave `TUTOR_MODE` out of `.env.prod`: these targets choose it, so the worker and the UI can't
disagree. A value other than `ai` or `teacher` stops the worker at start (`settings.tutor_mode`).

## 10. The server (Deploy Step 5)

Oracle Cloud Always Free: an Ampere A1 (ARM) VM with Ubuntu 24.04, a free DuckDNS name, Caddy in
front. Budget $0. Teacher hints only (section 9).

```
visitor ──HTTPS──> Caddy (:443, the only open ports are 80/443 and SSH)
                     └─> web 127.0.0.1:3200 ──> api / demo-api (inside the Docker network)
```

| File | What it does |
|---|---|
| `deploy/Caddyfile` | HTTPS for the domain (Let's Encrypt, renewed by Caddy), proxy to the web container, **replaces** `X-Forwarded-For` with the address Caddy saw, 1 MB body cap, HSTS, rotated access log |
| `deploy/setup-server.sh` | Run once as root from the clone (safe to run again): Docker from Docker's apt repo, gVisor (`install-gvisor.sh`), Caddy, ports 80/443 in iptables (Oracle's image rejects everything else), the nightly backup cron |
| `deploy/backup.sh` | `pg_dump` of the real database (custom format) into `/var/backups/codetutor`, checked with `pg_restore --list`, newest 7 kept |
| `deploy/check-proxy-ip.sh` | The spoofed-header test, run from your own computer |

### Order

1. Oracle console: create the VM (Ampere A1, Ubuntu 24.04, your SSH key). In its subnet's
   security list, add ingress rules for TCP 80 and 443 from `0.0.0.0/0`.
2. DuckDNS: make a name, set it to the VM's public IP.
3. On the VM:
   ```bash
   git clone https://github.com/najeeb101/codetutor.git && cd codetutor
   sudo deploy/setup-server.sh <name>.duckdns.org
   exit                                   # log in again, so the docker group applies
   cd codetutor && cp .env.prod.example .env.prod   # fill it in, SANDBOX_RUNTIME=runsc
   make prod-build prod-up
   make prod-demo-data prod-demo-up       # optional, the public /demo (~13 min once)
   ```
4. From your own computer: open `https://<name>.duckdns.org`, then
   `deploy/check-proxy-ip.sh https://<name>.duckdns.org` must print PASS.
5. An uptime check (a free monitor) on `https://<name>.duckdns.org/api/health`.

### The spoofed-header test

The API allows 5 new guests per hour per address. The script asks for 6, each with a different
made-up `X-Forwarded-For`. If the API ignores the made-up header, one of them gets 429 (PASS);
if all 6 get in, a visitor can choose their own address (FAIL). Measured on the laptop
2026-11-19, with the same Caddyfile in a container: through Caddy, guest 6 got 429 (PASS);
straight to the web container, all 6 got in (FAIL), so the test can tell the two apart.

A PASS alone would also come out if every visitor looked like the same address. So on the
server, right after the test, start a guest from another network (a phone on mobile data): it
must get in. If it gets 429 too, the API sees one address for everyone.

### Backups

```bash
deploy/backup.sh                                        # by hand; cron runs it at 03:30 UTC
ls -l /var/backups/codetutor                            # the newest 7
# restore one (stops nothing; replaces the tables' contents):
docker compose -f compose.prod.yaml --env-file .env.prod exec -T db \
    pg_restore -U codetutor -d codetutor --clean --if-exists < /var/backups/codetutor/<file>.dump
```
Measured on the laptop 2026-11-19: 84 KB per dump, about 1 s, pruning to `KEEP` works. The
dumps are on the VM's own disk: they undo a bad delete or migration, not the loss of the VM.
Copy one to your computer now and then (`scp`).

### Still open

- Not run on a real Oracle VM yet: the setup script, HTTPS and the test above.
- The tutor CPU benchmark (section 9) was measured on CI runners, not on the Ampere VM.
- The teacher routes keep one shared token (section 5).
