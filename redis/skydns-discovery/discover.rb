#!/usr/bin/env ruby

require 'getoptlong'

require 'rubygems'
require 'net/dns'

opts = GetoptLong.new(
  [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
  [ '--nameservers', '-n', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--search', '-s', GetoptLong::REQUIRED_ARGUMENT ],
)

resolver = Net::DNS::Resolver.new

opts.each do |opt, arg|
  case opt
  when '--help'
    puts <<-EOF
usage: discover.rb [OPTION ...] NAME ...
-h, --help:

    show help

--nameservers x, -n x:

    specify comma-separated list of name servers

--search x, -n x:

    specify comma-separated list of search domains

NAME:

    hostname to use in discovery
    EOF
  when '--nameservers'
    resolver.nameservers = arg.split(',')
  when '--search'
    resolver.searchlist = arg.split(',')
  end
end

if ARGV.size < 1
  puts "Missing NAME (try --help)"
  exit 1
end

ARGV.each do |name|
  search = resolver.search(name, Net::DNS::SRV)
  p search.elements
end
