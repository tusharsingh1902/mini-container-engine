#!/bin/bash
#
# Configuration settings for Conductor
# Author: Tushar Singh
#

# ---------------------------------------------------------
# Host Network Configuration
# Update this to match your system's internet-facing interface
# (You can find this by running 'ip a' on your host)
# ---------------------------------------------------------
DEFAULT_IFC=enp0s1

# ---------------------------------------------------------
# Container Subnet Settings
# Modify these only if they conflict with your host network
# ---------------------------------------------------------
IP4_SUBNET=192.168
IP4_PREFIX_SIZE=24      # Subnet mask for individual containers
IP4_FULL_PREFIX_SIZE=16 # Total managed address space

# =========================================================
# INTERNAL CONSTANTS (Do not modify below this line)
# =========================================================

# Required system binaries
NEEDED_TOOLS="ip ping iptables top debootstrap sha256sum"

# Storage paths
IMAGEDIR="$(dirname "$0")/.images"
CONTAINERDIR="$(dirname "$0")/.containers"
CACHEDIR="$(dirname "$0")/.cache"
EXTRADIR="$(dirname "$0")/extras"

# Reference to the main executable
SETUP_SCRIPT="$(dirname "$0")/conductor.sh"

# Global runtime state variables
IP4_PREFIX=
PORT=
INNER_PORT=
OUTER_PORT=
INTERNET=0
EXPOSE=0

# Valid base images and download endpoints
declare -A BASE_MIRRORS=(
    [debian]="https://deb.debian.org/debian"
    [ubuntu]="http://de.archive.ubuntu.com/ubuntu"
)

declare -A BASE_SUITES=(
    [debian:bookworm]="bookworm"
    [ubuntu:focal]="focal"
    [ubuntu:jammy]="jammy"
)
