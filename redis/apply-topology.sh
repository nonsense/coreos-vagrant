#!/bin/sh -e

echo Topology:
cat topology.json
echo

echo Applying topology...
o=$(curl -L http://172.17.8.101:4001/v2/keys/config/redis-1/topology -XPUT --data-urlencode value@topology.json 2>&1)
if [ $? != 0 ]; then
	echo Could not set topology 1>&2
	echo "$o" 1>&2
	exit 1
fi

echo Done.
