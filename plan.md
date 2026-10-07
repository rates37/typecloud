# Typecloud: A Mini Cloud In Haskell

This is a planning / ideas document for a project implementing a cloud infrastructure stack in Haskell.

## Goals / Scope:

At a high level, the end-goal for this project (currently) is a few linux machines controlled from one CLI, that can run containers, connect them across a private network, and give them storage. Implemented with Haskell, on top of podman, WireGuard and other components (that should be theoretically able to be swapped out for others if/as needed).

Goals surround three key areas: compute, networking, storage.

### Compute Goals/Requirements:

1. Run a command like `tc run IMAGE [CMD...]` to start a container on some node in the cloud.

2. List running containers on a specific node, e..g, `tc ps`

3. Remove a container `tc rm CONTAINER_ID`

4. Compute instances declare CPUs and memory. Scheduler spreads instances across available nodes appropriately. Never overcommit resources. If nothing fits, the instance waits in some "pending" state and is allocated as soon as resources are available.

For now/planned, compute is only in containers (no VMs yet).

### Networking Goals/Requirements:

1. Every instance gets a unique IP address within 10.100.0.0/16. Any instance can reach any other instance by IP, whichever node each is on.

2. Adding a node only needs a single command, no manual network configuration needed from the end user / cloud operator.

### Storage Goals/Requirements:

1. Create volumes like `tc volume create VOLUME_NAME`

2. Compute instances can mount volumes

3. Data persists in volume when instance is deleted, unless the volume itself is explicitly removed.

4. Object store to support put, get delete operations over HTTP.

### Operational Goals/Requirements:

1. Restarting the control plane does nothing. If it's down, running instances are unaffected.

### Currently Out of Scope (possible future work):

1. VMs

2. Advanced networking features like load balancers, firewalls, etc.

3. Multi-tenancy/isolation between cloud users (beyond what Podman provides)

4. High availability (keen to implement in the future)

5. Live migration, volume replication (want), snapshots

6. Container image registry. Just rely on what podman can pull.

## Architecture:

tbc

## Plan:

tbc
