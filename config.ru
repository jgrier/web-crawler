# frozen_string_literal: true

require_relative 'lib/crawl_manager'
require_relative 'lib/crawl_state'
require_relative 'lib/page_fetcher'
require_relative 'lib/rate_limiter'

endpoint = Restate.endpoint(CrawlManager, CrawlState, PageFetcher, RateLimiter)
run endpoint.app
