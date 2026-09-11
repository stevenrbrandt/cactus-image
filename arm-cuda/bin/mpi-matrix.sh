#!/bin/bash
# Probe which srun --mpi=<plugin> / MPI-flavor combinations actually
# bootstrap a 2-rank job with a Singularity image.
#
#   ./mpi-matrix.sh /work/images/cactus-cuda.sif "--bind /work"
#
# This is a REPORT, not a pass/fail test. Which combinations work is a
# property of the site, not of the image: on Deep Bayou only OpenMPI with
# --mpi=pmix_v4 works, while pmix_v5 hangs. The image ships both MPICH and
# OpenMPI builds precisely so that there is something to fall back to.
#
# It ships INSIDE the image but must be run OUTSIDE it, on a login or
# allocation node: srun and singularity live on the host, not in the
# container. It travels with the image so that the probe and the
# pmi-test binaries it launches can never be version-skewed. To get it out:
#
#   singularity exec cactus-cuda.sif mpi-matrix.sh --emit > mpi-matrix.sh
#   chmod +x mpi-matrix.sh
#   salloc -N 2 -n 2
#   ./mpi-matrix.sh /path/to/cactus-cuda.sif
#
# It is deliberately free of any docker/cluster assumptions, so the same
# file runs on this repo's test cluster and on a real machine.
#
# Outcomes:
#   PASS   2 ranks, message exchanged
#   SPLIT  each task came up as rank 0 of its own size-1 world -- the tasks
#          ran as N independent 1-rank jobs instead of joining one
#          MPI_COMM_WORLD. This is the failure that looks like success.
#   HANG   no result within the timeout
#   ERROR  the launch itself failed (plugin refused, etc.)
set -uo pipefail

# Hand back our own source, so the script can be lifted out of the image it
# ships in without needing a copy kept anywhere else.
if [ "${1:-}" = "--emit" ]; then cat "$0"; exit 0; fi

# Running this inside the container cannot work: srun is on the host. Say so
# rather than failing later with a confusing "srun: not found".
if [ -n "${SINGULARITY_CONTAINER:-}${APPTAINER_CONTAINER:-}" ]; then
    cat >&2 <<'MSG'
mpi-matrix.sh: this is running INSIDE the container, where there is no srun.
               Run it on the login/allocation node instead:

                 singularity exec <image.sif> mpi-matrix.sh --emit > mpi-matrix.sh
                 chmod +x mpi-matrix.sh
                 salloc -N 2 -n 2
                 ./mpi-matrix.sh <image.sif>
MSG
    exit 2
fi

sif="${1:?usage: mpi-matrix.sh <image.sif> [singularity-exec-args] }"
bind="${2:---bind /work}"
T="${MPI_MATRIX_TIMEOUT:-60}"
NODES="${MPI_MATRIX_NODES:-2}"

# What does this site offer? Parse `srun --mpi=list` rather than guessing:
# the set differs between sites and Slurm versions.
list=$(srun --mpi=list 2>&1)
plugins=$(printf '%s\n' "$list" \
    | sed -n 's/^[[:space:]]\{1,\}\([a-z0-9_]\{1,\}\)[[:space:]]*$/\1/p')
versioned=$(printf '%s\n' "$list" \
    | sed -n 's/.*versions available:[[:space:]]*//p' | tr ',' '\n' | tr -d ' ')
plugins=$(printf '%s\n%s\n' "$plugins" "$versioned" | sed '/^$/d' | sort -u)

echo "site offers: $(echo $plugins | tr '\n' ' ')"
echo "image:       $sif"
echo "timeout:     ${T}s per combination, -N $NODES -n 2"
echo

printf '%-14s %-10s %-7s %s\n' PLUGIN FLAVOR RESULT DETAIL
printf '%-14s %-10s %-7s %s\n' ------ ------ ------ ------

any_pass=0
best=""
classify() {
    local rc="$1" out="$2"
    if [ "$rc" = 124 ]; then echo "HANG|no output within ${T}s"; return; fi
    if printf '%s' "$out" | grep -q 'PMI-TEST: PASS'; then echo "PASS|"; return; fi
    if printf '%s' "$out" | grep -q 'requires exactly 2 MPI ranks, got 1'; then
        echo "SPLIT|tasks ran as independent 1-rank jobs"; return
    fi
    local first
    first=$(printf '%s' "$out" | grep -viE '^\s*$' | grep -iE 'error|fatal|invalid|unable|not found|refused' | head -1)
    echo "ERROR|${first:-$(printf '%s' "$out" | head -1)}"
}

for plugin in $plugins; do
    for flavor in mpich openmpi; do
        out=$(timeout "$T" srun --mpi="$plugin" -N "$NODES" -n 2 \
                  singularity exec $bind "$sif" \
                  "/opt/cactus-deps/bin/pmi-test-$flavor" 2>&1)
        rc=$?
        res=$(classify "$rc" "$out")
        printf '%-14s %-10s %-7s %s\n' "$plugin" "$flavor" "${res%%|*}" "${res#*|}"
        if [ "${res%%|*}" = PASS ]; then
            any_pass=1
            [ -z "$best" ] && best="--mpi=$plugin + $flavor"
        fi
    done
done

echo
if [ "$any_pass" = 1 ]; then
    echo "working combination for 'srun ... singularity exec ... cactus_sim': $best"
else
    echo "NO combination bootstrapped a 2-rank job."
fi

# The env-stripping failure, demonstrated rather than asserted: srun passes
# the PMI handshake entirely through environment variables.
if [ -n "$best" ]; then
    p="${best#--mpi=}"; p="${p%% *}"; f="${best##*+ }"
    out=$(timeout "$T" srun --mpi="$p" -N "$NODES" -n 2 \
              singularity exec --cleanenv $bind "$sif" \
              "/opt/cactus-deps/bin/pmi-test-$f" 2>&1); rc=$?
    res=$(classify "$rc" "$out")
    echo "same combination with --cleanenv: ${res%%|*} ${res#*|}"
fi

[ "$any_pass" = 1 ]
