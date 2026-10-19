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

Run tests:

```bash
cabal test
```

Run executables:

```bash
cabal run tc  # cli
cabal run tc-objstore  # objstore
cabal run tc-server  # server
cabal run tc-agent  # agent
```

## CLI Reference:

## Control Plane HTTP API:

## Other Notes:
