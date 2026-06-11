# mini-container-engine
# Containers From Scratch

## Overview

This task implements a Docker-like container management tool using Bash and core Linux primitives. The tool, called **Conductor**, enables you to build images, instantiate containers, manage networking, and layer filesystems using overlayfs—all from scratch, without relying on Docker or other container engines.


---

## Features

- **Image Building:** Create Debian/Ubuntu-based images using a Dockerfile-like Conductorfile. Supports `FROM`, `COPY`, and `RUN` instructions with layered overlayfs.
- **Container Lifecycle:** Instantiate, list, stop, and remove containers. Each container is isolated using Linux namespaces (PID, UTS, NET, MOUNT, IPC).

---

## Prerequisites

- **Operating System:** Linux (recommended inside provided VM)
- **Tools:** `ip`, `ping`, `iptables`, `top`, `debootstrap`, `sha256sum`
- **Install dependencies:**

```bash
sudo apt install debootstrap iptables
```


---

## Usage

### 1. Build an Image

Prepare a `Conductorfile` (like a Dockerfile) with instructions:

```
FROM debian:bookworm
COPY ./myapp /opt/myapp
RUN apt update && apt install -y python3
```

Build the image:

```bash
sudo ./conductor.sh build myimage Conductorfile
```

### 2. List Images

```bash
sudo ./conductor.sh images
```

### 3. Run a Container

```bash
sudo ./conductor.sh run myimage mycontainer -- [command args]
# If no command is given, defaults to /bin/bash
```

### 4. List Running Containers

```bash
sudo ./conductor.sh ps
```

### 5. Execute a Command in a Running Container

```bash
sudo ./conductor.sh exec mycontainer -- [command args]
# Example: sudo ./conductor.sh exec mycontainer -- /bin/bash
```

### 6. Stop and Remove a Container

```bash
sudo ./conductor.sh stop mycontainer
```

### 7. Remove an Image

```bash
sudo ./conductor.sh rmi myimage
```



---
