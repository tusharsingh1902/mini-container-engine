#!/bin/bash
#
# Conductor - A lightweight container manager
# Author: Tushar Singh
#
echo -e "\e[1;36m Starting Conductor: Container Management System\e[0m"

# Require root privileges to proceed
[ "$EUID" -ne "0" ] && echo "Root permissions are required to run this script." && exit 1

set -o errexit
set -o nounset
umask 077

source "$(dirname "$0")/setup.sh"

############## utility functions start

fatal_error() {
    echo -e "\e[1;31m[CRITICAL]: $1\e[0m" >&2
    exit 1
}

verify_dependencies() {
    [ "$EUID" -ne "0" ] && fatal_error "Root permissions are required."
    for tool in $NEEDED_TOOLS; do which "$tool" >/dev/null || fatal_error "Missing required tool: $tool"; done
    mkdir -p "$IMAGEDIR" "$CONTAINERDIR" "$CACHEDIR" || fatal_error "Could not initialize required directories"
}

fetch_next_id() {
    local ID_NUM=1
    if [ -f "$CACHEDIR/.HIGHEST_NUM" ]; then
        ID_NUM=$(( 1 + $(< "$CACHEDIR/.HIGHEST_NUM" )))
    fi

    echo $ID_NUM > "$CACHEDIR/.HIGHEST_NUM"
    printf "%x" $ID_NUM
}

wait_for_interface() {
    local net_iface="$1"
    local ns_target="${2:-}"
    local max_retries=5
    local ns_cmd=

    [ -n "$ns_target" ] && ns_cmd="ip netns exec $ns_target"
    while [ "$max_retries" -gt "0" ]; do
        if ! $ns_cmd ip addr show dev $net_iface | grep -q tentative; then return 0; fi
        sleep 0.5
        max_retries=$((max_retries - 1))
    done
}

parse_instruction() {
    local current_cmd="$1"
    local parents="$2"
    
    # Extract command type (first word)
    local cmd_prefix="${current_cmd%% *}"
    local arguments="${current_cmd#* }"

    case "$cmd_prefix" in
        RUN)
            handle_run "$arguments" "$parents"
            ;;
        COPY)
            handle_copy "$arguments" "$parents"
            ;;
        *)
            fatal_error "Instruction not supported: $cmd_prefix"
            ;;
    esac
}

extract_layer_hash() {
    echo "$1" | awk -F: '{print $NF}' | awk -F/ '{print $NF}'
}

append_layer_stack() {
    local new_layer="$1"
    local current_stack="$2"
    
    if [ -z "$current_stack" ]; then
        echo "$new_layer"
    else
        echo "$current_stack:$new_layer"
    fi
}

############## utility functions end

# Core System Functions

handle_run() {
    local command="$1"
    local parent_layers="$2"
    local parent_hash=$(extract_layer_hash "$parent_layers")
    
    local cmd_hash=$(echo "$command" | sha256sum | cut -d' ' -f1)
    local layer_hash=$(echo "RUN-${parent_hash}-${cmd_hash}" | sha256sum | cut -d' ' -f1)
    
    if [ -d "$CACHEDIR/layers/$layer_hash" ]; then
        echo "Using cached RUN layer: $layer_hash"
        current_layer="$CACHEDIR/layers/$layer_hash"
        return
    fi
    
    mkdir -p "$CACHEDIR/layers/$layer_hash"/{diff,work,merged}

    mount -t overlay overlay \
    -o lowerdir="$parent_layers",upperdir="$CACHEDIR/layers/$layer_hash/diff",workdir="$CACHEDIR/layers/$layer_hash/work" \
    "$CACHEDIR/layers/$layer_hash/merged" || fatal_error "Failed to mount overlay"

    chroot "$CACHEDIR/layers/$layer_hash/merged" /bin/bash -c "$command" || fatal_error "Failed to execute command: $command"

    umount "$CACHEDIR/layers/$layer_hash/merged" || fatal_error "Failed to unmount overlay"

    echo "RUN $command" > "$CACHEDIR/layers/$layer_hash/metadata"
    echo "$parent_hash" > "$CACHEDIR/layers/$layer_hash/parent"
    current_layer="$CACHEDIR/layers/$layer_hash"
    echo "$current_layer" > "$CACHEDIR/layers/.last_layer"
}

