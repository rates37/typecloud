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

### Ideas/Concepts:

#### Control Plane and Data Plane:

Control plane decides what should be true about the current state of the cloud, e.g., what instances exist and where. Stores state, answers API calls, etc.

Data plane carries out the actual work, carries containers, network, disks, etc.

For now, control plane will be 1 server, and data plane is the collective of what the agent does on each machine.

#### Level-Triggered Reconciliation:

The way the simple cloud will run: the server tells a node to do something like "start a container X". But if a message is lost, or the agent crashes, machine reboots, etc. the state of the cloud may not match the desired state.
Level triggered reconciliation is like what Kubernetes (and most cloud orchestrators) do. The server announces a desired state, and the agent repeatedly:

1. Poll the desired state from the server
2. Check the actual state of the node
3. Computes the difference between the desired state and the real state, taking relevant actions to fix the differences.
4. Sleep before repeating the process

The agent doesn't rely on having to have "seen" or "received" an event. That way a missed message, temporary failure, or even manual `podman rm` just self-fixes on the next polling loop iteration. So at its core, the agent is basically just a pure function like:

```haskell
reconcile :: Desired -> Actual -> [Action]
```

#### Overlay Network Plan:

Each node owns a slice of the address space `10.100.N.0/24` and a local bridge that its containers attach to. A WireGuard tunnel between nodes can carry traffic for the other nodes' address space slices.

The underlay is whatever network the machines already share (e.g., for testing, the addresses of the VMs). The overlay is 10.100.0.0/16 which only exists in the tunnels (containers never see).

#### Volumes:

A "disk" for a container can be a sparse file on the host, formatted as ext4 and mounted through a loop device, then bind-mounted into the container. Large oversimplification of real cloud storage systems, but not the focus for now.

## Components/Plan:

### `tc-server`

The control plane component. Owns the entire cluster state. Responsible for decision making, scheduling, detect dead nodes, etc. Runs as a single server instance (for now). Talks to CLI and data plane agents (HTTP).

### `tc-agent`

The data plane node agent. Observes its machine and reconciles it toward the desired state. Runs on every machine in the data plane. Talks to the `tc-server` (HTTP), podman, local machine resources.

### `tc`

The CLI to interact with (setup, manage, monitor, etc.) the cloud. Runs on user/cloud admin computer and only communicates with the `tc-server` (HTTP).

### `tc-objstore`

An S3-like object storage service.

### Example Lifecycle

1. The CLI POSTs an `Instance` to `/instances` on the `tc-server`
2. The sever runs pure functions to validate the request, record the instance as unplaced/unallocated, then asks the scheduler for a node and allocates an IP from that node's `/24`. New state is saved to disk
3. Agent on the selected node fetches `GET /nodes/<name>/desired` and sees the new instance in it
4. Agent observes what's currently running, runs `reconcile desired actual` to get list of actions to perform, and then executes those actions to reconcile the actual state with the desired state.

### The State Model:

The control plane's entire state is a value:

```haskell
data Cluster = Cluster
    { cNodes     :: Map NodeId Node
    , cInstances :: Map InstanceId Instance
    , cVolumes   :: Map VolumeId Volume
    , cNextId    :: Int
    }
```

Every API call is a pure function from one `Cluster` state to the next. The following invariants must hold after each state transition:

- I1: A placed instance's IP lies inside its node's /24 subnet and is unique among that node's instances.
- I2: At placement time, the node's placed CPUs and memory never exceed its capacity
- I3: An instance that mounts volumes is only ever placed on the node that those volumes reside on (currently out of scope to have cross-node volume mounting)
- I4: A volume is mounted by at most one instance at a time
- I5: No two nodes share a subnet

### Interfaces:

HTTP API description (the endpoints exposed by `tc-server` and what the cli will talk to):

