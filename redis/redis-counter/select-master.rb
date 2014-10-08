require 'rubygems'
require 'securerandom'
require 'redis'
require 'net/dns'

HARDCODED_DOMAIN = "docker"
IMPOSSIBLY_HUGE_NUMBER_OF_SLAVES = 1_000_000

class RedisInstance

  attr_reader :host, :port

  def initialize(host: nil, port: nil)
    @host, @port = host, port
  end

  def master!
    redis.slaveof('no', 'one')
  end

  def slave!(instance)
    redis.slaveof(instance.host, instance.port)
  end

  def to_s
    {host: @host, port: @port, master: master}.to_s
  end

  def master?
    redis.info['role'] == 'master'
  end

  def master_to?(other)
    master? and get_slaves.detect { |s| s.host == other.host and s.port == other.port }
  end

  def reject_client_writes!
    @min_slaves ||= redis.config('GET', 'min-slaves-to-write')[1]
    redis.config('SET', 'min-slaves-to-write', IMPOSSIBLY_HUGE_NUMBER_OF_SLAVES)
  end

  def allow_client_writes!
    redis.config('SET', 'min-slaves-to-write', @min_slaves)
    @min_slaves = nil
  end

  def flush!
    slaves = get_slaves
    if slaves.empty?
      puts "WARNING: master with no online slaves #{self}"
    else
      loop do
        break unless slaves.detect { |s| s.send(:repl_offset) != repl_offset }
        puts "waiting for slaves to reach offset #{repl_offset}"
        slaves.each { |s| puts "\t#{s} offset #{s.send(:repl_offset)}" }
        sleep 0.1
      end
    end
  end

  def rewrite_config!
    redis.config('REWRITE')
  end

  private

    def master
      info = redis.info
      if info['role'] == 'master'
        'no one'
      else
        info['master_host'] + ' ' + info['master_port']
      end
    end

    def redis
      @_redis ||= Redis.new(host: @host, port: @port)
    end

    def repl_offset
      info = redis.info
      if info['role'] == 'master'
        info['master_repl_offset'].to_i
      else
        info['slave_repl_offset'].to_i
      end
    end

    def get_slaves
      info = redis.info
      slave_ids = info.keys.select { |k| k =~ /^slave\d+$/ }
      slave_states = slave_ids.inject([]) { |m, i| m << info[i] }
      slave_states.inject([]) do |m, s|
        s =~ /ip=([^,]+),port=(\d+),state=online/ or next
        m << RedisInstance.new(host: $1, port: $2.to_i)
      end || []
    end

end

def resolver
  Net::DNS::Resolver.new(searchlist: [HARDCODED_DOMAIN],
                         nameservers: [IPAddr.new("172.17.8.101"), IPAddr.new("172.17.8.102"), IPAddr.new("172.17.8.103")])
end

def lookup_instances
  service = "redis-1"
  resolver.search(service).elements.map { |a| {host: a.value, port: 6379} }
end

def lookup_instance(host)
  service = "redis-1"
  resolver.search("#{host}.#{service}").elements.map { |a| {host: a.value, port: 6379} }.first
end

def find_master(redises)
  redises.detect do |r|
    r.info['role'] == 'master'
  end
end

if ARGV.size != 1
  $stderr.puts "usage: select-master.rb hostname"
  exit(1)
end

hostname = ARGV[0]
master_service = lookup_instance(hostname)
host, port = master_service[:host], master_service[:port]

services = lookup_instances
services.each { |s| puts "discovered redis #{s}" }

redises = services.map { |i| RedisInstance.new(i) }

master = redises.detect { |r| r.host == host and r.port == port } or raise "new master not found"
slaves = redises.reject { |r| r == master }

redises.each do |r|
  puts "making #{r} reject_client_writes"
  r.reject_client_writes!
  r.rewrite_config!
end

redises.each do |r|
  if r.master?
    puts "waiting for #{r} to flush to its slaves"
    r.flush!
  end
end

puts "making #{master} master"
master.master!
master.rewrite_config!

slaves.each do |r|
  puts "enslave #{r}\n     -> #{master}"
  r.slave!(master)
  loop do
    break if master.master_to?(r)
    sleep 0.1
  end
  r.rewrite_config!
end

puts "waiting for #{master} to flush to its slaves"
master.flush!

redises.each do |r|
  r.allow_client_writes!
  r.rewrite_config!
  puts r
end
