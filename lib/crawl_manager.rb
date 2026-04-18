# frozen_string_literal: true

require 'restate'
require_relative 'crawl_state'
require_relative 'page_fetcher'

class CrawlManager < Restate::VirtualObject
  # Public API for the web crawler. Keyed by domain.
  #
  # The exclusive `start` handler runs the crawl loop with fan-out/fan-in.
  # Shared handlers provide pause/resume/status/results — they delegate
  # control-plane operations to CrawlState (a separate VO) to avoid deadlock.
  #
  # State (owned, read/written only by exclusive handler):
  #   queue, pages_crawled, results, errors, consecutive_errors,
  #   config, site_keywords, start_time

  DEFAULT_MAX_PAGES = 50
  DEFAULT_BATCH_SIZE = 5
  ERROR_THRESHOLD = 5

  handler def crawl(config)
    domain = Restate.key
    seed_url = config['seed_url']
    max_pages = config['max_pages'] || DEFAULT_MAX_PAGES
    batch_size = config['batch_size'] || DEFAULT_BATCH_SIZE
    simulate_errors_after = config['simulate_errors_after']
    cache_ttl = config['cache_ttl']

    # Initialize own state
    Restate.set('queue', [seed_url])
    Restate.set('pages_crawled', 0)
    Restate.set('results', [])
    Restate.set('errors', [])
    Restate.set('consecutive_errors', 0)
    Restate.set('config', config)
    Restate.set('site_keywords', {})
    start_time = Restate.run_sync('start-time') { Time.now.iso8601 }
    Restate.set('start_time', start_time)

    # Signal running status
    CrawlState.call(domain).set_status('running').await

    $stderr.puts "[CrawlManager] Starting crawl of #{domain} (max: #{max_pages} pages, batch: #{batch_size})"

    loop do
      # Check for external pause request
      pause_requested = CrawlState.call(domain).is_pause_requested(nil).await
      if pause_requested
        $stderr.puts "[CrawlManager] Pause requested for #{domain} — pausing..."
        do_pause(domain, 'manual')
      end

      # Pop next batch from queue
      queue = Restate.get('queue') || []
      break if queue.empty?

      batch = queue.shift(batch_size)
      Restate.set('queue', queue)

      pages_crawled = Restate.get('pages_crawled') || 0
      $stderr.puts "[CrawlManager] Fetching batch of #{batch.size} pages (#{pages_crawled}/#{max_pages} done, #{queue.size} queued)"

      # Should we simulate errors for this batch?
      should_simulate = simulate_errors_after && pages_crawled >= simulate_errors_after

      # Fan-out: dispatch parallel page fetches
      futures = batch.map do |url|
        PageFetcher.call(url).fetch({
          'domain' => domain,
          'cache_ttl' => cache_ttl,
          'simulate_errors' => should_simulate
        })
      end

      # Fan-in: await all results
      results_list = Restate.get('results') || []
      errors_list = Restate.get('errors') || []
      site_keywords = Restate.get('site_keywords') || {}
      consecutive_errors = Restate.get('consecutive_errors') || 0

      futures.each do |future|
        result = future.await

        if result['success']
          # Store minimal per-page summary (keywords already aggregated into site_keywords)
          results_list << {
            'url' => result['url'],
            'title' => result['title'],
            'word_count' => result['word_count']
          }
          pages_crawled += 1
          consecutive_errors = 0

          # Merge keywords into site-wide aggregation, cap at 200 terms
          (result['keywords'] || {}).each do |term, count|
            site_keywords[term] = (site_keywords[term] || 0) + count
          end
          if site_keywords.size > 200
            site_keywords = site_keywords.sort_by { |_, c| -c }.first(200).to_h
          end

          # Enqueue newly discovered same-domain links
          new_links = (result['links'] || []) - queue
          queue = Restate.get('queue') || []
          queue.concat(new_links)
          Restate.set('queue', queue)

          $stderr.puts "[CrawlManager] Crawled: #{result['url']} — \"#{result['title']}\""
        else
          errors_list << { 'url' => result['url'], 'error' => result['error'], 'fetched_at' => result['fetched_at'] }
          consecutive_errors += 1
          $stderr.puts "[CrawlManager] Error: #{result['url']} — #{result['error']} (#{consecutive_errors} consecutive)"
        end
      end

      # Persist updated state
      Restate.set('results', results_list)
      Restate.set('errors', errors_list)
      Restate.set('pages_crawled', pages_crawled)
      Restate.set('consecutive_errors', consecutive_errors)
      Restate.set('site_keywords', site_keywords)

      # Human-in-the-loop: too many consecutive errors
      if consecutive_errors >= ERROR_THRESHOLD
        $stderr.puts "[CrawlManager] Too many consecutive errors (#{consecutive_errors}) for #{domain}"
        $stderr.puts "[CrawlManager] HUMAN INTERVENTION NEEDED — call POST /CrawlManager/#{domain}/resume to continue"
        do_pause(domain, 'errors')
        # After resume, reset consecutive errors
        Restate.set('consecutive_errors', 0)
      end

      # Check max pages
      break if pages_crawled >= max_pages
    end

    # Mark completed
    CrawlState.call(domain).set_status('completed').await
    pages_crawled = Restate.get('pages_crawled') || 0
    $stderr.puts "[CrawlManager] Crawl of #{domain} completed — #{pages_crawled} pages crawled"

    build_summary
  end

  # --- Shared handlers (run concurrently with the exclusive start handler) ---

  shared def pause(_input)
    CrawlState.call(Restate.key).request_pause(nil).await
    { 'message' => "Pause requested for #{Restate.key}" }
  end

  shared def resume(_input)
    awakeable_id = CrawlState.call(Restate.key).get_awakeable_id(nil).await
    if awakeable_id.nil?
      return { 'error' => 'No active pause to resume — crawl may not be paused' }
    end

    Restate.resolve_awakeable(awakeable_id, 'resumed')
    { 'message' => "Resumed crawl for #{Restate.key}" }
  end

  shared def status(_input)
    control = CrawlState.call(Restate.key).get_status(nil).await
    pages_crawled = Restate.get('pages_crawled') || 0
    queue = Restate.get('queue') || []
    errors = Restate.get('errors') || []
    config = Restate.get('config') || {}

    {
      'domain' => Restate.key,
      'status' => control['status'],
      'pause_requested' => control['pause_requested'],
      'pages_crawled' => pages_crawled,
      'queue_size' => queue.size,
      'error_count' => errors.size,
      'consecutive_errors' => Restate.get('consecutive_errors') || 0,
      'max_pages' => config['max_pages'],
      'start_time' => Restate.get('start_time')
    }
  end

  shared def results(_input)
    results_list = Restate.get('results') || []
    site_keywords = Restate.get('site_keywords') || {}

    # Sort site keywords by frequency, take top 30
    top_keywords = site_keywords.sort_by { |_, count| -count }.first(30).to_h

    {
      'domain' => Restate.key,
      'pages_crawled' => Restate.get('pages_crawled') || 0,
      'results' => results_list,
      'site_keywords' => top_keywords,
      'errors' => Restate.get('errors') || []
    }
  end

  private

  def do_pause(domain, reason)
    awakeable_id, future = Restate.awakeable
    CrawlState.call(domain).set_paused({
      'awakeable_id' => awakeable_id,
      'reason' => reason
    }).await

    # Block until someone calls resume
    future.await

    # We're back — mark as running
    CrawlState.call(domain).set_resumed(nil).await
    $stderr.puts "[CrawlManager] Crawl of #{domain} resumed"
  end

  def build_summary
    results_list = Restate.get('results') || []
    site_keywords = Restate.get('site_keywords') || {}
    top_keywords = site_keywords.sort_by { |_, count| -count }.first(30).to_h

    {
      'domain' => Restate.key,
      'pages_crawled' => Restate.get('pages_crawled') || 0,
      'top_keywords' => top_keywords,
      'start_time' => Restate.get('start_time'),
      'page_titles' => results_list.map { |r| r['title'] }.compact
    }
  end
end
