#!/bin/sh

if [ $# -lt 2 ]; then
	echo usage: ./mess-with-cluster.sh host:port host:port ... 1>&2
	exit 1
fi
hosts="$*"

while ! read -t 0 abort; do
	echo ruby select-master.rb $hosts
	ruby select-master.rb $hosts

	master=${hosts##* }
	slaves=${hosts% *}
	hosts="$master $slaves"

        echo
        echo $(date) Press ENTER to stop messing with the cluster
        echo
done
