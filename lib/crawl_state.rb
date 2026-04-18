# frozen_string_literal: true

require 'restate'

class CrawlState < Restate::VirtualObject
  # Minimal control-plane state for pause/resume signaling.
  # Only stores what must be writable from shared handlers
  # while the CrawlManager's exclusive start handler runs.
  #
  # State:
  #   status        - "idle", "running", "paused", "error_paused", "completed"
  #   pause_requested - boolean flag set by external pause request
  #   awakeable_id  - stored when paused, used by resume to unblock the crawl

  ingress_private

  handler def request_pause(_input)
    Restate.set('pause_requested', true)
    { 'ok' => true }
  end

  handler def set_paused(data)
    status = data['reason'] == 'errors' ? 'error_paused' : 'paused'
    Restate.set('status', status)
    Restate.set('awakeable_id', data['awakeable_id'])
    Restate.set('pause_requested', false)
    { 'ok' => true }
  end

  handler def set_resumed(_input)
    Restate.set('status', 'running')
    Restate.clear('awakeable_id')
    { 'ok' => true }
  end

  handler def set_status(status)
    Restate.set('status', status)
    { 'ok' => true }
  end

  shared def get_status(_input)
    {
      'status' => Restate.get('status') || 'idle',
      'pause_requested' => Restate.get('pause_requested') || false,
      'has_awakeable' => !Restate.get('awakeable_id').nil?
    }
  end

  shared def is_pause_requested(_input)
    Restate.get('pause_requested') || false
  end

  shared def get_awakeable_id(_input)
    Restate.get('awakeable_id')
  end
end