- `POST /nodes`: called by data plane agents
- `GET /nodes`: called by the CLI to see all nodes
- `GET /nodes/:name/desired`: called by the data plane agent to fetch the desired state
- `POST /nodes/:name/heartbeat`: called by the data plane agent to report its health
- `POST /instances`: called by the CLI to create a new instance
- `GET /instances`: called by the CLI to see all instances
- `DELETE /instances/:id`: called by the CLI to delete an instance
- `POST /volumes`: called by the CLI to create a new volume
- `GET /volumes`: called by the CLI to see all volumes
- `DELETE /volumes/:id`: called by the CLI to delete a volume

Object store has it's own trivial API too.

## Planned Haskell Module Layout:

### Pure Modules:

- `TC.Net`: responsible for networking, subnet management
- `TC.Types`: All domain types and its JSON
- `TC.Scheduler`: responsible for choosing what nodes to place instances on
- `TC.Cluster`: state transition functions behind the API calls
- `TC.Reconcile`: Pure model of actions (basically reconciliation functionality)
- `TC.Agent.Parse`: interprets outputs of `podman ps`, `wg show`, `/proc/mounts`, etc.
- `TC.Agent.Commands`: Build commands to interact with the system (e.g., `podman`, `wg`, etc.)

### Impure Modules:

- `TC.Server`: `MVar Cluster` to hold current state, HTTP handlers, etc.
- `TC.Agent.Backend`: Implements the apply functions to enact `Action`s
- `TC.ObjStore`: Implements the object store backend on node's local disk

## Implementation Notes

### Scheduler

Goal of the scheduler is to, given the needs of an instance, and a list of live nodes with their free capacity, select the most appropriate node to place the instance on.

1. If a volume pins an instance to a node, instance must be placed on that node.
2. Node is only eligible if its free CPUs and memory can accommodate the requirements
3. From the eligible nodes, prefer the one with the most memory (then CPUs) left AFTER placement. Tie break by node name if needed.


### API

The API is a servant API type defined in `TC.API`. Both server and the client derive from the same type ensuring consistency.

See `TC.Server` for server implementation. Rough server notes:

* atomic snapshots: save function writes to `filename.tmp` and then renames it to `filename` to make sure a crash doesn't leave a partially written or corrupt file.

* heartbeat events are not persisted to disk as they happen every 2 seconds and don't add anything meaningful to the long-term state


Using/testing the server:

In one terminal, start the server:

```bash
cabal run tc-server -- --port 8080 --state state.json
```

Then curl:

```
$ export U=http://localhost:8080

$ curl -X POST $U/nodes -H 'Content-Type: application/json' -d '{"name":"a","addr":"192.168.64.2","wgKey":"AAAA=","cpus":4,"memMb":4096}'

{"subnet":1}

                                       
$ curl -X POST $U/volumes -H 'Content-Type: application/json' -d '{"sizeGb":1,"node":"a"}'
{"id":"v-1","sizeGb":1,"node":"a"}

$ curl -X POST $U/instances -H 'Content-Type: application/json' -d '{"image":"nginx","cmd":[],"cpus":1,"memMb":256,"mounts":[{"volume":"v-1","path":"/data"}]}'
{"id":"i-2","spec":{"image":"nginx","cmd":[],"cpus":1,"memMb":256,"mounts":[{"volume":"v-1","path":"/data"}]},"placement":null,"running":false}

$ curl $U/nodes/a/desired
{"instances":{},"volumes":{"v-1":1},"peers":[{"key":"BBBB=","endpoint":"192.168.64.3:51820","subnet":2}]}

$ cat state.json
{"nodes":{"a":{"name":"a","addr":"192.168.64.2","wgKey":"AAAA=","subnet":1,"cpus":4,"memMb":4096,"lastSeen":"2026-10-08T13:37:14.584958Z","running":[]},"b":{"name":"b","addr":"192.168.64.3","wgKey":"BBBB=","subnet":2,"cpus":4,"memMb":4096,"lastSeen":"2026-10-08T13:40:58.799571Z","running":[]}},"instances":{"i-2":{"id":"i-2","spec":{"image":"nginx","cmd":[],"cpus":1,"memMb":256,"mounts":[{"volume":"v-1","path":"/data"}]},"placement":null}},"volumes":{"v-1":{"id":"v-1","sizeGb":1,"node":"a"}},"nextId":3}
```
