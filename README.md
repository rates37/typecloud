# typecloud

`typecloud` is a lightweight cloud, implemented in Haskell. The CLI allows you to drive a cluster of Linux machines. It runs containers on them, connects those containers over a WireGuard-based overlay network, gives them persistent volumes, and manages their lifecycle.

It is not intended for use in any real production environment. It is currently WIP (but even when finished you probably shouldn't use it in a production setting).

## What it does:

The responsibilities of `typecloud` are partitioned into the following main areas:

- Compute: Manage the lifecycle of containers on a node in the cloud. The scheduler spreads instances across nodes and never [overcommits](https://en.wikipedia.org/wiki/Memory_overcommitment) CPU or memory. Instances that don't fit in the available cloud resources are left in a pending state until either they are removed or sufficient resources become available.

- Networking: Every container gets a unique address in the range `10.100.0.0/16` Any container can reach any other container by IP, whichever node is runs on. A new node that is added doesn't need any manual network configuration.

- Storage: Volumes are created as etx4 filesystems on a node. They can be mounted into containers. Their lifetime is not tied to the container(s) that use them. They persist until explicitly deleted.

- Control: All nodes are managed by a central control plane, which manages their lifecycle and coordinates the overall cloud. Each node sends regular heartbeats to the control plane, reporting its status and available resources. A node that stops heartbeating is marked as dead, and its instances are automatically re-scheduled onto healthy (online) nodes.

- Object store: A separate HTTP service that stores objects in a directory tree. Interacts over a REST-like API (GET, PUT, DELETE).

## Main Components:

`typecloud` is implemented as a set of Haskell executables that each serve a specific role:

| Binary        | Runs on                            | Role                                                                                                                                                 |
| ------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tc-server`   | one control plane node             | Holds the cluster state, schedules instances and volumes, and serves the HTTP API. Optionally saves state to a JSON snapshot file.                   |
| `tc-agent`    | every worker (data plane) node     | Registers with the server, sends heartbeats, and controls the local machine match what the server wants it to run/store: containers, volumes, peers. |
| `tc`          | anywhere that can reach the server | Command-line client interface                                                                                                                        |
| `tc-objstore` | anywhere that can reach the server | Object storage service                                                                                                                               |

## Requirements:

To build, GHC and Cabal. This project was tested/developed using GHC 9.6 and GHC2021 language.

On each node:

- Linux, running as root
- `podman` for containers
- `wireguard-tools` (`wg`) and `iproute2` (`ip`) for the overlay network
- `iptables` and `sysctl` for forwarding rules
- `e2fsprogs` (`mkfs.ext4`), `util-linux` (`mount`, `umount`, `mountpoint`) and `coreutils` (`truncate`) for volumes

Ports:

| Port  | Protocol | Used by                            |
| ----- | -------- | ---------------------------------- |
| 8080  | TCP      | `tc-server` (HTTP API)             |
| 51820 | UDP      | WireGuard on every node            |
| 9000  | TCP      | `tc-objstore` (object storage API) |

## Build and Test:

```bash
cabal build
cabal test
```

## Quick Start:

Bring up a control plane and two nodes on a network. Each command below is shown with its default flags. The `--help` flag can be used to see all available options.

```bash
## On the control plane machine: start the server, logging the state to a file:
cabal run tc-server -- --state /var/lib/typecloud/state.json

## on each node, as root:
# start the agent with a unique name and a reachable address:
cabal run tc-agent -- --server https://CONTROL_PLANE:8080 --name n1 --addr 192.168.1.11
cabal run tc-agent -- --server https://CONTROL_PLANE:8080 --name n2 --addr 192.168.1.12

## from any machine that can reach the control plane:
# list all nodes and their status:
cabal run tc -- --server https://CONTROL_PLANE:8080 nodes
# start up an instance
cabal run tc -- --server https://CONTROL_PLANE:8080 run <TODO>
# see all running instances:
cabal run tc -- --server https://CONTROL_PLANE:8080 ps
```

You can try the system without root and without real containers. You can just run the agent with `--dry-run`. It will log every action it would take without actually running them.

## Running each component:

### tc-server:

```bash
cabal run tc-server -- [--port 8080] [--state FILE]
```

| Flag      | Default | Explanation                                                                                                                                                                                                             |
| --------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--port`  | 8080    | The port for the HTTP API                                                                                                                                                                                               |
| `--state` | none    | The JSON snapshot file. If provided, state is loaded from it at startup. If it is empty, the server starts with empty initial state. If this option is not provided, the state is in-memory only, and is not persisted. |

### tc-agent:

```bash
sudo cabal run tc-agent -- [--name NAME] [--addr ADDR] [--dry-run]
```

| Flag          | Default              | Explanation                                                                             |
| ------------- | -------------------- | --------------------------------------------------------------------------------------- |
| `--name`      | required             | A unique node name. It should not change, and should be unique in the cloud             |
| `--addr`      | required             | The address other nodes use to reach this node's WireGuard socket                       |
| `--cpus`      | 2                    | CPUs this node can offer to instances                                                   |
| `--mem-mb`    | 2048                 | Memory in MB this node can provide to instances                                         |
| `--dry-run`   | false                | If set, the agent will log actions but not perform them                                 |
| `--state-dir` | `/var/lib/typecloud` | The directory where the agent stores its WireGuard key, volume images, and mount points |

On the first start, the agent creates a WireGuard key in `--state-dir`. It is kept across restarts, and registers with the server. If the server is down/unreachable, it re-attempts every two seconds.

## CLI Reference:

Global options, placed before the subcommand:

| Option               | Default                 | Explanation                         |
| -------------------- | ----------------------- | ----------------------------------- |
| `-s`, `--server URL` | `http://localhost:8080` | The URL of the control plane server |

| Command                             | Explanation                                                                                                                              |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `tc nodes`                          | List all nodes with address, subnet, CPUs, memory, status, and instance count                                                            |
| `tc run IMAGE [CMD...]`             | Starts an instance. Options: `--cpus N` (default 1), `--mem MB` (default 256), `-v VOL:PATH` (repeatable). Prints the newest instance ID |
| `tc ps`                             | Lists instances with ID, image, node, IP, and status                                                                                     |
| `tc rm ID`                          | Deletes an instance. Its container is stopped on the node within a short period of time                                                  |
| `tc volume-create GB [--node NAME]` | Creates a volume (limited to max 100GB). Without `--node`, it goes on the live node with the fewest volumes.                             |
| `tc volume-ls`                      | Lists volumes with ID, size, and node.                                                                                                   |
| `tc volume-rm ID`                   | Deletes a volume and its data. Refused if the volume is in use.                                                                          |