handle_copy() {
    local args="$1"
    local parent_layers="$2"
    local parent_hash=$(extract_layer_hash "$parent_layers")
    
    IFS=' ' read -r src dest <<< "$args"
    [ -z "$src" ] && fatal_error "COPY requires source path"
    [ -z "$dest" ] && fatal_error "COPY requires destination path"
    
    local content_hash=$(find "$src" -type f -exec sha256sum {} + | sha256sum | cut -d' ' -f1)
    local layer_hash=$(echo "COPY-${parent_hash}-${content_hash}" | sha256sum | cut -d' ' -f1)

    if [ -d "$CACHEDIR/layers/$layer_hash" ]; then
        echo "Using cached COPY layer: $layer_hash"
        current_layer="$CACHEDIR/layers/$layer_hash"
        return
    fi
    
    mkdir -p "$CACHEDIR/layers/$layer_hash"/{diff,work,merged}

    mount -t overlay overlay \
        -o lowerdir="$parent_layers",upperdir="$CACHEDIR/layers/$layer_hash/diff",workdir="$CACHEDIR/layers/$layer_hash/work" \
        "$CACHEDIR/layers/$layer_hash/merged" || fatal_error "Failed to mount overlay"
    
    mkdir -p "$CACHEDIR/layers/$layer_hash/merged/$dest"
    cp -a "$src/" "$CACHEDIR/layers/$layer_hash/merged/$dest" || fatal_error "Failed to copy $src to $dest"

    umount "$CACHEDIR/layers/$layer_hash/merged" || fatal_error "Failed to unmount overlay"

    echo "COPY $src $dest" > "$CACHEDIR/layers/$layer_hash/metadata"
    echo "$parent_hash" > "$CACHEDIR/layers/$layer_hash/parent"
    current_layer="$CACHEDIR/layers/$layer_hash"
    echo "$current_layer" > "$CACHEDIR/layers/.last_layer"
}

build() {
    local NAME=${1:-}
    [ -z "$NAME" ] && fatal_error "Image name required"
    [ -d "$IMAGEDIR/$NAME" ] && fatal_error "Image $NAME exists"

    local CONDUCTORFILE="${2:-Conductorfile}"

    [ -f "$CONDUCTORFILE" ] || fatal_error "Conductorfile not found"
    
    local FROM_LINE=$(grep -m1 "^FROM " "$CONDUCTORFILE")
    [[ $FROM_LINE =~ FROM[[:space:]]([^:]+):([^[:space:]]+) ]] || fatal_error "Invalid FROM format"
    local DISTRO="${BASH_REMATCH[1]}" VERSION="${BASH_REMATCH[2]}"

    local BASE_KEY="${DISTRO}:${VERSION}" BASE_NAME="${DISTRO}-${VERSION}"
    
    if [ ! -d "$CACHEDIR/base/$BASE_NAME" ]; then
        mkdir -p "$CACHEDIR/base/$BASE_NAME"

        echo "=== DEBOOTSTRAP START ==="
        debootstrap "${BASE_SUITES[$BASE_KEY]}" "$CACHEDIR/base/$BASE_NAME" "${BASE_MIRRORS[$DISTRO]}" || fatal_error "Failed to create image $NAME"
        echo "=== DEBOOTSTRAP COMPLETE ==="
    fi

    local BASE_LAYER=$"$CACHEDIR/base/$BASE_NAME"
    local LAYER_STACK="$BASE_LAYER"
    
    while IFS= read -r instruction; do
        parse_instruction "$instruction" "$LAYER_STACK"
        LAYER_STACK=$(append_layer_stack "$current_layer/diff" "$LAYER_STACK")
    done < <(grep -E '^(RUN|COPY)' "$CONDUCTORFILE")
    
    mkdir -p "$IMAGEDIR/$NAME"
    echo "$LAYER_STACK" > "$IMAGEDIR/$NAME/layers"
    echo -e "\e[1;32mImage ${NAME:-} built with $(( $(echo "${LAYER_STACK}" | tr -dc ':' | wc -c) + 1 )) layers\e[0m"
}

images() {
    local IMAGES=$(ls -1 "$IMAGEDIR" 2>/dev/null || true)
    if [ -z "$IMAGES" ]; then
        echo -e "\e[1;31mNo images found\e[0m"
    else
        printf "%-20s %-10s %s\n" "Name" "Size" "Date"
        for i in $IMAGES; do
            local SIZE=$(du -sh "$IMAGEDIR/$i" | awk '{print $1}')
            local DATE=$(stat -c %y "$IMAGEDIR/$i" | awk '{print $1}')
            printf "%-20s %-10s %s\n" "$i" "$SIZE" "$DATE"
        done
    fi
}

remove_image() {
    local NAME=${1:-}
    [ -z "$NAME" ] && fatal_error "Image name is required"
    [ -d "$IMAGEDIR/$NAME" ] || fatal_error "Image $NAME does not exist"

    rm -rf "$IMAGEDIR/$NAME"
    echo -e "\e[1;32mImage $NAME removed\e[0m"
}

rmcache() {
    local active_containers=$(ls "$CONTAINERDIR" 2>/dev/null || true)
    [ -n "$active_containers" ] && fatal_error "Cannot remove cache: Active containers exist.\n$active_containers"

    if [ ! -d "$CACHEDIR/layers" ]; then
        echo -e "\e[1;31mNo cached layers found.\e[0m"
    else
        find "$CACHEDIR/layers" -mindepth 1 -maxdepth 1 -type d | while read -r layer; do
            local layer_hash=$(basename "$layer")
            if ! grep -qr "$layer_hash" "$IMAGEDIR"; then
                rm -rf "$layer"
                echo "Removed unused layer: $layer_hash"
            fi
        done
    fi

    find "$CACHEDIR/base" -mindepth 1 -maxdepth 1 -type d | while read -r base; do
        local base_name=$(basename "$base")
        if mount | grep -q "$base"; then
            umount "$base/merged" 2>/dev/null || true
        fi
        rm -rf "$base"
        echo -e "\e[1;32mRemoved base cache: $base_name\e[0m"
    done
}

run() {
    local IMAGE=${1:-}
    local NAME=${2:-}

    [ -z "$NAME" ] && fatal_error "Container name is required"
    [ -z "$IMAGE" ] && fatal_error "Image name is required"

    [ -d "$IMAGEDIR/$IMAGE" ] || fatal_error "Image $IMAGE does not exist"
    [ -d "$CONTAINERDIR/$NAME" ] && fatal_error "Container $NAME already exists"

    local CONTAINER_ROOTFS="$CONTAINERDIR/$NAME"
    mkdir -p "$CONTAINER_ROOTFS"
    local UPPER_DIR="$CONTAINER_ROOTFS/upper"
    local WORK_DIR="$CONTAINER_ROOTFS/work"
    local MERGED_DIR="$CONTAINER_ROOTFS/rootfs" 
    local BASE_LAYER=$(cat "$IMAGEDIR/$IMAGE/layers")

    mkdir -p "$UPPER_DIR" "$WORK_DIR" "$MERGED_DIR"

    mount -t overlay overlay \
        -o lowerdir=$BASE_LAYER,upperdir=$UPPER_DIR,workdir=$WORK_DIR \
        $MERGED_DIR || fatal_error "Failed to mount overlay for container"

    shift 2
    local INIT_CMD_ARGS=${@:-/bin/bash}

    mount --bind /dev $MERGED_DIR/dev || fatal_error "Failed to bind mount /dev"

    chmod 755 $MERGED_DIR
    unshare --fork --uts --pid --net --mount --ipc --kill-child --mount-proc chroot $MERGED_DIR /bin/bash -c "/bin/mount -t proc none /proc; /bin/mount -t sysfs none /sys; $INIT_CMD_ARGS;"
}

show_containers() {
    local CONTAINERS=$(ls -1 "$CONTAINERDIR" 2>/dev/null || true)

    if [ -z "$CONTAINERS" ]; then
        echo "No active containers found."
    else
        printf "%-20s %-10s\n" "Container Name" "Creation Date"
        for c in $CONTAINERS; do
            local c_date=$(stat -c %y "$CONTAINERDIR/$c" | awk '{print $1}')
            printf "%-20s %-10s\n" "$c" "$c_date"
        done
    fi
}

stop() {
    local NAME=${1:-}
    [ -z "$NAME" ] && fatal_error "Container name is required"
    [ -d "$CONTAINERDIR/$NAME" ] || fatal_error "Container $NAME does not exist"

    local PID=$(ps -ef | grep "$CONTAINERDIR/$NAME/rootfs" | grep -v grep | awk '{print $2}' || true)
    
    if [ -e "/sys/class/net/${NAME}-outside" ]; then
        ip link delete "${NAME}-outside" 2>/dev/null || true
    fi

    [ -z "$PID" ] || kill -9 $PID 2>/dev/null || true

    umount "$CONTAINERDIR/$NAME/rootfs/proc" > /dev/null 2>&1 || true
    umount "$CONTAINERDIR/$NAME/rootfs/sys" > /dev/null 2>&1 || true
    umount "$CONTAINERDIR/$NAME/rootfs/dev" > /dev/null 2>&1 || true

    local MERGED="$CONTAINERDIR/$NAME/rootfs"
    umount $MERGED || fatal_error "Failed to unmount $MERGED"

    local UPPER="$CONTAINERDIR/$NAME/upper"
    local WORK="$CONTAINERDIR/$NAME/work"
    rm -rf "$UPPER" "$WORK" "$MERGED"
    
    rm -rf "$CONTAINERDIR/$NAME"
    
    if [ -z "$(ls -1 "$CONTAINERDIR" 2>/dev/null || true)" ]; then
        rm -f "$EXTRADIR/.HIGHEST_NUM" 2>/dev/null || true
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -F FORWARD 2>/dev/null || true
        iptables -t nat -F 2>/dev/null || true
    fi
    
    echo -e "\e[1;32mContainer $NAME successfully removed.\e[0m"
}

