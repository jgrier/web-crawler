#!/usr/bin/env python3
# Usage: ./results.sh <domain>
# Example: ./results.sh qualified.com

import json, sys, urllib.request

domain = sys.argv[1] if len(sys.argv) > 1 else None
if not domain:
    print("Usage: ./results.sh <domain>")
    sys.exit(1)

def fetch(handler):
    url = f"http://localhost:8080/CrawlManager/{domain}/{handler}"
    req = urllib.request.Request(url, data=b"null", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

status = fetch("status")
data = fetch("results")

pages = status.get("pages_crawled", 0)
max_p = status.get("max_pages", "?")
queued = status.get("queue_size", 0)
err_count = status.get("error_count", 0)
started = status.get("start_time", "?")
st = status.get("status", "unknown").upper()

sep = "=" * 60

print(f"""
{sep}
  Crawl Report: {domain}
{sep}
  Status:    {st}
  Progress:  {pages} / {max_p} pages crawled
  Queued:    {queued} URLs remaining
  Errors:    {err_count}
  Started:   {started}
{sep}
""")

# Keywords
keywords = data.get("site_keywords", {})
if keywords:
    print("  TOP KEYWORDS")
    print("  " + "-" * 40)
    max_count = max(keywords.values())
    for term, count in keywords.items():
        bar = "\u2588" * int(30 * count / max_count)
        print(f"  {term:20s} {count:>6}  {bar}")
    print()

# Pages
results = data.get("results", [])
content_pages = [r for r in results if r.get("title") and not r["title"].startswith("Redirect")]
if content_pages:
    print(f"  PAGES CRAWLED ({len(content_pages)} with content)")
    print("  " + "-" * 40)
    for r in content_pages[:30]:
        wc = r.get("word_count", 0)
        title = r["title"][:60]
        print(f"  {wc:>5} words | {title}")
    if len(content_pages) > 30:
        print(f"  ... and {len(content_pages) - 30} more")
    print()

# Errors
errors = data.get("errors", [])
if errors:
    print(f"  ERRORS ({len(errors)})")
    print("  " + "-" * 40)
    for e in errors[:10]:
        print(f"  {e.get('url', '?')[:60]}")
        print(f"    {e.get('error', '?')}")
    print()
