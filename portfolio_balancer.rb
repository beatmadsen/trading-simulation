require 'bigdecimal'
require 'bigdecimal/util'
require 'distribution'

KEYS = %i[sek btc usd goog].freeze

INITIAL_AMOUNTS = {
  sek: 10_000.to_d,
  usd: 1000.to_d,
  btc: 0.2.to_d,
  goog: 1.to_d
}.freeze

INITIAL_RATES_SEK = {
  sek: 1.to_d,
  usd: 8.04.to_d,
  btc: 90_594.66.to_d,
  goog: 1137.51.to_d * 8.04
}.freeze

class MovingAverage
  def initialize(period)
    @period = period
    @n = 0
    @total = 0.to_d
  end

  def append(value)
    if @n >= @period
      @total = ((@total / @period) * (@period - 1) + value).round(10)
    else
      @n += 1
      @total += value
    end
  end

  def current_value
    @total / @n
  end
end

# daily std dev of rate relative to 90 days rolling mean price
RATES_STD_DEV = {
  sek: 0.to_d,
  usd: 0.005.to_d,
  btc: 0.07.to_d,
  goog: 0.01.to_d
}.freeze

GROWTH_YOY = {
  sek: 1.to_d,
  usd: 1.to_d,
  btc: 3.2.to_d, # https://www.reddit.com/r/Bitcoin/comments/76bctp/bitcoin_price_history_growing_by_a_factor_of_32/
  goog: 1.05.to_d
}.freeze

def find_proportions(amounts: INITIAL_AMOUNTS, rates: INITIAL_RATES_SEK)
  sek_values = KEYS.map { |key| [key, amounts[key] * rates[key]] }
  total = sek_values.sum { |(_key, value)| value }

  sek_values.each_with_object({}) do |(key, value), acc|
    acc[key] = value / total
  end
end

PROPORTIONS = find_proportions.freeze

puts "Proportions: #{PROPORTIONS}"

def random(lower_bound, upper_bound)
  rand(lower_bound.to_f.next_float...upper_bound)
end

def display_hash(amounts)
  amounts.merge(amounts) { |_k, v1, _v2| display_decimal(v1) }
end

def display_decimal(value)
  if value > 0 && value < 0.01 || value < 0 && value > -0.01
    format('%.5f', value.truncate(5))
  else
    format('%.2f', value.truncate(2))
  end
end

# State machine that triggers shock at random time
class ShockGenerator
  def initialize(interval_mean:, interval_std_dev:)
    @rng = Distribution::Normal.rng(interval_mean, interval_std_dev)
    @days_until_next = @rng.call
    @state = :normal
  end

  # advance state by one day
  def advance
    if @days_until_next <= 0
      @state = :shock
      @days_until_next = @rng.call
    else
      @state = :normal
      @days_until_next -= 1
    end
  end

  def shock?
    @state == :shock
  end
end

class NoShockGenerator
  def advance; end

  def shock?
    false
  end
end

# key -> (mean, std_dev)
SHOCK_INTERVALS_DAYS = {
  sek: [0, 0],
  usd: [250, 60],
  goog: [100, 20],
  btc: [180, 60]
}.freeze

n = 0
amounts = INITIAL_AMOUNTS.dup
rates = INITIAL_RATES_SEK.dup
daily_growth = GROWTH_YOY.merge(GROWTH_YOY) do |_k, v1, _v2|
  v1**(1.to_d / 365)
end
rngs = RATES_STD_DEV.map do |k, v|
  [k, Distribution::Normal.rng(0, v)]
end.to_h

shock_rngs = RATES_STD_DEV.map do |k, v|
  [k, Distribution::Normal.rng(0, 10 * v)]
end.to_h

rate_moving_averages = KEYS.map do |key|
  ma = MovingAverage.new(90)
  ma.append(INITIAL_RATES_SEK[key])
  [key, ma]
end.to_h

ideal_values = INITIAL_RATES_SEK.dup
shock_generators = SHOCK_INTERVALS_DAYS.map do |key, (mean, std_dev)|
  next [key, NoShockGenerator.new] if mean == 0 && std_dev == 0
  [key, ShockGenerator.new(interval_mean: mean, interval_std_dev: std_dev)]
end.to_h

loop do
  puts "\n\nstart of day #{n += 1} balance: #{display_hash(amounts)}"

  # STEP 1: market movements to rates
  KEYS.each do |key|
    # 1.1: find ideal value according to long term trend
    ideal_value = (ideal_values[key] *= daily_growth[key])

    # 1.2: calculate new rate t1 based on gaussian with mean=t0 and std dev by key
    sg = shock_generators[key]
    sg.advance

    t0 = rates[key]

    # 10x std dev when a shock happens
    s = if sg.shock?
          puts "SHOCK to rate of #{key}!!!"
          shock_rngs[key].call
        else
          rngs[key].call
        end

    m = rate_moving_averages[key].current_value
    # puts "Key: #{key} | Rel std dev: #{s} | Mean 90: #{display_decimal(m)}"
    t1 = t0 + m * s
    t1 = 0.01.to_d if t1 <= 0

    # 1.3: let actual rate close in on ideal value
    adjustment_rate = 0.01.to_d

    t1 = t1 > ideal_value ?
      t1 - adjustment_rate * (t1 - ideal_value) :
      t1 + adjustment_rate * (ideal_value - t1)

    t1 = t1.round(10)

    rates[key] = t1
    rate_moving_averages[key].append(t1)
  end

  puts "market movements done, new rates: #{display_hash(rates)}"

  total_value = KEYS.sum { |key| rates[key] * amounts[key] }
  initial_amounts_new_value = KEYS.sum { |key| rates[key] * INITIAL_AMOUNTS[key] }
  trading_effect = (total_value / initial_amounts_new_value) - 1
  puts "Total value: #{display_decimal(total_value)} | " \
       "If no trading had happened: #{display_decimal(initial_amounts_new_value)} | " \
       "Trading effect: #{display_decimal(trading_effect)}"

  sek_growth = amounts[:sek] / INITIAL_AMOUNTS[:sek]
  puts "SEK growth: #{display_decimal(sek_growth)}"

  # STEP 2: re-balance according to proportions
  # (assuming zero transaction costs)
  KEYS.each do |key|
    new_amount = total_value * (PROPORTIONS[key] / rates[key])
    # puts "Total value: #{display_decimal(total_value)} | New amount: #{display_decimal(new_amount)}"
    amounts[key] = new_amount.round(10)
  end
end
