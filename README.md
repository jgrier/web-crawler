# Restate Web Crawler

A web crawler built on [Restate](https://restate.dev) using the [Ruby SDK](https://github.com/restatedev/sdk-ruby). Demonstrates how Restate's durable execution primitives solve common distributed systems challenges in web crawling: rate limiting, pause/resume, human-in-the-loop intervention, deduplication, and parallel processing.

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │         CrawlManager (VO)               │
  User ─────────────────│  keyed by domain                        │
  POST /CrawlManager/   │                                         │
    {domain}/start       │  Exclusive: start (crawl loop)         │
    {domain}/pause       │  Shared:    pause, resume, status,     │
    {domain}/resume      │            results                     │
    {domain}/status      │                                         │
    {domain}/results     └────┬──────────────┬───────────────┬────┘
                              │              │               │
                   ┌──────────▼──┐  ┌────────▼────────┐  ┌──▼──────────┐
                   │ CrawlState  │  │  PageFetcher    │  │ ContentAna- │
                   │ (VO)        │  │  (VO)           │  │ lyzer       │
                   │ keyed by    │  │  keyed by URL   │  │ (module)    │
                   │ domain      │  │                 │  │             │
                   │             │  │  Dedup via key  │  │ Nokogiri    │
                   │ Pause/resume│  │  TTL cache      │  │ parsing +   │
                   │ signaling   │  │                 │  │ keyword     │
                   │ only        │  │       │         │  │ extraction  │
                   └─────────────┘  └───────┼─────────┘  └─────────────┘
                                            │
                                   ┌────────▼─────────┐
                                   │  RateLimiter     │
                                   │  (VO)            │
                                   │  keyed by domain │
                                   │                  │
                                   │  Token bucket +  │
                                   │  durable sleep   │
                                   └──────────────────┘
```

### Components

| Component | Type | Key | Purpose |
|-----------|------|-----|---------|
| **CrawlManager** | Virtual Object | domain | Public API + crawl loop orchestrator |
| **CrawlState** | Virtual Object | domain | Minimal control-plane state (pause/resume signaling) |
| **PageFetcher** | Virtual Object | URL | Per-page fetch with built-in dedup and TTL cache |
| **RateLimiter** | Virtual Object | domain | Token bucket rate limiter with durable sleep |
| **ContentAnalyzer** | Ruby module | — | HTML parsing, link extraction, keyword analysis |

## Restate Patterns Demonstrated

### 1. Fan-out / Fan-in
Pages are fetched in parallel batches. The crawl manager dispatches multiple `PageFetcher` calls simultaneously and awaits all results before processing the next batch.

### 2. Rate Limiting
A virtual object per domain implements a token bucket. Since the `acquire` handler is exclusive, concurrent fetch requests naturally queue up and are spaced out using durable sleep — no tokens wasted, no threads blocked.

### 3. Pause / Resume
The crawl loop can be paused externally via API (or from the Restate UI by cancelling). Pause uses an **awakeable** — a durable callback token. The crawl suspends at the awakeable, consuming no resources. A `resume` call resolves the awakeable, and the crawl continues exactly where it left off — even across process restarts.

### 4. Human-in-the-Loop
When the crawler hits too many consecutive errors (e.g., a firewall blocking requests), it automatically pauses and logs a message asking for human intervention. The human investigates, fixes the issue, and calls the resume endpoint. Same awakeable mechanism as manual pause.

### 5. Deduplication
Each `PageFetcher` is a virtual object keyed by URL. The first fetch stores the processed result in state. Subsequent calls for the same URL return the cached result immediately. Cache expires after a configurable TTL so pages can eventually be re-crawled.

### 6. Durable Execution
Every HTTP fetch is wrapped in `Restate.run_sync` — a durable side effect. If the process crashes mid-crawl, Restate replays the journal: already-completed fetches are skipped (results replayed from the journal), and the crawl resumes from the exact point of failure.

## Prerequisites

- **Ruby** >= 3.1
- **Restate Server** ([install guide](https://docs.restate.dev/develop/local_dev))
- **Bundler**

## Quick Start

```bash
# Install dependencies
bundle install

# Start Restate server (terminal 1)
restate-server

# Start the crawler service (terminal 2)
bundle exec falcon serve --bind http://localhost:9080

# Register the deployment (terminal 3)
restate deployments register http://localhost:9080
```

### Start a Crawl

```bash
# Fire-and-forget — returns immediately, crawl runs in background
curl -X POST localhost:8080/CrawlManager/restate.dev/start/send \
  -H 'content-type: application/json' \
  -d '{
    "seed_url": "https://restate.dev",
    "max_pages": 30,
    "batch_size": 5
  }'
```

### Monitor Progress

```bash
curl localhost:8080/CrawlManager/restate.dev/status \
  -H 'content-type: application/json' -d 'null'
```

### Pause and Resume

```bash
# Pause
curl -X POST localhost:8080/CrawlManager/restate.dev/pause \
  -H 'content-type: application/json' -d 'null'

# Resume
curl -X POST localhost:8080/CrawlManager/restate.dev/resume \
  -H 'content-type: application/json' -d 'null'
```

### View Results

```bash
curl localhost:8080/CrawlManager/restate.dev/results \
  -H 'content-type: application/json' -d 'null'
```

Returns page titles, headings, keyword analysis per page, and aggregated site-wide keywords.

## Demo: Human-in-the-Loop

Use `simulate_errors_after` to trigger the automatic error-pause flow:

```bash
curl -X POST localhost:8080/CrawlManager/restate.dev/start/send \
  -H 'content-type: application/json' \
  -d '{
    "seed_url": "https://restate.dev",
    "max_pages": 30,
    "batch_size": 5,
    "simulate_errors_after": 10
  }'
```

After 10 successful pages, the crawler starts receiving simulated 403 errors. After 5 consecutive errors, it auto-pauses and logs:

```
[CrawlManager] HUMAN INTERVENTION NEEDED — call POST /CrawlManager/restate.dev/resume to continue
```

Check the status — it will show `"status": "error_paused"`. Resume with:

```bash
curl -X POST localhost:8080/CrawlManager/restate.dev/resume \
  -H 'content-type: application/json' -d 'null'
```

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `seed_url` | *(required)* | Starting URL for the crawl |
| `max_pages` | 50 | Maximum pages to crawl |
| `batch_size` | 5 | Pages fetched in parallel per batch |
| `simulate_errors_after` | *(disabled)* | Start returning 403 errors after N pages |
| `cache_ttl` | 86400 (24h) | Seconds before a cached page result expires |

Rate limiter defaults: 5 token bucket capacity, 2 tokens/second refill rate. Configure via:

```bash
curl -X POST localhost:8080/RateLimiter/restate.dev/configure \
  -H 'content-type: application/json' \
  -d '{"max_tokens": 10, "refill_rate": 5.0}'
```

## Admin

- **Restate UI**: http://localhost:9070 — inspect virtual object state, view invocations, cancel crawls
- **Cancel a crawl**: Cancel the `CrawlManager/{domain}/start` invocation from the UI
- **Restate CLI**: `restate invocations list` to see active crawls
