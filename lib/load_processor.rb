require "json"
require "date"
require "prime"

class LoadProcessor
  DAILY_LIMIT_CENTS     = 5_000_00
  WEEKLY_LIMIT_CENTS    = 20_000_00
  MAX_DAILY_COUNT       = 3
  PRIME_ID_LIMIT_CENTS  = 9_999_00

  def initialize
    @state = Hash.new { |h, cid| h[cid] = { daily: {}, weekly: {} } }
    @global_prime_done = {}  # tracks if a prime-ID has been processed each date
    @seen_ids = {}           # tracks processed load IDs to ignore duplicates
  end

  # Processes a JSON line and returns a hash: { "id", "customer_id", "accepted" }
  # On any parsing or data error, returns accepted: false (without raising)
  def process_line(line)
    result = { "id" => nil, "customer_id" => nil, "accepted" => false }

    begin
      attempt = JSON.parse(line)
      load_id = attempt.fetch("id").to_s
      cid     = attempt.fetch("customer_id").to_s
      amount_cents = parse_amount(attempt.fetch("load_amount"))
      time         = DateTime.parse(attempt.fetch("time"))
    rescue JSON::ParserError, ArgumentError, TypeError, KeyError
      # Invalid JSON, missing keys, or bad formats => reject
      return result
    end

    result["id"] = load_id
    result["customer_id"] = cid

    # Return previous result for duplicate IDs
    if @seen_ids.key?(load_id)
      return @seen_ids[load_id]
    end

    date       = time.to_date
    week_key   = [date.cwyear, date.cweek]
    is_monday  = time.monday?
    is_prime   = load_id.match?(/^\d+$/) && Prime.prime?(load_id.to_i)
    monday_tag = is_monday && (is_prime || load_id.start_with?("mon_"))

    daily_amount  = monday_tag ? amount_cents * 2 : amount_cents
    weekly_amount = monday_tag ? amount_cents * 2 : amount_cents

    cust      = @state[cid]
    day_state = cust[:daily].fetch(date, { sum: 0, count: 0 })
    week_sum  = cust[:weekly].fetch(week_key, 0)
    prime_done = @global_prime_done[date]

    # Prime-ID logic
    if is_prime
      if !prime_done && weekly_amount <= PRIME_ID_LIMIT_CENTS
        accept_load(cust, date, week_key, day_state, daily_amount, weekly_amount)
        @global_prime_done[date] = true
        result["accepted"] = true
      end
    else
      # Regular load logic
      if can_accept_regular?(day_state, daily_amount, week_sum, weekly_amount)
        accept_load(cust, date, week_key, day_state, daily_amount, weekly_amount)
        result["accepted"] = true
      end
    end

    @seen_ids[load_id] = result
    result
  end

  private

  def parse_amount(amount_str)
    (amount_str.delete('$ ').to_f * 100).to_i
  end

  def can_accept_regular?(day_state, daily_amount, week_sum, weekly_amount)
    day_state[:count] + 1 <= MAX_DAILY_COUNT &&
      day_state[:sum] + daily_amount <= DAILY_LIMIT_CENTS &&
      week_sum + weekly_amount <= WEEKLY_LIMIT_CENTS
  end

  def accept_load(cust, date, week_key, day_state, daily_amount, weekly_amount)
    day_state[:sum]   += daily_amount
    day_state[:count] += 1
    cust[:daily][date]      = day_state
    cust[:weekly][week_key] = cust[:weekly].fetch(week_key, 0) + weekly_amount
  end
end
