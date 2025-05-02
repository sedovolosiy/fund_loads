# Fund Loads Processor

A simple Ruby script for processing fund loading attempts according to these rules:  
- **Daily limit:** $5,000  
- **Weekly limit:** $20,000  
- **Maximum:** 3 loading attempts per day

## Installation

```
cd fund_loads
bundle install
```

## Usage

```
ruby bin/process_loads.rb input.txt > output.txt
```

## Input Format

The input should contain JSON objects, one per line, with the following structure:

```
{"id":"12345","customer_id":"1001","load_amount":"$4000.00","time":"2000-01-01T00:00:00Z"}
```

## Output Format

The output will be JSON objects, one per line, with the following fields:

```
{"id":"12345","customer_id":"1001","accepted":true}
```

## Running Tests

```
rake spec
```

## Project Structure

- `process_loads.rb` – Entry point script  
- `load_processor.rb` – Core processing logic  
- `spec/` – Test files
