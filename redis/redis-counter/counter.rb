require 'rubygems'
require 'redis'
require 'securerandom'
require 'net/dns'

def get_redis
  r = Net::DNS::Resolver.new(searchlist: ["docker"],
                             nameservers: [IPAddr.new("172.17.8.101"), IPAddr.new("172.17.8.102"), IPAddr.new("172.17.8.103")])
  service = 'redis-1'
  candidates = r.search(service).elements.map { |a| {host: a.value, port: 6379} }
  candidates.each do |c|
    r = Redis.new(c)
    if r.info['role'] == 'master'
      return r
    else
      r.quit
    end
  end
  nil
end

redis = get_redis

clear = ENV['COUNTER_CLEAR'] || false
key = ENV['COUNTER_KEY'] || 'debug:counter:stack'
count = ENV['COUNTER_COUNT'].to_i
interval = ENV['COUNTER_INTERVAL'].to_i

redis.del(key) if clear
redis.quit

puts "Okay, start trashing the cluster and then press ENTER"
gets

redis = get_redis

ack = []
err = []
count.times do
  uuid = SecureRandom.uuid
  begin
    raise "not connected" unless redis and redis.connected?
    redis.rpush(key, uuid)
    $stderr.puts "ack #{uuid}"
    ack.push uuid
  rescue Exception => e
    $stderr.puts "err #{uuid}: #{e}"
    err.push uuid
    begin
      $stderr.puts "reconnecting"
      redis.quit if redis and redis.connected?
      redis = get_redis
    rescue Exception
    end
  end
  sleep (interval / 1000.0)
end

puts "Okay, stop trashing the cluster and then press ENTER"
gets

redis = get_redis
persisted = redis.lrange(key, 0, -1)

missing = 0
ack.each do |v|
  if ! persisted.include?(v)
    $stderr.puts "ack'd #{v} missing from persisted set"
    missing += 1
  end
end

phantom = 0
err.each do |v|
  if persisted.include?(v)
    $stderr.puts "err'd #{v} phantom in persisted set"
    phantom += 1
  end
end

$stdout.puts "ack'd: #{ack.size} (#{missing} missing) err'd: #{err.size} (#{phantom} phantom)"
