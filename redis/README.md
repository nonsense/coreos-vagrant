# Safe Redis on CoreOS

This is an example of how redis could be run safely in a CoreOS cluster. This is a challenging undertaking for a few reasons:

* redis doesn't support DNS SRV records for discovering peers on ephemeral ports.
* redis-sentinel doesn't support redis masters whose ip addresses change.

This set of CoreOS fleet services sets up a redis instance on every host in the cluster that has `hosts=redis-1` metadata,
and some services that apply a master/slave topology to the available redis instances.

## Redis instances

Each redis instance is supported by three Fleet services, global to the set of hosts in the CoreOS cluster with the `hosts=redis-1` metadata.

`redis-1-node.service` starts a redis instance, with data volumes containers (DVCs) for its `etc/redis` and `/data`. Redis instances that have not had the master/slave topology applied to them come up unconfigured, as `SLAVEOF NO ONE`, but this poses no risk of accumulating unwanted writes because they have not yet been published into DNS. The service has an `ExecStartPost` that writes to a trigger in etcd indicate that the master/slave topology should be (re-)applied. The instances expose environment variables that cause them to be registered into the CoreOS cluster's SkyDNS, using the CoreOS host's name in the `redis-1.docker` domain. Use of the CoreOS host name would not be wise in production, but it makes demonstrations more visually appealing.

## Master/slave topology application

The following services maintain the master/slave topology:

`redis-1-dictator.service` listens for HTTP PUT requests to its /master path, expecting a JSON representation of the desired master/slave topology. If a redis instance is addressed by name instead of IP address, a DNS SRV lookup against the CoreOS cluster's SkyDNS is used to look up the IP address and port of the instance. The topology is then applied, with operations ordered to guarantee that no data is lost, at the cost of a small window during which writes to an old master will error out. Clients are expected to rediscover the redis master and retry on failure.

`redis-1-dnsd.service` listens for HTTP PUT requests to ids /dns path, expecting a JSON representation of the desired master/slave topology.  It currently only supports toplogies that address redis instances by SRV hostname, not by IP address. It publishes `master.redis-1.docker` and `slaves.redis-1.docker` SRV records.

`redis-1-topology-observer.service` watches the etcd key `/config/redis-1/topology-trigger` for writes from `redis-1-node.service` startups. When a write occurs, it reads the etcd key `/config/redis-1/topology` and sends its value to `redis-1-dictator.service` and `redis-1-dnsd.service`.

## Assumptions

Some assumptions are made about the CoreOS cluster, expressed in and fulfilled by [sheldonh/coreos-vagrant](https://github.com/sheldonh/coreos-vagrant):

* It provides etcd on every host. In very large production clusters, this is not true.
* It provides a SkyDNS service on every host.
* It automatically registers started containers into the `.docker` domain of of the SkyDNS service, and automatically deregisters stopped containers from same.

The [sheldonh/coreos-vagrant](https://github.com/sheldonh/coreos-vagrant) repo currently makes use of a patched version of [progrium/registrator](https://github.com/progrium/registrator):

* [PR 31](https://github.com/progrium/registrator/pull/31) implements TTL expiry for SKyDNS records.
* [PR 18](https://github.com/progrium/registrator/pull/18) implements support for published container IP addresses and exposed ports instead of host addresses and published ports. This redis demo does not require that patch.

## Demo

First set up an (optional) Docker registry mirror, to save on redownloading images every time you destroy and recreate your CoreOS cluster.

```
# On Fedora
sudo yum install -y docker-io
sudo curl -L http://goo.gl/fMM65m -o /etc/systemd/system/docker-registry-mirror.service
sudo systemctl start docker-registry-mirror.service
sudo systemctl enable docker-registry-mirror.service
sudo firewall-cmd --zone=public --add-port=5000/tcp
sudo firewall-cmd --zone=public --permanent --add-port=5000/tcp
```

Now create the CoreOS cluster. If you don't want to bother with a Docker registry mirror, just leave the `$registry_mirror` declaration
out of your `config.rb`. Note that we track the `alpha` channel of CoreOS for docker-1.3.0, for its `--ip-masq` and `--registry-mirror`
options:

```
git clone git@github.com:sheldonh/coreos-vagrant

cd coreos-vagrant

cat > config.rb <<EOF
\$num_instances=3
\$update_channel='alpha'
\$vb_memory = 2048
\$registry_mirror = "172.17.8.1:5000"
EOF

vagrant destroy -f && rm -f core-*-user-data ~/.fleetctl/known_hosts && cp user-data.erb.sample user-data.erb && vagrant up
```

Once the cluster is up, define the redis master/slave topology.
Note that this doesn't actually have to be done before the redis services are brought up.

```
cat > topology.json <<EOF
{
  "master": {
    "address": "core-01.redis-1.docker"
  },
  "slaves": [
    {
      "address": "core-02.redis-1.docker"
    },
    {
      "address": "core-03.redis-1.docker"
    }
  ]
}
EOF

sh define-topology.sh
```

Now schedule the services and wait for them to start:

```
cd redis

ssh-add ~/.vagrant.d/insecure_private_key
export FLEETCTL_TUNNEL=127.0.0.1:2222
fleetctl start *.service

watch fleetctl list-units
```

Initial service startup may be slow while docker pulls images. Wait for the config and data services to reach `active/exited` state, and for the remaining services to reach `active/running` state.

Now apply the defined master/slave topology:

```
sh apply-topology.sh
```

### Simple redis shell

You should now be able to contact the current redis master wherever it is with:

```
sh redis-cli.sh
```

This is a good way to check that all the components are interoperating, before testing that master/slave topology changes are lossless.

### Error 

A demonstration of lossless master/slave topology change can now be run. It's easiest to do this in two terminals:

```
# Terminal 1
cd redis-counter
rvm use . --create
bundle
COUNTER_CLEAR=1 COUNTER_COUNT=10000 COUNTER_INTERVAL=6 ruby counter.rb
```

```
# Terminal 2
sh mess-with-cluster.sh
```

The `counter.rb` process in terminal 1 will occasionally print error messages, as it attempts to write during topology changes.
When it is finished, it should print output like this:

```
ack'd: 9882 (0 missing) err'd: 118 (0 phantom)

```

Errors are to be expected. What is important is that there should be 0 missing and 0 phantom.
_Missing acks_ are bad; those are writes that were acknowledged by the master, but later found missing the final tally.
They indicate a hardware or network failure during topology change, or that the topology change algorithm is flawed.
_Phantom errors_ are bad; those are writes that the client considered as errors, and yet they made it into the final tally.
They indicate that [the consensus problem](http://en.wikipedia.org/wiki/Consensus_%28computer_science%29#Problem_description) is hard to solve.
