#!/bin/bash
# Convert a local docker image into a Singularity .sif on the cluster's
# shared filesystem, so it can be exec'd from any node.
#
#   ./load-image.sh stevenrbrandt/cactus-cuda [name]
#
# It pulls straight from the host's docker daemon (node1 has the socket bind
# mounted), so the image under test is exactly the one built locally,
# including changes not yet pushed to any registry.
#
# The obvious route -- docker save to a tar, then build from it -- does not
# work here, and both failure modes are worth recording:
#
#   docker-archive:///work/tmp/x.tar
#     FATAL: must specify a digest - layout contains multiple images
#     Modern `docker save` writes an OCI layout and BuildKit puts two
#     manifests in it (the tagged image plus an unannotated one), so the
#     transport cannot choose.
#
#   oci-archive:///work/tmp/x.tar:latest
#     FATAL: stat .../temp-oci-3843297576:latest/index.json: no such file
#     The tag is appended to apptainer's temp *directory* name rather than
#     being parsed as a reference.
#
# Both also require materialising a ~51GB uncompressed tar for a 13GB image,
# which costs many minutes of dockerd CPU before a single byte is emitted.
set -euo pipefail

img="${1:?usage: load-image.sh <docker-image> [sif-name]}"
name="${2:-$(printf '%s' "$img" | tr '/:' '__')}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$here/work"

case "$img" in *:*) ref="$img" ;; *) ref="$img:latest" ;; esac

mkdir -p "$work/images" "$work/tmp"

echo "==> apptainer build $name.sif from docker-daemon://$ref"
# APPTAINER_TMPDIR must be on the big shared volume: the default inside the
# container is far too small for a multi-GB image, and the failure is an
# opaque "no space left on device" partway through the squashfs step.
cd "$here"
docker compose exec -T \
    -e APPTAINER_TMPDIR=/work/tmp \
    -e APPTAINER_CACHEDIR=/work/tmp/cache \
    node1 apptainer build -F "/work/images/$name.sif" "docker-daemon://$ref"

# The build runs as root inside the container; hand the result back to the
# cluster user so it can be read (and deleted) as them and from the host.
docker compose exec -T node1 chown 1168:1000 "/work/images/$name.sif"

echo "==> /work/images/$name.sif"
docker compose exec -T node1 ls -lh "/work/images/$name.sif"