exec() {
    local NAME=${1:-}
    local CMD=${2:-}

    [ -z "$NAME" ] && fatal_error "Container name is required"
    
    shift 
    local EXEC_CMD_ARGS=${@:-/bin/bash}

    [ -d "$CONTAINERDIR/$NAME" ] || fatal_error "Container $NAME does not exist"
    echo -e "\e[1;36mExecuting command in container: $NAME\e[0m"

    local UNSHARE_PID=$(ps -ef | grep "$CONTAINERDIR/$NAME/rootfs" | grep -v grep | awk '{print $2}')
    [ -z "$UNSHARE_PID" ] && fatal_error "Cannot locate container main process"

    local CONTAINER_INIT_PID=$(pgrep -P $UNSHARE_PID | head -1)
    [ -z "$CONTAINER_INIT_PID" ] && fatal_error "Cannot locate container init process"

    nsenter -t $CONTAINER_INIT_PID --uts --pid --net --mount --ipc --root --wd $EXEC_CMD_ARGS 
}

# Functions Pending Implementation

addnetwork() {
    echo "Function 'addnetwork' is pending implementation."
}

peer() {
    echo "Function 'peer' is pending implementation."
}

print_usage() {
    local display_full=${1:-}

    echo "Usage: $0 <command> [params] [options] [params]"
    echo ""
    echo "Available Commands:"
    echo "build <img-name> <conductorfile>      Compile a new container image"
    echo "images                                Display local images"
    echo "rmi <img>                             Remove an image"
    echo "rmcache                               Clear all cached layers"
    echo "run <img> <cntr> -- [command <args>]  Launch a container named <cntr> from <img>"
    echo "ps                                    List active containers"
    echo "stop <cntr>                           Halt and remove a container"
    echo "exec <cntr> -- [command <args>]       Run a command inside an active container"
    echo "addnetwork <cntr>                     Attach layer 3 networking"
    echo "peer <cntr> <cntr>                    Enable container-to-container communication"
    echo ""

    if [ -z "$display_full" ] ; then
        echo "Run with --help to view options."
        exit 1
    fi

    echo "Options:"
    echo "-h, --help                Display this help message"
    echo ""
    echo "-i, --internet            Grant internet access to the container."
    echo "                          Must be used with addnetwork."
    echo ""
    echo "-e, --expose <inner-port>-<outer-port>"
    echo "                          Map container port (inner) to host port (outer)"
    echo ""
    exit 1
}

OPTS="hie:"
LONGOPTS="help,internet,expose:"

OPTIONS=$(getopt -o "$OPTS" --long "$LONGOPTS" -- "$@")
[ "$?" -ne "0" ] && print_usage >&2 || true

eval set -- "$OPTIONS"

while true; do
    arg="$1"
    shift

    case "$arg" in
        -h | --help)
            print_usage full >&2
            ;;
        -i | --internet)
            INTERNET=1
            ;;
        -e | --expose)
            PORT="$1"
            INNER_PORT=${PORT%-*}
            OUTER_PORT=${PORT#*-}
            EXPOSE=1
            shift
            ;;
        -- )
            break
            ;;
    esac
done

[ "$#" -eq 0 ] && print_usage >&2

case "$1" in
    build)
        CMD=build
        ;;
    images)
        CMD=images
        ;;
    rmi)
        CMD=remove_image
        ;;
    rmcache)
        CMD=rmcache
        ;;
    run)
        CMD=run
        ;;
    ps)
        CMD=show_containers
        ;;
    stop)
        CMD=stop
        ;;
    exec)
        CMD=exec
        ;;
    addnetwork)
        CMD=addnetwork
        ;;
    peer)
        CMD=peer
        ;;
    "help")
        print_usage full >&2
        ;;
    *)
        print_usage >&2
        ;;
esac

shift
verify_dependencies
$CMD "$@"
