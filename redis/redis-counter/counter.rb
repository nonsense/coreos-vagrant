require 'resolv'
require 'securerandom'

require 'rubygems'
require 'redis'

def get_redis
  resolv = Resolv::DNS.new(nameserver: %{172.17.8.101 172.17.8.102 172.17.8.103}, search: ["docker"])
  service = 'master.redis-1'
  master = resolv.getresource(service, Resolv::DNS::Resource::IN::SRV)
  c = {host: resolv.getaddress(master.target).to_s, port: master.port}
  Redis.new(c).tap { |x| x.info }
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
