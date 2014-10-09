require 'rubygems'
require 'redis'

class RedisInstance

  IMPOSSIBLY_HUGE_NUMBER_OF_SLAVES = 1_000_000
  SELECT_MASTER_CHANNEL = 'select-master'

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
    {host: @host, port: @port}.to_s
  end

  def master?
    redis.info['role'] == 'master'
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

  protected

    def send_message(message)
      redis.publish(SELECT_MASTER_CHANNEL, message)
    end

  private

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

if ARGV.size < 2
  $stderr.puts "usage: select-master.rb master[:port] slave[:port] ..."
  exit(1)
end

services = ARGV.map do |a|
  host, port = a.split(':')
  port = port ? port.to_i : 6379
  {host: host, port: port}
end

redises = services.map { |s| RedisInstance.new(s) }
master, *slaves = *redises

slaves.each do |r|
  if r.master?
    puts "waiting for #{r} to flush to its slaves"
    r.reject_client_writes!
    r.flush!
  end
end

puts "making #{master} master"
master.master!
master.rewrite_config!

slaves.each do |r|
  puts "enslave #{r}\n     -> #{master}"
  r.slave!(master)
  r.allow_client_writes!
  r.rewrite_config!
end

puts "done"
