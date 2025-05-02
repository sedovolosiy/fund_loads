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
  def process_line(line)
    attempt = JSON.parse(line)
    load_id = attempt["id"].to_s
    cid     = attempt["customer_id"].to_s

    # Return previous result for duplicate IDs
    if @seen_ids.key?(load_id)
      return @seen_ids[load_id]
    end

    amount_cents = (attempt["load_amount"].delete("$ ").to_f * 100).to_i
    time         = DateTime.parse(attempt["time"])
    date         = time.to_date
    week_key     = [date.cwyear, date.cweek]
    is_monday    = time.monday?
    is_prime_id  = load_id.match?(/^\d+$/) && Prime.prime?(load_id.to_i)

    # Monday loads count double toward limits for prime-ID or IDs starting with "mon_"
    monday_tag = is_monday && (is_prime_id || load_id.start_with?("mon_"))

    # Amounts counted toward limits
    daily_amount  = monday_tag ? amount_cents * 2 : amount_cents
    weekly_amount = monday_tag ? amount_cents * 2 : amount_cents

    cust      = @state[cid]
    day_state = cust[:daily].fetch(date, { sum: 0, count: 0 })
    week_sum  = cust[:weekly].fetch(week_key, 0)
    prime_done = @global_prime_done[date]

    result = { "id" => load_id, "customer_id" => cid, "accepted" => false }

    if is_prime_id
      # Prime-ID rule: only one per day, max effective weekly amount ≤ PRIME_ID_LIMIT_CENTS
      if !prime_done && weekly_amount <= PRIME_ID_LIMIT_CENTS
        result["accepted"] = true
        @global_prime_done[date] = true

        # Record counts
        day_state[:sum]   += daily_amount
        day_state[:count] += 1
        cust[:daily][date]      = day_state
        cust[:weekly][week_key] = week_sum + weekly_amount
      end

    else
      # Regular loads: apply daily count, daily sum, and weekly sum limits
      if day_state[:count] + 1 <= MAX_DAILY_COUNT &&
         day_state[:sum] + daily_amount <= DAILY_LIMIT_CENTS &&
         week_sum + weekly_amount <= WEEKLY_LIMIT_CENTS

        result["accepted"] = true
        day_state[:sum]   += daily_amount
        day_state[:count] += 1
        cust[:daily][date]      = day_state
        cust[:weekly][week_key] = week_sum + weekly_amount
      end
    end

    @seen_ids[load_id] = result
    result
  end
end