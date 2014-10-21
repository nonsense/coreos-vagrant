#!/bin/sh -e

master=master.redis-1.docker

addr=$(host -t a $master 172.17.8.101 | awk '$3 == "address" {print $4}')
port=$(host -t srv $master 172.17.8.101 | awk '$3 == "SRV" {print $7}')

echo Connecting to $master at $addr:$port...
redis-cli -h $addr -p $port
