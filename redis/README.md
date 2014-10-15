# Safe Redis on CoreOS

This is an example of how redis could be run safely in a CoreOS cluster. This is a challenging undertaking for a few reasons:

* redis doesn't support DNS SRV records for discovering peers on ephemeral ports.
* redis-sentinel doesn't support redis masters whose ip addresses change.

This set of CoreOS fleet services sets up a redis instance on every host in the cluster that has `hosts=redis-1` metadata,
and some services that apply a master/slave topology to the available redis instances.

## Redis instances

Each redis instance is supported by three Fleet services, global to the set of hosts in the CoreOS cluster with the `hosts=redis-1` metadata.

`redis-1-node-config.service` and `redis-1-node-data.service` create persistent data volume containers (DVCs) for redis config and data respectively, if these do not already exist on the host. They are `oneshot` services.

`redis-1-node.service` starts a redis instance that mounts `/etc/redis` and `/data` from the DVCs. Redis instances that have not had the master/slave topology applied to them come up unconfigured, as `SLAVEOF NO ONE`, but this poses no risk of accumulating unwanted writes because they have not yet been published into DNS. The service has an `ExecStartPost` that writes to a trigger in etcd indicate that the master/slave topology should be (re-)applied. The instances expose environment variables that cause them to be registered into the CoreOS cluster's SkyDNS, using the CoreOS host's name in the `redis-1.docker` domain. Use of the CoreOS host name would not be wise in production, but it makes demonstrations more visually appealing.

## Master/slave topology application

The following services maintain the master/slave topology:

`redis-1-dictator.service` listens for HTTP PUT requests to its /master path, expecting a JSON representation of the desired master/slave topology. If a redis instance is addressed by name instead of IP address, a DNS SRV lookup against the CoreOS cluster's SkyDNS is used to look up the IP address and port of the instance. The topology is then applied, with operations ordered to guarantee that no data is lost, at the cost of a small window during which writes to an old master will error out. Clients are expected to rediscover the redis master and retry on failure.

`redis-1-topology-observer.service` watches the etcd key `/config/redis-1/topology-trigger` for writes from `redis-1-node.service` startups. When a write occurs, it reads the etcd key `/config/redis-1/topology` and sends its value to `redis-1-dictator.service`.

## Assumptions

Some assumptions are made about the CoreOS cluster, expressed in and fulfilled by [sheldonh/coreos-vagrant](https://github.com/sheldonh/coreos-vagrant):

* It provides etcd on every host. In very large production clusters, this is not true.
* It provides a SkyDNS service on every host.
* It automatically registers started containers into the `.docker` domain of of the SkyDNS service, and automatically deregisters stopped containers from same.

The [sheldonh/coreos-vagrant](https://github.com/sheldonh/coreos-vagrant) repo currently makes use of a patched version of [progrium/registrator](https://github.com/progrium/registrator):

* [PR 31](https://github.com/progrium/registrator/pull/31) implements TTL expiry for SKyDNS records.
* [PR 18](https://github.com/progrium/registrator/pull/18) implements support for published container IP addresses and exposed ports instead of host addresses and published ports. This redis demo does not require that patch.

## Demo

To get up and running, first create the CoreOS cluster. Note that this demo assumes you run a local docker registry, to save docker pulls when you destroy and recreate the cluster. If that's too desirable, just hack the registry mirror details out of the Fleet service files.

```
git clone git@github.com:sheldonh/coreos-vagrant

cd coreos-vagrant

cat > config.rb <<EOF
$num_instances=3
$update_channel='alpha'
$vb_memory = 2048
$registry_mirror = "172.17.8.1:5000"
EOF

vagrant destroy -f && rm -f core-*-user-data && cp user-data.erb.sample user-data.erb && vagrant up
```

Once the cluster is up, define the redis master/slave topology. Note that this doesn't actually have to be done before the redis services are brought up.

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
sh apply-topology.sh
```

Now schedule the services and wait for them to start:

```
cd redis

fleet start *.service

watch fleetctl list-units
```

Initial service startup may be slow while docker pulls images. Wait for the config and data services to reach `active/exited` state, and for the remaining services to reach `active/running` state.

You should now be able to contact the current redis master as follows:

```
vagrant ssh 172.17.8.101 -- docker run --rm -it --link redis-1-node:redis 172.17.8.1:5000/redis redis-cli -h redis
```

## TODO

For the demo to shine, it should

* set up `master.redis-1.docker` and `slaves.redis-1.docker` in SkyDNS, and
* show how to connect to the redis master without `vagrant ssh`,
* show how to connect to the redis master on an ephemeral port.
