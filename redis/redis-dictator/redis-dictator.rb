require_relative './lib'

if ARGV.size < 2
  $stderr.puts "usage: select-master.rb master[:port] slave[:port] ..."
  exit(1)
end

services = ARGV.map do |a|
  host, port = a.split(':')
  port = port ? port.to_i : 6379
  {host: host, port: port}
end
master = services.first

group = RedisGroup.new(services: services)
group.dictate_master(service: master)
