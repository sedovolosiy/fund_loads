#!/usr/bin/env ruby
require "json"
require_relative "../lib/load_processor"

# Get the input file name from arguments or read from STDIN
input = ARGV[0] || $stdin

processor = LoadProcessor.new

start_time = Time.now

# Read JSON events line by line and output the processing result
File.foreach(input) do |line|
  result = processor.process_line(line)
  puts JSON.generate(result)
end

# Output performance metrics to STDERR so they don't go into the output file
$stderr.puts "\n======= Performance Metrics ======="
$stderr.puts "Total time: #{Time.now - start_time} seconds"

metrics = processor.metrics
metrics.each do |key, value|
  formatted_value = value.is_a?(Float) ? value.round(6) : value
  $stderr.puts "#{key}: #{formatted_value}"
end
$stderr.puts "=================================="
