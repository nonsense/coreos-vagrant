#!/bin/sh

hosts="core-01.redis-1.docker core-02.redis-1.docker core-03.redis-1.docker"

while ! read -t 0 abort; do
	master=${hosts##* }
	slaves=${hosts% *}
	hosts="$master $slaves"

	echo "Let's make ${master} master and ${slaves} slaves..."

	slave1=${slaves% *}
	slave2=${slaves#* }

	cat > topology.json <<EOF
{
  "master": {
    "address": "${master}"
  },
  "slaves": [
    {
      "address": "${slave1}"
    },
    {
      "address": "${slave2}"
    }
  ]
}
EOF

	./define-topology.sh
	./apply-topology.sh

        echo
        echo $(date) Press ENTER to stop messing with the cluster
        echo
done
