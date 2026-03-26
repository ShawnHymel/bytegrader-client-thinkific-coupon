I'm building a Thinkific client for ByteGrader — a Go-based autograding server. This client is a small, completely stateless Go web application that runs alongside ByteGrader on the same DigitalOcean droplet. I want to build and test one feature at a time, so do not implement everything at once. After each feature is working, we'll move to the next. Please ask clarifying questions before writing any code.

## Reference Folders

The following sibling folders contain reference code:

* **../bytegrader/** - ByteGrader backend (server) code, latest version
* **../bytegrader-client-learndash/** - Example client used for the LearnDash WordPress plugin
* **../course-iot-with-esp-idf-assignments** - The exact grader paired with ByteGrader for the course. The Thinkific client should be generic enough to work with any grader, but use this as an example.

Do not modify any repo other than this one. If a ByteGrader change is needed, flag it first.

## Architecture Overview

The Thinkific client is a single stateless Go HTTP server with no database and no background processes. It has four responsibilities:

1. **Serve the submission portal** — A webpage embedded as a Multimedia lesson in Thinkific via an iframe. Thinkific passes student identity as URL query parameters:
   `?email={{email}}&first_name={{first_name}}&last_name={{last_name}}&assignment={{assignment_id}}`
   The portal renders a file upload UI personalized to the student.

2. **Forward submissions to ByteGrader** — Accepts the student's ZIP file upload, forwards it to ByteGrader's local API, and returns the jobId to the browser. The client acts as a proxy so the browser never needs ByteGrader's URL or API key.

3. **Proxy status checks** — Exposes a /status/{jobId} endpoint that the browser polls every few seconds. The client forwards the request to ByteGrader and returns the result.

4. **Handle completion** — When the browser detects a passing score, it calls the client's /complete endpoint with the jobId. The client re-fetches the result directly from ByteGrader to independently verify the score (the browser cannot be trusted to self-report a passing grade). If confirmed passing, the client sends the student an email via Resend containing their score, feedback, coupon code, and a direct checkout link to Course B.

## HTTPS

The client listens on plain HTTP on CLIENT_PORT (e.g. 8081). HTTPS is handled entirely by
a dedicated nginx reverse proxy managed by the client's own install.sh — do not add TLS
handling to the Go server. The client runs on its own subdomain (e.g.
portal.esp32-iot.bytegrader.com), fully independent of ByteGrader's nginx config. This
keeps the two services modular: updating or redeploying ByteGrader has no effect on the
client's nginx setup, and vice versa.

## Key Design Decisions

- **Language:** Go
- **No database** — fully stateless. No SQLite, no Redis, nothing persistent.
- **Email:** Resend (resend-go SDK)
- **Web server:** Go standard library net/http (no heavy frameworks)
- **Deployment:** Runs as a Docker container, alongside ByteGrader and the grader on
  the same droplet. Built via a multi-stage Dockerfile (no Go installation required on
  the host). Managed with Docker Compose.
- **Inter-service networking:** The client and ByteGrader share a Docker network named
  `bytegrader-net`. BYTEGRADER_URL uses the Docker service name (e.g. http://bytegrader:8080) —
  ByteGrader's port is not exposed to the host.
- **ByteGrader API:** Accessed via Docker network. Requires X-API-Key header.
- **HTTPS:** Handled by the client's own nginx reverse proxy, configured and managed
  by install.sh independently of ByteGrader's nginx setup. The client listens on a
  local port; nginx proxies to it with SSL already terminated.
- **Subdomain:** The client runs on its own subdomain (e.g. portal.esp32-iot.bytegrader.com),
  separate from ByteGrader's subdomain. install.sh obtains its own SSL cert via certbot.
- **Truly stateless:** No files written at runtime. All state lives in the browser
  (the jobId) and in ByteGrader (the job result). The client holds only the
  in-memory coupon list loaded at startup.

## Coupon Strategy

One single unlimited-use 100% off coupon code per assignment is pre-generated in Thinkific
for Course B and loaded at startup via environment variable (COUPONS_HW1=SOMECODE).

On each deployment, a new coupon is generated in Thinkific and the old one deleted.

If the env var is missing for a given assignment, the client sends the results email
without a coupon and logs a warning.

## Score Validation in /complete

The /complete endpoint receives a jobId from the browser. It must NOT trust any score
value sent by the browser. Instead it:
1. Calls ByteGrader GET /status/{jobId} directly
2. Checks that status == "complete"
3. Checks that score >= PASSING_SCORE
4. Only then sends the coupon email

## Browser-Side Flow

```
Student loads portal iframe
↓ (Thinkific injects email, name, assignment into URL params)
Portal displays "Hi {first_name}, upload your assignment below"
↓
Student selects ZIP and clicks Submit
↓
JS: POST /submit → receives { job_id: "abc123" }
↓
JS: poll GET /status/abc123 every 3 seconds
↓ (show spinner + "Grading in progress...")
↓
Status == "complete":
  Show score and feedback to student
  If score >= PASSING_SCORE (client-side check for display only):
    POST /complete { job_id: "abc123" }
    Show "You passed! Check your email for your Course B access code."
  Else:
    Show "Not quite — review the feedback and resubmit when ready."
```

The client-side pass/fail check is for display only. The authoritative check is in /complete.

## Configuration

All configuration lives in config.yaml at the repo root. install.sh reads this file
(using the same python3 cfg() pattern as ByteGrader) and passes values to the container
as environment variables. The Go server reads only environment variables — it never reads
config.yaml directly.

### config.yaml fields

- bytegrader_path     — absolute path to the bytegrader repo on the server
- domain              — root domain, e.g. bytegrader.com
- subdomain           — client subdomain, e.g. portal.esp32-iot
- ssl_email           — email for Let's Encrypt notifications
- bytegrader_api_key  — must match an entry in bytegrader/config.yaml api_keys
- resend_api_key      — Resend API key for sending email
- resend_from         — e.g. "ByteGrader <grader@yourdomain.com>"
- client_port         — port the client listens on inside Docker, e.g. 8081
- passing_score       — minimum score to trigger coupon email, e.g. 80.0
- course_b_url        — direct Thinkific checkout URL for Course B
- coupons             — map of assignment ID to coupon code:
                          coupons:
                            hw1: SOMECODE

### Environment variables (set by install.sh, read by Go server)

- BYTEGRADER_URL, BYTEGRADER_API_KEY
- RESEND_API_KEY, RESEND_FROM
- CLIENT_PORT, PASSING_SCORE, COURSE_B_URL
- COUPONS_{ID} — one per assignment (e.g. COUPONS_HW1=SOMECODE)

## ByteGrader API (what we're calling)

- POST /submit?assignment={assignment_id}
  Multipart form, file field "file"
  Returns: {"job_id": "abc123"}

- GET /status/{job_id}
  Returns: {"status": "pending|running|complete|error", "score": 85.0, "feedback": "..."}

Both require header: X-API-Key: {BYTEGRADER_API_KEY}

## Endpoints the Client Exposes

- GET  /portal        — serves the submission portal HTML page
- POST /submit        — accepts multipart file upload, proxies to ByteGrader
- GET  /status/{id}   — proxies status check to ByteGrader
- POST /complete      — validates score and sends coupon email
- GET  /health        — returns {"status":"ok"} for monitoring

## Security Considerations

- /submit and /complete must have per-IP rate limiting
- Uploaded files must be validated as ZIPs before forwarding
- ByteGrader's URL and API key are never exposed to the browser
- CORS: portal is same-origin so no CORS config needed for normal use;
  optionally restrict to Thinkific domains via ALLOWED_ORIGINS env var

## Directory Structure

```
bytegrader-client-thinkific-coupon/
├── main.go               — entry point, wires everything together
├── config.go             — loads env vars, fails fast if required vars missing
├── handlers.go           — HTTP handlers for all endpoints
├── bytegrader.go         — ByteGrader API client (Feature 3)
├── email.go              — Resend email sending (Feature 6)
├── go.mod
├── web/
│    └── portal.html      — submission portal UI, embedded via go:embed (Feature 2)
├── Dockerfile             — multi-stage build (no Go required on host)
├── docker-compose.yaml
├── .env                   — written by install.sh, gitignored
├── .env.example           — copy to .env for local testing
├── coupons.env            — written by install.sh, gitignored
├── coupons.env.example
├── config.yaml            — all configuration (edited by operator before install)
├── install.sh             — deploys client AND calls bytegrader/install.sh
└── .gitignore
```

**Deployment model:** The repo itself is the deployment directory. `install.sh` writes `.env` and `coupons.env` from `config.yaml` and runs `docker compose` from the repo root. No source file copying.

## Feature Checklist

- [x] **Feature 1** — Project scaffold, config loading, `/health` endpoint, Dockerfile, docker-compose, install.sh
- [ ] **Feature 2** — Portal page: `GET /portal` serves `web/portal.html` via `go:embed`; page reads `email`, `first_name`, `last_name`, `assignment` from URL params and renders them
- [ ] **Feature 3** — ByteGrader client: `bytegrader.go` — internal HTTP client that calls ByteGrader `/submit` and `/status` with the API key header
- [ ] **Feature 4** — Submit endpoint: `POST /submit` validates ZIP, proxies to ByteGrader via Feature 3, returns `{"job_id": "..."}` to browser; per-IP rate limiting
- [ ] **Feature 5** — Status proxy: `GET /status/{id}` proxies ByteGrader status response to browser
- [ ] **Feature 6** — Email: `email.go` Resend SDK integration with template (score, feedback, coupon code, Course B link)
- [ ] **Feature 7** — Complete endpoint: `POST /complete` re-verifies score via Feature 3, sends email via Feature 6; per-IP rate limiting
