#!/bin/sh

curl -L http://172.17.8.101:4001/v2/keys/config/redis-1/topology -XPUT --data-urlencode value@topology.json
