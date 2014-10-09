require 'rubygems'
require 'securerandom'
require 'redis'
require 'net/dns'

HARDCODED_DOMAIN = "docker"
IMPOSSIBLY_HUGE_NUMBER_OF_SLAVES = 1_000_000
SELECT_MASTER_CHANNEL = 'select-master'

class RedisInstance

  attr_reader :host, :port

  def initialize(host: nil, port: nil)
    @host, @port = host, port
  end

  def master!
    redis.slaveof('no', 'one')
  end

  def slave!(master)
    redis.slaveof(master.host, master.port)
    wait_until_slaved_to(master)
  end

  def to_s
    {host: @host, port: @port, master: master}.to_s
  end

  def master?
    redis.info['role'] == 'master'
  end

  def send_message(message)
    redis.publish(SELECT_MASTER_CHANNEL, message)
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
    loop do
      slaves = get_slaves
      if slaves.empty?
        puts "WARNING: master with no online slaves #{self}"
        break
      end
      break if slaves.all? { |s| s.repl_offset == repl_offset }
      puts "waiting for slaves to reach offset #{repl_offset}"
      slaves.each { |s| puts "\t#{s} offset #{s.repl_offset}" }
      sleep 0.1
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

    def wait_until_slaved_to(master)
      connected = false
      message = "#{host}:#{port} seeks #{master.host}:#{master.port}"
      receiver = Thread.new do
        wait_for_message(message)
        connected = true
      end
      receiver.abort_on_exception = true
      loop do
        master.send_message(message)
        sleep 0.1
        break if connected
      end
      receiver.join
    end

    def wait_for_message(message)
      myself = to_s
      redis.subscribe(SELECT_MASTER_CHANNEL) do |on|
        on.message do |chn, msg|
          redis.unsubscribe(SELECT_MASTER_CHANNEL) if msg == message
        end
      end
    end

    def get_slaves
      info = redis.info
      slave_ids = info.keys.select { |k| k =~ /^slave\d+$/ }
      slave_states = slave_ids.inject([]) { |m, i| m << info[i] }
      slave_states.inject([]) do |m, s|
        s =~ /ip=([^,]+),port=(\d+),state=[^.]+,offset=(\d+)/ or next
        m << RedisSlave.new(host: $1, port: $2.to_i, repl_offset: $3.to_i)
      end || []
    end

    class RedisSlave
      attr_reader :host, :port, :repl_offset
      def initialize(host: nil, port: nil, repl_offset: nil)
        @host, @port, @repl_offset = host, port, repl_offset
      end
      def to_s
        {host: @host, port: @port, offset: @repl_offset}.to_s
      end
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
  r.rewrite_config!
end

puts "waiting for #{master} to flush to its slaves"
master.flush!

redises.each do |r|
  puts "making #{r} accept_client_writes"
  r.allow_client_writes!
  r.rewrite_config!
end

puts "done"
