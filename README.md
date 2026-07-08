# Conductor — A Minimal Container Runtime in Bash

A lightweight container engine written entirely in Bash, built on raw Linux kernel primitives — no Docker, no containerd, no external runtime dependencies. It builds images, launches isolated processes, wires up networking, and manages filesystems using nothing but `unshare`, `nsenter`, `overlayfs`, and standard networking tools.

## What's in here

Two files do all the work:

| File | Role |
|---|---|
| `conductor.sh` | Main driver script — every container/image command goes through this |
| `setup.sh` | Local config: network interface name, storage paths, etc. |

## Setup

You'll need a Linux box (a VM is fine) with these installed:

```bash
sudo apt install debootstrap iptables
```

Also make sure `ip`, `ping`, `top`, and `sha256sum` are available (they usually are by default on any Debian/Ubuntu system).

Before running anything, open `setup.sh` and set `DEFAULT_IFC` to whatever your machine's outward-facing network interface is called. Run `ip a` if you're not sure which one that is.

## What it can do

- **Build images** from a `Conductorfile` (yes, it's basically a Dockerfile clone) — supports `FROM`, `COPY`, and `RUN`, layered together with `overlayfs`
- **Spin up containers** with real process isolation via Linux namespaces — PID, mount, network, UTS, and IPC are all separated per-container
- **Attach networking** — each container gets its own `veth` pair, can be NATed out to the internet, or have host ports forwarded straight into it
- **Exec into running containers** by hooking into their existing namespaces with `nsenter`
- **Link containers together** so two running containers can talk to each other directly
- Handles the boring-but-necessary stuff automatically: mounting `/dev`, `proc`, and `sysfs` inside every container so it actually behaves like a normal Linux environment

## Command reference

**Build an image**

Write a `Conductorfile`:
```
FROM debian:bookworm
COPY ./myapp /opt/myapp
RUN apt update && apt install -y python3
```

Then build it:
```bash
sudo ./conductor.sh build myimage Conductorfile
```

**List images**
```bash
sudo ./conductor.sh images
```

**Run a container**
```bash
sudo ./conductor.sh run myimage mycontainer -- [cmd args]
```
No command given? Defaults to dropping you into `/bin/bash`.

**List running containers**
```bash
sudo ./conductor.sh ps
```

**Exec into a running container**
```bash
sudo ./conductor.sh exec mycontainer -- /bin/bash
```

**Stop a container**
```bash
sudo ./conductor.sh stop mycontainer
```

**Remove an image**
```bash
sudo ./conductor.sh rmi myimage
```

**Clear cached layers**
```bash
sudo ./conductor.sh rmcache
```

**Networking**

Give a container basic networking:
```bash
sudo ./conductor.sh addnetwork mycontainer
```

Give it internet access too:
```bash
sudo ./conductor.sh addnetwork mycontainer -i
```

Forward a host port into the container (host 80 → container 8080 here):
```bash
sudo ./conductor.sh addnetwork mycontainer -e 8080-80
```

Connect two containers directly:
```bash
sudo ./conductor.sh peer container1 container2
```

## How it's actually built under the hood

| Piece | Mechanism |
|---|---|
| Image builds | `debootstrap` pulls the base rootfs, the `Conductorfile` gets parsed line by line, each layer stacked via `overlayfs` |
| Running a container | `unshare` creates the new namespaces, `chroot` jumps into the overlay root, then `/dev`, `proc`, `sysfs` get mounted in |
| Exec into a container | `nsenter` joins all of the target container's active namespaces |
| Networking | `veth` pairs created via `ip`, NAT and port-forwarding handled through `iptables` |
| Storage | `overlayfs` gives copy-on-write layering so images and containers don't duplicate data unnecessarily |

## End-to-end example

```bash
# build an image
sudo ./conductor.sh build testimage Conductorfile

# launch a container from it
sudo ./conductor.sh run testimage eg

# give it internet + forward host:3000 to container:8080
sudo ./conductor.sh addnetwork eg -i -e 3000-8080

# get a shell inside it
sudo ./conductor.sh exec eg -- /bin/bash

# tear it down
sudo ./conductor.sh stop eg
```

## References

- [OverlayFS — Arch Wiki](https://wiki.archlinux.org/title/Overlay_filesystem)
- [Debootstrap — Debian Wiki](https://wiki.debian.org/Debootstrap)
- [Linux Namespaces — LWN.net](https://lwn.net/Articles/531381/)
