# Zero-Downtime Blue/Green Deployment with Nginx, Docker Compose, and CI

## 🎯 Overview
Shipping backend fixes should not interrupt paying customers. This project sets up a production-style Blue/Green rollout for a stateless Node.js service so we can deploy safely, test failures intentionally, and recover without anyone noticing. Two identical containers (Blue and Green) are always running behind an Nginx reverse proxy. Blue handles traffic on port 8081, Green waits in reserve on 8082, and Nginx listens on 8080, retrying the Green pool instantly if Blue hiccups. Everything runs through Docker Compose, so we reuse pre-built images with no rebuild step—CI simply points at the right tags and decides which pool is primary.

## 🏗 Architecture & Components
**Blue container (primary by default)**  
Runs the Node.js app with `APP_POOL=blue` and exposes port 3000 internally. Docker publishes it as `localhost:8081` for direct checks and chaos injection endpoints (e.g., `/chaos/start`, `/healthz`, `/version`).

**Green container (standby)**  
Identical Node.js image tagged independently via `RELEASE_ID_GREEN`. It binds to 8082 and is wired exactly like Blue so it can take over instantly.

**Nginx reverse proxy**  
Listens on 8080 and proxies traffic to the pool defined by `ACTIVE_POOL`. The entrypoint script renders `nginx.conf` via `envsubst`, substituting the primary and backup upstream lines, then launches `nginx -g 'daemon off;'`. Reloading with `nginx -s reload` after changing `ACTIVE_POOL` (or release IDs) lets CI or operators flip traffic without container restarts.

**Environment variables (.env)**  
`BLUE_IMAGE`, `GREEN_IMAGE`, `ACTIVE_POOL`, `RELEASE_ID_BLUE`, `RELEASE_ID_GREEN`, and `PORT` parameterize everything. Because images are supplied via `.env`, CI can test arbitrary Node.js builds without re-baking containers. Additional variables tune alerting and Slack notifications.

**Alert watcher (optional extra)**  
`alert_watcher` tails structured Nginx logs and posts to Slack when error budgets are exceeded or when maintenance mode is toggled.

```
 Client (browser/curl)
          |
          v
   +---------------+
   |   Nginx 8080  |
   +---------------+
      |       |
      |       +--> Green app (standby) :8082
      |
      +----------> Blue app (active)  :8081
```

## 📄 Nginx Configuration & Failover Logic
`nginx/entrypoint.sh` inspects `ACTIVE_POOL` and emits upstream directives with tight failure detection:

```nginx
upstream app_backend {
    zone app_backend_zone 64k;
    keepalive 16;
    server app_blue:3000 max_fails=1 fail_timeout=5s;
    server app_green:3000 backup;
}

proxy_connect_timeout 1s;
proxy_send_timeout 1s;
proxy_read_timeout 1s;
proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
proxy_next_upstream_tries 2;
proxy_pass_header X-App-Pool;
proxy_pass_header X-Release-Id;
```

*Primary vs. backup.* The primary server uses `max_fails=1` and `fail_timeout=5s`, so a single timeout or 5xx marks it unhealthy for five seconds. The backup server is declared with the `backup` keyword, meaning it only receives traffic when the primary is down or returns a failure.

*Retry policy.* Short 1-second timeouts plus `proxy_next_upstream` tell Nginx to retry failures immediately within the same client request. The user still receives a 200 response, now served by the backup pool.

*Header forwarding.* The Node.js service sets `X-App-Pool` and `X-Release-Id`. `proxy_pass_header` ensures those headers reach the client unchanged so monitoring, log shipping, and graders know which release served each response.

## 🔬 Nginx Internals (Logging, Upstreams, Proxying, Locations)

