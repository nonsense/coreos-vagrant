#!/bin/sh -e

echo Triggering topology change...
o=$(curl -L http://172.17.8.101:4001/v2/keys/config/redis-1/topology-trigger -XPUT -d value=1 2>&1)
if [ $? != 0 ]; then
	echo Could not trigger topology change 1>&2
	echo "$o" 1>&2
	exit 1
fi

echo Done.
