#!/bin/bash

set -eufx -o pipefail

# Default docker tag to pull.
# latest  = latest LTS release
# rolling = latest LTS (regardless of LTS status)
# devel   = current development snapshot
: "${DOCKERTAG:=latest}"

# Default size limit
: "${MAXSIZE:=90}"

container="docker-$DOCKERTAG-image-size-test"

# If there is a stale container delete it
if lxc list --format csv -c n | grep -q "^${container}$"; then
    lxc delete "$container" --force
    sleep 5
fi

lxc launch ubuntu: "$container" -e

# Wait for the container to be fully initialized.
lxc exec "$container" -- cloud-init status --wait

lxc exec "$container" -- apt update
lxc exec "$container" -- apt -y install docker.io
lxc exec "$container" -- mkdir /etc/systemd/system/docker.service.d
lxc exec "$container" -- \
	sh -c 'echo "[Service]\nEnvironment=\"HTTPS_PROXY=http://squid.internal:3128/\"" > /etc/systemd/system/docker.service.d/https-proxy.conf'
lxc exec "$container" -- systemctl daemon-reload
lxc exec "$container" -- systemctl restart docker
lxc exec "$container" -- docker pull "ubuntu:$DOCKERTAG"
size=$(lxc exec "$container" -- docker image ls "ubuntu:$DOCKERTAG" --format "{{.Size}}")
lxc delete "$container" --force

size=$(echo "$size" | grep -o '^[0-9]*')
echo "Maximum allowed size: ${MAXSIZE}MB"
echo "Current size: ${size}MB"

test "$size" -le "$MAXSIZE"
