# frozen_string_literal: true

require 'nokogiri'
require 'uri'

module ContentAnalyzer
  STOP_WORDS = Set.new(%w[
    a about above after again against all am an and any are aren't as at be
    because been before being below between both but by can't cannot could
    couldn't did didn't do does doesn't doing don't down during each few for
    from further get got had hadn't has hasn't have haven't having he he'd
    he'll he's her here here's hers herself him himself his how how's i i'd
    i'll i'm i've if in into is isn't it it's its itself let's me more most
    mustn't my myself no nor not of off on once only or other ought our ours
    ourselves out over own same shan't she she'd she'll she's should
    shouldn't so some such than that that's the their theirs them themselves
    then there there's these they they'd they'll they're they've this those
    through to too under until up us very was wasn't we we'd we'll we're
    we've were weren't what what's when when's where where's which while who
    who's whom why why's will with won't would wouldn't you you'd you'll
    you're you've your yours yourself yourselves also just like one two three
    new used use using get gets got can will may even still way many make
    made much well back know however see go going come came take took first
    last long great need want look find give day said tell asked old right
    big high end point help try turn start show began found run let began
    might think say work call keep went put set hand set yes www com http
    https html page site web link click home contact read free best next
    view menu search content post blog
  ]).freeze

  def self.analyze(html_string, url, domain)
    doc = Nokogiri::HTML(html_string)

    # Remove script and style elements
    doc.css('script, style, noscript').remove

    title = doc.at_css('title')&.text&.strip || ''
    description = doc.at_css('meta[name="description"]')&.[]('content')&.strip || ''

    headings = doc.css('h1, h2, h3').map { |h| h.text.strip }.reject(&:empty?).first(20)

    # Extract visible text
    body_text = doc.at_css('body')&.text || ''
    # Normalize whitespace
    clean_text = body_text.gsub(/\s+/, ' ').strip

    words = clean_text.downcase.scan(/\b[a-z][a-z']{2,}\b/)
    word_count = words.length

    # Keyword extraction via term frequency
    freq = Hash.new(0)
    words.each { |w| freq[w] += 1 unless STOP_WORDS.include?(w) }
    keywords = freq.sort_by { |_, count| -count }.first(20).to_h

    # Extract same-domain links
    links = extract_links(doc, url, domain)

    {
      'success' => true,
      'url' => url,
      'title' => title,
      'description' => description,
      'headings' => headings,
      'word_count' => word_count,
      'keywords' => keywords,
      'links' => links
    }
  end

  def self.extract_links(doc, page_url, domain)
    base_uri = URI.parse(page_url)
    links = Set.new

    doc.css('a[href]').each do |a|
      href = a['href'].to_s.strip
      next if href.empty? || href.start_with?('#', 'mailto:', 'tel:', 'javascript:')

      begin
        resolved = URI.join(base_uri, href)
        # Same domain only
        next unless resolved.host&.downcase&.end_with?(domain.downcase)
        # HTTP(S) only
        next unless %w[http https].include?(resolved.scheme)

        # Normalize: strip fragment, keep path
        normalized = "#{resolved.scheme}://#{resolved.host}#{resolved.path}"
        # Remove trailing slash for consistency (except root)
        normalized = normalized.chomp('/') unless normalized.end_with?('://')
        links.add(normalized)
      rescue URI::InvalidURIError
        next
      end
    end

    links.to_a.first(100)
  end
end
