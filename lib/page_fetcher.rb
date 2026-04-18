# frozen_string_literal: true

require 'restate'
require 'net/http'
require 'uri'
require_relative 'content_analyzer'
require_relative 'rate_limiter'

class PageFetcher < Restate::VirtualObject
  # Fetches and parses a single page. Keyed by URL.
  # Deduplication is inherent: first fetch caches the processed result,
  # subsequent calls return cached result if within TTL.

  DEFAULT_CACHE_TTL = 86_400 # 24 hours in seconds
  FETCH_TIMEOUT = 15 # seconds

  handler def fetch(request)
    domain = request['domain']
    cache_ttl = request['cache_ttl'] || DEFAULT_CACHE_TTL

    # Check cache — if we've already fetched this URL within TTL, return cached result
    cached = Restate.get('result')
    if cached
      fetched_at = Restate.get('fetched_at')
      now = Restate.run_sync('check-ttl') { Time.now.to_f }
      if fetched_at && (now - fetched_at) < cache_ttl
        return cached
      end
    end

    # Acquire rate limit token (blocks until available)
    RateLimiter.call(domain).acquire(nil).await

    # Simulate errors if configured (for demo)
    if request['simulate_errors'] == true
      result = {
        'success' => false,
        'url' => Restate.key,
        'error' => 'HTTP 403 Forbidden (simulated firewall)',
        'fetched_at' => Restate.run_sync('error-ts') { Time.now.to_f }
      }
      Restate.set('result', result)
      Restate.set('fetched_at', result['fetched_at'])
      return result
    end

    # Fetch and parse the page in a durable side effect
    url = Restate.key
    result = Restate.run_sync('fetch-and-parse', background: true) do
      fetch_and_parse(url, domain)
    end

    # Cache the result
    Restate.set('result', result)
    Restate.set('fetched_at', result['fetched_at'])
    result
  end

  private

  def fetch_and_parse(url, domain)
    uri = URI.parse(url)

    # Reject URLs with missing or empty host — non-retriable
    if uri.host.nil? || uri.host.strip.empty?
      return {
        'success' => false,
        'url' => url,
        'error' => 'Invalid URL: no hostname',
        'fetched_at' => Time.now.to_f
      }
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: FETCH_TIMEOUT,
                                                     read_timeout: FETCH_TIMEOUT) do |http|
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'RestateCrawler/1.0'
      request['Accept'] = 'text/html'
      http.request(request)
    end

    case response.code.to_i
    when 200
      result = ContentAnalyzer.analyze(response.body, url, domain)
      result['fetched_at'] = Time.now.to_f
      result
    when 301, 302, 303, 307, 308
      # Follow redirects — resolve relative Location to absolute URL
      location = response['location']
      resolved_links = []
      if location
        begin
          resolved = URI.join(uri, location)
          resolved_links = [resolved.to_s] if resolved.host && !resolved.host.empty?
        rescue URI::InvalidURIError
          # Skip malformed redirect targets
        end
      end
      {
        'success' => true,
        'url' => url,
        'title' => "Redirect to #{location}",
        'description' => '',
        'headings' => [],
        'word_count' => 0,
        'keywords' => {},
        'links' => resolved_links,
        'fetched_at' => Time.now.to_f
      }
    when 404
      {
        'success' => false,
        'url' => url,
        'error' => 'HTTP 404 Not Found',
        'fetched_at' => Time.now.to_f
      }
    when 403, 401
      {
        'success' => false,
        'url' => url,
        'error' => "HTTP #{response.code} #{response.message}",
        'fetched_at' => Time.now.to_f
      }
    when 429
      {
        'success' => false,
        'url' => url,
        'error' => 'HTTP 429 Too Many Requests',
        'fetched_at' => Time.now.to_f
      }
    else
      {
        'success' => false,
        'url' => url,
        'error' => "HTTP #{response.code} #{response.message}",
        'fetched_at' => Time.now.to_f
      }
    end
  rescue StandardError => e
    {
      'success' => false,
      'url' => url,
      'error' => "#{e.class}: #{e.message}",
      'fetched_at' => Time.now.to_f
    }
  end
end
