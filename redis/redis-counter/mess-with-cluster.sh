#!/bin/sh

while ! read -t 0 abort; do
	for i in 1 2 3; do
	       	ruby select-master.rb node-$i
		echo
		echo $(date) Press ENTER to stop messing with the cluster
		echo
	done
done
