require "spec_helper"
require_relative "../lib/load_processor"
require "json"

RSpec.describe LoadProcessor do
  let(:proc) { LoadProcessor.new }

  def run(attempt)
    line = JSON.generate(attempt)
    JSON.parse(proc.process_line(line).to_json)
  end

  it "accepts a load within the daily limit" do
    res = run({ "id" => "1", "customer_id" => "10", "load_amount" => "$1000.00", "time" => "2025-05-01T10:00:00Z" })
    expect(res["accepted"]).to be true
  end

  it "rejects a load exceeding the daily limit" do
    2.times do
      run({ "id" => "x", "customer_id" => "20", "load_amount" => "$3000.00", "time" => "2025-05-01T09:00:00Z" })
    end
    res = run({ "id" => "y", "customer_id" => "20", "load_amount" => "$3000.00", "time" => "2025-05-01T17:00:00Z" })
    expect(res["accepted"]).to be false
  end

  it "limits load attempts to three per day" do
    3.times do |i|
      run({ "id" => i.to_s, "customer_id" => "30", "load_amount" => "$10.00", "time" => "2025-05-02T0#{i}:00:00Z" })
    end
    res = run({ "id" => "4", "customer_id" => "30", "load_amount" => "$10.00", "time" => "2025-05-02T13:00:00Z" })
    expect(res["accepted"]).to be false
  end

  it "rejects a load exceeding the weekly limit" do
    4.times do |i|
      run({ "id" => "w#{i}", "customer_id" => "40", "load_amount" => "$4500.00", "time" => "2025-05-0#{5+i}T10:00:00Z" })
    end
    res = run({ "id" => "w4", "customer_id" => "40", "load_amount" => "$2500.00", "time" => "2025-05-09T11:00:00Z" })
    expect(res["accepted"]).to be false
  end

  it "accepts loads exactly hitting the daily limit" do
    run({ "id" => "d1", "customer_id" => "50", "load_amount" => "$2000.00", "time" => "2025-05-12T10:00:00Z" })
    res = run({ "id" => "d2", "customer_id" => "50", "load_amount" => "$3000.00", "time" => "2025-05-12T11:00:00Z" })
    expect(res["accepted"]).to be true
    res3 = run({ "id" => "d3", "customer_id" => "50", "load_amount" => "$1.00", "time" => "2025-05-12T12:00:00Z" })
    expect(res3["accepted"]).to be false
  end

  it "accepts loads exactly hitting the weekly limit" do
    %w[2025-05-13 2025-05-14 2025-05-15 2025-05-16].each_with_index do |date, i|
      res = run({ "id" => "wk#{i}", "customer_id" => "60", "load_amount" => "$5000.00", "time" => "#{date}T10:00:00Z" })
      expect(res["accepted"]).to be true
    end
    res_fail = run({ "id" => "wk4", "customer_id" => "60", "load_amount" => "$1.00", "time" => "2025-05-17T11:00:00Z" })
    expect(res_fail["accepted"]).to be false
    res_next_week = run({ "id" => "wk5", "customer_id" => "60", "load_amount" => "$1.00", "time" => "2025-05-19T10:00:00Z" })
    expect(res_next_week["accepted"]).to be true
  end

  it "resets daily limits correctly across midnight UTC" do
    run({ "id" => "m1", "customer_id" => "70", "load_amount" => "$4000.00", "time" => "2025-05-13T23:59:00Z" })
    res = run({ "id" => "m2", "customer_id" => "70", "load_amount" => "$4000.00", "time" => "2025-05-14T00:01:00Z" })
    expect(res["accepted"]).to be true
  end

  it "accepts a zero amount load if daily count allows" do
    run({ "id" => "z1", "customer_id" => "80", "load_amount" => "$10.00", "time" => "2025-05-15T10:00:00Z" })
    run({ "id" => "z2", "customer_id" => "80", "load_amount" => "$10.00", "time" => "2025-05-15T11:00:00Z" })
    res = run({ "id" => "z3", "customer_id" => "80", "load_amount" => "$0.00", "time" => "2025-05-15T12:00:00Z" })
    expect(res["accepted"]).to be true
    res4 = run({ "id" => "z4", "customer_id" => "80", "load_amount" => "$0.00", "time" => "2025-05-15T13:00:00Z" })
    expect(res4["accepted"]).to be false
  end

  it "ignores duplicate load attempts based on id" do
    res1 = run({ "id" => "dup1", "customer_id" => "90", "load_amount" => "$1000.00", "time" => "2025-05-16T10:00:00Z" })
    expect(res1["accepted"]).to be true
    res2 = run({ "id" => "dup1", "customer_id" => "90", "load_amount" => "$1000.00", "time" => "2025-05-16T11:00:00Z" })
    expect(res2["accepted"]).to be true
    res3 = run({ "id" => "dup2", "customer_id" => "90", "load_amount" => "$3500.00", "time" => "2025-05-16T12:00:00Z" })
    expect(res3["accepted"]).to be true
  end

  context "with extra credit rules" do
    it "rejects a prime ID load exceeding the $9,999 limit" do
      res = run({ "id" => "17", "customer_id" => "200", "load_amount" => "$10000.00", "time" => "2025-05-19T10:00:00Z" })
      expect(res["accepted"]).to be false
    end

    it "accepts the first prime ID load within limits" do
      res = run({ "id" => "19", "customer_id" => "201", "load_amount" => "$9999.00", "time" => "2025-05-20T10:00:00Z" })
      expect(res["accepted"]).to be true
    end

    it "rejects the second prime ID load on the same day" do
      run({ "id" => "23", "customer_id" => "202", "load_amount" => "$100.00", "time" => "2025-05-21T10:00:00Z" })
      res = run({ "id" => "29", "customer_id" => "203", "load_amount" => "$100.00", "time" => "2025-05-21T11:00:00Z" })
      expect(res["accepted"]).to be false
    end

    it "accepts a prime ID load on the next day after one was processed" do
      run({ "id" => "31", "customer_id" => "204", "load_amount" => "$100.00", "time" => "2025-05-22T10:00:00Z" })
      res = run({ "id" => "37", "customer_id" => "205", "load_amount" => "$100.00", "time" => "2025-05-23T10:00:00Z" })
      expect(res["accepted"]).to be true
    end

    it "counts Monday loads as double towards the daily limit" do
      res1 = run({ "id" => "mon_d1", "customer_id" => "210", "load_amount" => "$2500.00", "time" => "2025-05-12T10:00:00Z" })
      expect(res1["accepted"]).to be true
      res2 = run({ "id" => "mon_d2", "customer_id" => "210", "load_amount" => "$1.00", "time" => "2025-05-12T11:00:00Z" })
      expect(res2["accepted"]).to be false
      res3 = run({ "id" => "mon_d3", "customer_id" => "211", "load_amount" => "$2500.01", "time" => "2025-05-12T12:00:00Z" })
      expect(res3["accepted"]).to be false
    end

    it "applies both Prime ID and Monday rules correctly" do
      res1 = run({ "id" => "17", "customer_id" => "230", "load_amount" => "$5000.00", "time" => "2025-05-19T10:00:00Z" })
      expect(res1["accepted"]).to be false
      res2 = run({ "id" => "19", "customer_id" => "231", "load_amount" => "$4999.00", "time" => "2025-05-19T11:00:00Z" })
      expect(res2["accepted"]).to be true
      res3 = run({ "id" => "23", "customer_id" => "232", "load_amount" => "$1.00", "time" => "2025-05-19T12:00:00Z" })
      expect(res3["accepted"]).to be false
    end
  end
end