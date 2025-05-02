require "json"
require "date"
require "prime"
require "benchmark"
require "lru_redux"

class LoadProcessor
  DAILY_LIMIT_CENTS     = 5_000_00
  WEEKLY_LIMIT_CENTS    = 20_000_00
  MAX_DAILY_COUNT       = 3
  PRIME_ID_LIMIT_CENTS  = 9_999_00
  MAX_PRIME_CHECK       = 10_000_000  # Limit for detailed prime checks
  CACHE_MAX_SIZE        = 10_000      # Maximum size for LRU caches
  
  # Small primes for quick checking
  SMALL_PRIMES = Prime.each(10_000).to_a.freeze

  def initialize(options = {})
    @state = Hash.new { |h, cid| h[cid] = { daily: {}, weekly: {} } }
    @global_prime_done = {}  # tracks if a prime-ID has been processed each date
    
    # Use LRU cache for seen IDs to prevent unbounded growth
    @seen_ids = LruRedux::Cache.new(options[:cache_size] || CACHE_MAX_SIZE)
    
    # Pre-compute prime cache for small numbers
    @prime_cache = SMALL_PRIMES.each_with_object({}) { |p, h| h[p] = true }
    
    # Performance metrics
    @metrics = { 
      total_processed: 0,
      total_accepted: 0, 
      prime_checks: 0,
      processing_time: 0
    }
  end

  # Batch processing method - prepare for future parallelization
  def process_batch(lines, batch_size = 1000)
    results = []
    lines.each_slice(batch_size) do |batch|
      batch_results = batch.map { |line| process_line(line) }
      results.concat(batch_results)
    end
    results
  end

  # Processes a JSON line and returns a hash: { "id", "customer_id", "accepted" }
  # On any parsing or data error, returns accepted: false (without raising)
  def process_line(line)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    
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
    is_prime   = is_prime?(load_id)
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
    
    # Update metrics
    @metrics[:total_processed] += 1
    @metrics[:total_accepted] += 1 if result["accepted"]
    @metrics[:processing_time] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    
    result
  end

  # Returns current performance metrics
  def metrics
    @metrics.merge({
      avg_processing_time: @metrics[:total_processed] > 0 ? 
                           @metrics[:processing_time] / @metrics[:total_processed] : 0,
      acceptance_rate: @metrics[:total_processed] > 0 ? 
                      (@metrics[:total_accepted].to_f / @metrics[:total_processed]) * 100 : 0
    })
  end
  
  # Memory usage cleanup - call periodically for long-running processes
  def cleanup_old_records(days_to_keep = 30)
    cutoff_date = Date.today - days_to_keep
    
    # Clean up old customer daily records
    @state.each do |_, cust_state|
      cust_state[:daily].delete_if { |date, _| date < cutoff_date }
    end
    
    # Clean up global prime done tracking
    @global_prime_done.delete_if { |date, _| date < cutoff_date }
    
    # Remove empty customer records
    @state.delete_if { |_, cust_state| cust_state[:daily].empty? && cust_state[:weekly].empty? }
  end

  private

  def parse_amount(amount_str)
    (amount_str.delete('$ ').to_f * 100).to_i
  end
  
  # Optimized prime checking with caching
  def is_prime?(load_id)
    return false unless load_id.match?(/^\d+$/)
    
    num = load_id.to_i
    
    # Quick check for small primes using pre-computed cache
    return @prime_cache.key?(num) if num < 10_000
    
    # Quick checks for obvious non-primes
    return false if num < 2 || num.even?
    
    # Use cached result if available
    @metrics[:prime_checks] += 1
    
    # For very large numbers, use faster but less accurate check
    if num > MAX_PRIME_CHECK
      # Miller-Rabin probabilistic test would be implemented here
      # For now fall back to Ruby's Prime
      return Prime.prime?(num)
    end
    
    # Standard prime check for medium-sized numbers
    Prime.prime?(num)
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
