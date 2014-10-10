#!/usr/bin/env ruby

require 'rubygems'
require 'rack'
require 'json'

require_relative './lib'

class RedisDictatorRackApp
  def call(env)
    req = Rack::Request.new(env)
    if req.path == "/master"
      if req.put?
        master(req)
      else
        [405, {'Content-Type' => 'text/plain'}, ["Method Not Allowed\n"]]
      end
    else
      [404, {'Content-Type' => 'text/plain'}, ["Object Not Found\n"]]
    end
  end

  private

    def master(req)
      begin
        body = JSON.parse(req.body.read)
        master = {host: body["master"]["address"], port: body["master"]["port"]}
        slaves = body["slaves"].inject([]) { |acc, s| acc << {host: s["address"], port: s["port"] } }
        all = slaves.unshift(master)
        begin
          rg = RedisGroup.new(services: all)
          rg.dictate_master(service: master)
          [200, {'Content-Type' => 'text/plain'}, ["OK\n"]]
        rescue Exception => e
          $stderr.puts "#{e.class}: #{e.message}\n\t#{e.backtrace.join("\n\t")}"
          [500, {'Content-Type' => 'text/plain'}, ["#{e.class}: #{e.message}\n\t#{e.backtrace.join("\n\t")}"]]
        end
      rescue Exception => e
        $stderr.puts "#{e.class}: #{e.message}\n\t#{e.backtrace.join("\n\t")}"
        [400, {'Content-Type' => 'text/plain'}, ["#{e.class}: #{e.message}\n"]]
      end
    end
end

Rack::Handler::WEBrick.run(RedisDictatorRackApp.new, :Port => 8080)