### Logging & JSON formatting
- **Custom log formats exist because one size does not fit production.** NGINX lets you define log formats so you can capture the exact fields your tooling needs (pool, release, upstream status, timing) without post-processing unstructured text.
- **JSON logging requires escaping because raw request data can include quotes, newlines, or control characters.** Without escaping, a single request can break the JSON structure and poison downstream parsers.
- **“Escaping for JSON” means NGINX rewrites characters that would terminate or corrupt a JSON string.** It replaces or encodes characters so each log line remains valid JSON even when the request contains unexpected bytes.
- **Log fields are populated from request-scoped data collected as NGINX processes a request.** NGINX records metadata as it parses headers, routes the request, and completes the response.
- **Timestamps, client IPs, requests, and status codes are derived from the live request.** The time comes from the server clock at request end; the client IP is the observed socket peer (or forwarded headers if configured); the request line is the exact method/path/protocol NGINX received; and the status code is the final response sent to the client.
- **Timing and response size are measured by the proxy engine.** Request time is wall-clock time from first byte received to last byte sent; response size is total bytes written to the client for that request.
- **Upstream fields are only known after proxying completes.** NGINX can only log upstream address, status, and response time once it has attempted an upstream connection and received a response.
- **Upstream values can appear as lists because multiple upstreams may be tried in one client request.** Retries record each upstream result, so NGINX emits comma-separated values to preserve every attempt.

### Upstreams & primary/backup behavior
- **Primary selection is explicit in the upstream definition.** NGINX treats non-backup servers as primaries and routes there first.
- **A “backup” upstream is a hot standby that only receives traffic after primaries are marked unhealthy.** It is not used during normal operation.
- **Failure is detected by NGINX when a request to a primary returns errors or times out based on its health thresholds.** One failed request can temporarily mark a primary as down in a tight failover configuration.
- **Environment-provided values shape the active upstream list at runtime.** The entrypoint renders upstream targets based on env vars, so changing those values changes which servers exist and which is primary without rebuilding images.

### Proxying & retries
- **NGINX proxies because the apps live behind it, not inside it.** It terminates the client connection and forwards to internal services while enforcing timeouts, retries, and headers.
- **Retries happen when upstream failures are considered transient.** Errors, timeouts, invalid headers, and 5xx responses trigger retries because they indicate upstream instability rather than a bad client request.
- **Client errors are not retried because they are deterministic.** A 4xx indicates the client request is invalid, so switching upstreams will not fix it.
- **Retries are transparent to the client because they occur within one request lifecycle.** NGINX only responds once, after a successful upstream response (or after retry limits are exhausted).

### Location handling
- **Location blocks separate request handling so different routes can have different policies.** Health checks are lightweight and should not inherit full proxy behavior.
- **Health-check endpoints are treated differently to reduce noise and avoid masking failures.** They often use shorter timeouts and simple proxy rules to surface issues quickly.
- **Access logging is commonly disabled for health checks to keep logs signal-rich.** High-frequency probes would otherwise dominate log volume.

### Observability intent
- **Structured access logs enable downstream systems to detect errors, failovers, and traffic shifts automatically.** JSON logs are machine-friendly and allow precise alerting based on fields instead of fragile text parsing.
- **Logging upstream identity is critical for debugging and alerting.** Knowing which pool and release served a request is the fastest way to correlate incidents with deploys and failover events.

## ⚙️ Deployment with Docker Compose & Parameterization
The Compose file spins up both app pools, Nginx, and the alert watcher without rebuilding Node images:

```yaml
version: "3.9"
services:
  app_blue:
    image: "${BLUE_IMAGE}"
    environment:
      RELEASE_ID: "${RELEASE_ID_BLUE}"
      PORT: "3000"
      APP_POOL: "blue"
    ports:
      - target: "3000"
        published: 8081

  app_green:
    image: "${GREEN_IMAGE}"
    environment:
      RELEASE_ID: "${RELEASE_ID_GREEN}"
      PORT: "3000"
      APP_POOL: "green"
    ports:
      - target: "3000"
        published: 8082

  nginx:
    image: nginx:1.25-alpine
    environment:
      ACTIVE_POOL: "${ACTIVE_POOL}"
      RELEASE_ID_BLUE: "${RELEASE_ID_BLUE}"
      RELEASE_ID_GREEN: "${RELEASE_ID_GREEN}"
      PORT: "${PORT:-3000}"
    ports:
      - "8080:8080"
```

Add a `.env` file (or set CI variables) with:

```
BLUE_IMAGE=registry.example.com/node-api:blue
GREEN_IMAGE=registry.example.com/node-api:green
ACTIVE_POOL=blue
RELEASE_ID_BLUE=build-2024-05-01
RELEASE_ID_GREEN=build-2024-05-02
PORT=3000
```

Because Compose pulls images as-is, we only swap tags to deploy fresh builds. If CI decides Green should become primary, it updates `ACTIVE_POOL=green`, reruns `docker compose up -d` (or calls `nginx -s reload`), and traffic flips without touching containers.

## ✅ Expected Behavior & Verification
**Baseline (Blue active).** With the stack up, `curl -i http://localhost:8080/version` returns a 200, `X-App-Pool: blue`, and `X-Release-Id: <blue release>`. Repeated requests stay on Blue because the primary is healthy.

**Failure simulation.** To mimic a production incident, hit the chaos endpoint exposed on the Blue container:  
`curl -X POST "http://localhost:8081/chaos/start?mode=error"`. The service begins responding with 5xx (or not at all). Nginx sees the failure after a 1-second timeout and retries on the backup pool before finalizing the client response.

**After failover.** Subsequent `GET /version` calls through Nginx now include `X-App-Pool: green` and `X-Release-Id: <green release>` while still returning HTTP 200. The client is unaware anything failed, and ≥95% of requests during the chaos window hit Green thanks to the retry policy. Once Blue recovers (`curl -X POST http://localhost:8081/chaos/stop`), it re-enters service automatically after the `fail_timeout` window expires.

## 🧪 Testing & CI Integration
Continuous verification matters more than manual curls, so the repo ships `scripts/verify_failover.sh`. A typical CI job:

1. Populate `.env` with the desired images and metadata (no builds).  
2. `docker compose up -d` to start all services.  
3. Run `./scripts/verify_failover.sh`, which:
   - Polls `http://localhost:8080/version` until it sees `X-App-Pool=<ACTIVE_POOL>`.
   - Triggers chaos on the primary pool.
   - Issues 15 requests, ensuring every response is 200 and ≥95% are served by the standby pool.
   - Stops chaos and exits non-zero if any requirement fails.
4. Archive Nginx logs if the script fails so engineers can inspect upstream timings.

If `ACTIVE_POOL` changes mid-run (e.g., Blue → Green for a staged rollout), CI can update `.env`, re-run the entrypoint (`envsubst` + `nginx -s reload`), and confirm the new pool is serving traffic before cutting a release.

## 💡 Why This Design / Benefits
- **Zero downtime & zero failed requests.** Immediate retries mean clients never see a 5xx during controlled failures.
- **Simple tooling.** Standard Docker Compose plus `.env` variables avoid Kubernetes complexity while remaining automation-friendly.
- **Deterministic failover.** Low proxy timeouts and `max_fails=1` detect issues in seconds, switching pools predictably.
- **CI-ready parameterization.** Operators control everything through environment variables—swap image tags, release IDs, or primary pool without editing YAML.
- **Safe chaos testing.** Dedicated `/chaos/*` and `/healthz` endpoints let teams practice incidents daily without touching production users.

## 📝 Summary & Next Steps / Potential Extensions
We now have a production-grade Blue/Green deployment: two Node.js pools running simultaneously, Nginx managing instant failover, headers preserved for telemetry, and CI scripts that prove the behavior every time code changes. Future enhancements could include (1) push-button failback with Slack approvals, (2) Prometheus/Grafana dashboards fed by the structured Nginx logs, (3) automated rollback thresholds that flip pools if error rates exceed a budget, or (4) adding WebSocket-aware health probes for real-time APIs.

## 📚 References / Further Reading
- [Martín Fowler — Blue/Green Deployments](https://martinfowler.com/bliki/BlueGreenDeployment.html)
- [NGINX Docs: Reverse Proxy and Load Balancing](https://docs.nginx.com/nginx/admin-guide/load-balancer/http-load-balancer/)
- Similar open-source patterns inspired this setup, but the configuration here is tailored to Node.js services that expose `/version`, `/healthz`, and `/chaos` endpoints for release verification.
