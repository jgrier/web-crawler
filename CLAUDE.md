# Restate Web Crawler

## Running

```bash
# Terminal 1
restate-server

# Terminal 2
bundle exec falcon serve --bind http://localhost:9080

# Terminal 3
restate deployments register http://localhost:9080
```

Clean state between runs: `rm -rf restate-data/`

## Architecture

4 Virtual Objects + 1 Ruby module. CrawlManager is the only public API (facade pattern).

- **CrawlManager** (VO, keyed by domain) — crawl loop, fan-out/fan-in, holds all crawl data
- **CrawlState** (VO, keyed by domain, ingress_private) — minimal control plane: status, pause_requested, awakeable_id. Exists because shared handlers on CrawlManager can't write to their own VO's state while the exclusive handler runs.
- **PageFetcher** (VO, keyed by URL) — dedup is inherent via VO key, TTL cache, never raises (all errors return result hashes)
- **RateLimiter** (VO, keyed by domain) — token bucket with durable sleep
- **ContentAnalyzer** (plain Ruby module) — Nokogiri HTML parsing, not a Restate service

## Restate Ruby SDK Gotchas

- **No bare `rescue`** — catches Restate's internal `SuspendedError`. Always use `rescue StandardError`.
- **`Restate.sleep(n).await`** — must call `.await` or it returns immediately.
- **No Restate calls inside `run_sync` blocks** — only external/non-deterministic work.
- **Timestamps inside `run_sync`** — `Time.now` outside `run_sync` is non-deterministic on replay.
- **State is JSON** — symbols become strings, all values must be JSON-serializable.
- **Awakeable futures can't be stored in state** — they're runtime objects. This is why pause uses a two-step flag + poll mechanism via CrawlState.
- **Shared handlers CAN read VO state** — so `results` and `status` on CrawlManager read own state directly.
- **Logging duplicates on replay** — `$stderr.puts` will re-run during journal replay. Cosmetic only.
- **Exclusive lock held during sleep** — `Restate.sleep()` in an exclusive handler suspends the invocation but the key lock is NOT released. Other callers queue up until the handler completes.
- **Journaled calls are not re-executed on retry** — if a handler calls another service (e.g. `RateLimiter.acquire`) and that call is journaled, retries replay the result without re-executing. This means if a `run_sync` block fails AFTER acquiring a rate limit token, retries re-execute the fetch without consuming a new token — effectively bypassing the rate limiter. This is why PageFetcher must never raise: if `run_sync` always completes, its result is journaled and won't re-execute on replay.

## Key Design Decisions

- PageFetcher never raises — all errors return `{success: false}` result hashes so one bad URL can't stall the crawl AND so that `run_sync` always completes (preventing retries from bypassing the rate limiter). CrawlManager's consecutive_errors logic handles policy.
- Per-page results are slimmed to `{url, title, word_count}` — keywords are aggregated into site_keywords and discarded per-page.
- site_keywords capped at 200 terms to bound state growth.
- Redirect Location headers are resolved to absolute URLs before enqueueing.
- URLs with nil/empty hosts are filtered in both PageFetcher and ContentAnalyzer.

