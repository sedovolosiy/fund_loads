#!/usr/bin/env ruby
require "json"
require_relative "../lib/load_processor"

# Get the input file name from arguments or read from STDIN
input = ARGV[0] || $stdin

processor = LoadProcessor.new

# Read JSON events line by line and output the processing result
File.foreach(input) do |line|
  result = processor.process_line(line)
  puts JSON.generate(result)
end
