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

# Extra flags for srun itself -- account, partition, qos. Needed when this
# is run from a login node rather than inside an allocation, because then
# every combination has to allocate its own job.
SRUN_FLAGS="${MPI_MATRIX_SRUN_FLAGS:-}"
NODES_ARG=""; T_ARG=""
usage() {
    cat <<'USAGE'
usage: mpi-matrix.sh <image.sif> [singularity-exec-args] [options]

  <image.sif>              the image to test
  [singularity-exec-args]  e.g. "--nv --bind /work --bind /project"

options:
  -p, --partition NAME   partition/queue to run in
  -A, --account NAME     account to charge
      --srun-flags "..." any other srun flags (qos, reservation, gres, ...)
      --nodes N          nodes per combination (default 2)
      --timeout SECS     per-combination timeout (default 60)
      --emit             print this script's own source and exit
  -h, --help             this message

Partition and account have no defaults. Running outside an allocation
means every combination allocates its own job, so a site that requires
either will reject all of them -- which shows up as NOJOB rows naming the
scheduler's reason.

  salloc -N 2 -n 2 -A myacct -p mypart
  ./mpi-matrix.sh /path/image.sif "--nv --bind /work"

  # or, from a login node:
  ./mpi-matrix.sh /path/image.sif "--nv --bind /work" -A myacct -p mypart
USAGE
}

pos=(); npos=0
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--partition) SRUN_FLAGS="$SRUN_FLAGS -p $2"; shift 2 ;;
        -A|--account)   SRUN_FLAGS="$SRUN_FLAGS -A $2"; shift 2 ;;
        --srun-flags)   SRUN_FLAGS="$SRUN_FLAGS $2"; shift 2 ;;
        --nodes)        NODES_ARG="$2"; shift 2 ;;
        --timeout)      T_ARG="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        -*)
            # The second positional is the singularity exec args, and those
            # legitimately start with a dash ("--nv --bind /work"). So a
            # dashed argument is only an unknown option once both
            # positionals are already in hand; before that it is data.
            if [ "$npos" -lt 2 ]; then
                pos+=("$1"); npos=$((npos+1)); shift
            else
                echo "mpi-matrix.sh: unknown option $1" >&2; usage >&2; exit 2
            fi ;;
        *)              pos+=("$1"); npos=$((npos+1)); shift ;;
    esac
done
set -- ${pos+"${pos[@]}"}

if [ $# -lt 1 ]; then usage >&2; exit 2; fi
sif="$1"
bind="${2:---bind /work}"
T="${T_ARG:-${MPI_MATRIX_TIMEOUT:-60}}"
NODES="${NODES_ARG:-${MPI_MATRIX_NODES:-2}}"

# Lines Slurm writes to stderr that are notices, not failures. "Using
# default partition" in particular is printed with an "srun: error:" prefix
# on some sites, so a naive search for /error/i reports it as the reason a
# combination failed and hides the real one.
BENIGN='Using default partition|queued and waiting|has been allocated resources|Job [0-9]+ scheduled|Requested nodes are busy'

# What does this site offer? Parse `srun --mpi=list` rather than guessing:
# the set differs between sites and Slurm versions.
list=$(srun --mpi=list 2>&1)
plugins=$(printf '%s\n' "$list" \
    | sed -n 's/^[[:space:]]\{1,\}\([a-z0-9_]\{1,\}\)[[:space:]]*$/\1/p')
versioned=$(printf '%s\n' "$list" \
    | sed -n 's/.*versions available:[[:space:]]*//p' | tr ',' '\n' | tr -d ' ')
plugins=$(printf '%s\n%s\n' "$plugins" "$versioned" | sed '/^$/d' | sort -u)

if [ -z "${SLURM_JOB_ID:-}" ]; then
    echo "note: not inside an allocation, so each combination allocates its own"
    echo "      job. If this site needs an account or a non-default partition,"
    echo "      give them here, e.g."
    echo "        --srun-flags '-A <account> -p <partition>'"
    echo "      or run this inside salloc -N 2 -n 2."
    echo
fi
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
    # The job never started: nothing about MPI was tested, and the fix is
    # a scheduler one (account, partition, qos), not an MPI one. Keep it a
    # separate verdict so it cannot be misread as "this plugin does not work".
    local alloc
    alloc=$(printf '%s' "$out" | grep -vE "$BENIGN" \
            | grep -iE 'Unable to allocate resources|Invalid account|Invalid partition|account/partition|Invalid qos|Access/permission denied|specified partition|node configuration is not available|violates' \
            | head -1)
    if [ -n "$alloc" ]; then echo "NOJOB|${alloc#srun: error: }"; return; fi

    local first
    first=$(printf '%s' "$out" | grep -viE '^[[:space:]]*$' | grep -vE "$BENIGN" \
            | grep -iE 'error|fatal|invalid|unable|not found|refused' | head -1)
    echo "ERROR|${first:-$(printf '%s' "$out" | grep -vE "$BENIGN" | grep -viE '^[[:space:]]*$' | head -1)}"
}

for plugin in $plugins; do
    for flavor in mpich openmpi; do
        out=$(timeout "$T" srun $SRUN_FLAGS --mpi="$plugin" -N "$NODES" -n 2 \
                  singularity exec $bind "$sif" \
                  "/opt/cactus-deps/bin/pmi-test-$flavor" 2>&1)
        rc=$?
        res=$(classify "$rc" "$out")
        last_out="$out"; last_combo="--mpi=$plugin + $flavor"
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
    echo
    echo "Full output of the last one tried ($last_combo), so the reason is"
    echo "visible rather than reduced to one line:"
    printf '%s\n' "${last_out:-(no output)}" | tail -25 | sed 's/^/    /'
fi

# The env-stripping failure, demonstrated rather than asserted: srun passes
# the PMI handshake entirely through environment variables.
if [ -n "$best" ]; then
    p="${best#--mpi=}"; p="${p%% *}"; f="${best##*+ }"
    out=$(timeout "$T" srun $SRUN_FLAGS --mpi="$p" -N "$NODES" -n 2 \
              singularity exec --cleanenv $bind "$sif" \
              "/opt/cactus-deps/bin/pmi-test-$f" 2>&1); rc=$?
    res=$(classify "$rc" "$out")
    echo "same combination with --cleanenv: ${res%%|*} ${res#*|}"
fi

[ "$any_pass" = 1 ]
