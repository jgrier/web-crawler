# frozen_string_literal: true

require 'restate'

class RateLimiter < Restate::VirtualObject
  # Token bucket rate limiter. Keyed by domain.
  # Serializes access via exclusive handler — callers queue up
  # and are spaced out by durable sleep when tokens are exhausted.

  DEFAULT_MAX_TOKENS = 5.0
  DEFAULT_REFILL_RATE = 2.0 # tokens per second

  handler def acquire(_input)
    max_tokens = Restate.get('max_tokens') || DEFAULT_MAX_TOKENS
    refill_rate = Restate.get('refill_rate') || DEFAULT_REFILL_RATE

    now = Restate.run_sync('now') { Time.now.to_f }

    last_refill = Restate.get('last_refill') || now
    tokens = Restate.get('tokens') || max_tokens

    # Refill tokens based on elapsed time
    elapsed = now - last_refill
    tokens = [tokens + elapsed * refill_rate, max_tokens].min

    if tokens >= 1.0
      tokens -= 1.0
      Restate.set('tokens', tokens)
      Restate.set('last_refill', now)
      return nil
    end

    # Not enough tokens — sleep until one is available
    wait_time = (1.0 - tokens) / refill_rate
    Restate.set('tokens', 0.0)
    Restate.set('last_refill', now + wait_time)
    Restate.sleep(wait_time).await
    nil
  end

  handler def configure(config)
    Restate.set('max_tokens', config['max_tokens'].to_f) if config['max_tokens']
    Restate.set('refill_rate', config['refill_rate'].to_f) if config['refill_rate']
    nil
  end
end
