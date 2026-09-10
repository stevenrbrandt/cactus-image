#!/bin/bash
#
# Generate a SimFactory machine configuration that builds and runs Cactus
# through a Singularity image, from OUTSIDE the image, with srun.
#
# It writes the four files SimFactory needs, into an mdb tree:
#
#   mdb/machines/<name>.ini      make = <prefix> singularity exec … make
#   mdb/optionlists/<name>.cfg   extracted FROM the image
#   mdb/runscripts/<name>.run    srun --mpi=<plugin> … singularity exec … cactus
#   mdb/submitscripts/<name>.sub plain sbatch header
#
# The optionlist is copied out of the image rather than written from a
# template, so the paths it names (/opt/cactus-deps/..., /opt/mpi/...) are
# guaranteed to be the ones inside the image that will actually be used.
# That is the single most common way these configurations rot.
#
# Usage:
#   sim-config.sh --machine db-sing-cuda \
#                 --image /work/sbrandt/images/cactus-cuda.simg \
#                 --flavor openmpi --mpi pmix_v4 \
#                 --sing-flags "--nv --bind /work --bind /project" \
#                 --allocation hpc_smalltest --partition gpu2
#
# --emit prints this script's own source (it ships inside the image).
set -uo pipefail

if [ "${1:-}" = "--emit" ]; then cat "$0"; exit 0; fi

die() { echo "sim-config.sh: $*" >&2; exit 1; }
warn() { echo "sim-config.sh: warning: $*" >&2; }

machine=""; image=""; mpi=""; sing_flags=""; flavor=""
exec_prefix=""; optionlist_file=""
partition=""; allocation=""; ppn=48; num_threads=48; memory=196608; nodes=1
maxwalltime="24:00:00"; basedir=""; sourcebasedir=""; gpus_per_task=""
outdir=""; dry_run=""; location="unspecified"
# SimFactory splices this into `{ <envsetup> ; } && { cd … && make … }`, so
# an empty block is not "no setup" -- it is a bash syntax error:
#     /bin/bash: -c: line 0: syntax error near unexpected token `;'
#     `{ ; } && { cd /work/…/Cactus && … }'
# `true` is the no-op that keeps the construct valid. Sites needing module
# commands pass --envsetup "module purge; module load ...".
envsetup="true"

while [ $# -gt 0 ]; do
    case "$1" in
        --machine)        machine="$2"; shift 2 ;;
        --image)          image="$2"; shift 2 ;;
        --mpi)            mpi="$2"; shift 2 ;;
        --sing-flags)     sing_flags="$2"; shift 2 ;;
        --flavor)         flavor="$2"; shift 2 ;;
        --exec-prefix)    exec_prefix="$2"; shift 2 ;;
        --optionlist)     optionlist_file="$2"; shift 2 ;;
        --partition)      partition="$2"; shift 2 ;;
        --allocation)     allocation="$2"; shift 2 ;;
        --ppn)            ppn="$2"; shift 2 ;;
        --num-threads)    num_threads="$2"; shift 2 ;;
        --memory)         memory="$2"; shift 2 ;;
        --nodes)          nodes="$2"; shift 2 ;;
        --maxwalltime)    maxwalltime="$2"; shift 2 ;;
        --basedir)        basedir="$2"; shift 2 ;;
        --sourcebasedir)  sourcebasedir="$2"; shift 2 ;;
        --gpus-per-task)  gpus_per_task="$2"; shift 2 ;;
        --location)       location="$2"; shift 2 ;;
        --envsetup)       envsetup="$2"; shift 2 ;;
        --outdir)         outdir="$2"; shift 2 ;;
        --dry-run)        dry_run=1; shift ;;
        -h|--help)        sed -n '2,32p' "$0"; exit 0 ;;
        *)                die "unknown option $1 (try --help)" ;;
    esac
done

[ -n "$machine" ] || die "--machine is required"
[ -n "$image" ]   || die "--image is required"
[ -n "$mpi" ]     || die "--mpi is required (the value for srun --mpi=)"

case "$image" in /*) ;; *) die "--image must be an absolute path: every
             compute node has to resolve it identically" ;; esac

# --- which MPI flavor -------------------------------------------------------
# Required, not inferred. The image ships an MPICH build and an OpenMPI
# build side by side, with a separate optionlist and a separate
# /opt/cactus-deps tree for each, so this choice decides which Cactus gets
# built -- it is not merely a launch detail.
#
# It is deliberately not derived from --mpi: while pmix normally means
# OpenMPI and pmi2 normally means MPICH, OpenMPI can be built against pmi2,
# and sites do unusual things. Guessing wrong does not fail loudly; the job
# starts and every task comes up as rank 0 of its own 1-rank world.
[ -n "$flavor" ] || die "--flavor is required: openmpi or mpich.
         It selects which of the image's two MPI builds to use (its
         optionlist, its /opt/mpi prefix and its prebuilt AMReX/ADIOS2).
         Usually --mpi=pmix* goes with --flavor openmpi, and --mpi=pmi2
         with --flavor mpich; run mpi-matrix.sh against the image to see
         which pairs actually bootstrap on this machine."
case "$flavor" in openmpi|mpich) ;; *) die "--flavor must be openmpi or mpich, not '$flavor'" ;; esac

# See the note where envsetup is defined: empty is a syntax error downstream.
[ -n "$(printf '%s' "$envsetup" | tr -d '[:space:]')" ] \
    || die "--envsetup must not be empty; SimFactory splices it into
         '{ <envsetup> ; } && { ... }' and an empty block is a bash syntax
         error. Use 'true' for no setup at all."

# Cross-check the pairing rather than enforce it: unusual combinations are
# legitimate, but an accidental mismatch is worth a word.
case "$mpi:$flavor" in
    pmix*:openmpi|pmi2:mpich|pmi1:mpich) ;;
    *) warn "--mpi=$mpi with --flavor=$flavor is an unusual pairing."
       warn "  Normally pmix* goes with openmpi and pmi2 with mpich."
       warn "  If that is deliberate, carry on; if not, the job will run as"
       warn "  N independent 1-rank jobs rather than failing." ;;
esac

# --- sanity checks that catch the usual silent failures ---------------------
if command -v srun >/dev/null 2>&1; then
    if srun --mpi=list 2>&1 | grep -qw -- "$mpi"; then
        echo "==> srun offers --mpi=$mpi"
    else
        warn "srun --mpi=list does not list '$mpi' here. Offered:"
        srun --mpi=list 2>&1 | sed 's/^/             /' >&2
        warn "if this is a login node with a different Slurm build, ignore it;"
        warn "otherwise run mpi-matrix.sh to find a combination that works."
    fi
fi

# A bind list that omits the filesystem holding the build tree or the
# simulations is the other classic: the job starts, then cannot find the
# executable. Check the top-level directory of each path we are told about.
check_bound() {
    local path="$1" what="$2" top
    [ -n "$path" ] || return 0
    top="/$(printf '%s' "${path#/}" | cut -d/ -f1)"
    case " $sing_flags " in
        *" $top "*|*"$top:"*) ;;
        *) warn "$what is under $top, but --sing-flags does not bind $top."
           warn "  Cactus will not find its files inside the container." ;;
    esac
}
check_bound "$basedir" "basedir"
check_bound "$sourcebasedir" "sourcebasedir"
# The image itself needs no bind: singularity resolves that path on the host
# before it ever enters the container.

# --- locate the mdb tree ----------------------------------------------------
if [ -z "$outdir" ]; then
    for c in ./simfactory/mdb ./Cactus/simfactory/mdb ../simfactory/mdb; do
        [ -d "$c" ] && { outdir="$c"; break; }
    done
fi
[ -n "$outdir" ] || die "cannot find a simfactory mdb directory; pass --outdir <Cactus>/simfactory/mdb"
[ -d "$outdir" ] || die "--outdir $outdir does not exist"
for d in machines optionlists runscripts submitscripts; do
    [ -d "$outdir/$d" ] || die "$outdir/$d does not exist -- is $outdir really a simfactory mdb tree?"
done

# --- the optionlist, taken from the image itself ----------------------------
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "$optionlist_file" ]; then
    cp "$optionlist_file" "$tmp/ol.cfg" || die "cannot read --optionlist $optionlist_file"
    echo "==> optionlist taken from $optionlist_file"
else
    echo "==> extracting the $flavor optionlist from $image"
    # Deep Bayou (and others) only install singularity on compute nodes, so
    # this may need to go through srun: --exec-prefix "srun -A acct -p gpu2 -n 1"
    found=$($exec_prefix singularity exec "$image" \
              sh -c 'ls /opt/cactus-deps/*.cfg 2>/dev/null' 2>/dev/null \
            | grep -- "-$flavor\.cfg$" | head -1)
    [ -n "$found" ] || die "no *-$flavor.cfg found in $image under /opt/cactus-deps.
         If singularity is unavailable here, pass --exec-prefix 'srun …',
         or supply the file directly with --optionlist."
    $exec_prefix singularity exec "$image" cat "$found" > "$tmp/ol.cfg" \
        || die "failed to read $found out of the image"
    [ -s "$tmp/ol.cfg" ] || die "extracted an empty optionlist from $found"
    echo "    $found"
fi

# --- assemble ---------------------------------------------------------------
sing="singularity exec $sing_flags $image"
[ -n "$allocation" ] && alloc_flag=" -A @ALLOCATION@" || alloc_flag=""
[ -n "$partition" ]  && part_flag=" -p $partition"    || part_flag=""
[ -n "$gpus_per_task" ] && gpu_run=" --gpus-per-task $gpus_per_task" || gpu_run=""
[ -n "$gpus_per_task" ] && gpu_sub="#SBATCH --gpus-per-task $gpus_per_task" || gpu_sub="#"
: "${basedir:=/work/@USER@/simulations}"
: "${sourcebasedir:=/work/@USER@}"

ini="$outdir/machines/$machine.ini"
cfg="$outdir/optionlists/$machine.cfg"
run="$outdir/runscripts/$machine.run"
sub="$outdir/submitscripts/$machine.sub"

write() { if [ -n "$dry_run" ]; then echo "--- would write $1 ---"; cat; else cat > "$1"; fi; }

write "$ini" <<EOF
[$machine]
# Generated by sim-config.sh. Cactus is built and run through a Singularity
# image, invoked from outside the container:
#   image   $image
#   mpi     srun --mpi=$mpi  ($flavor build)
#   flags   $sing_flags
# Regenerate rather than hand-edit, so the optionlist stays in step with the
# image it was taken from.

nickname        = $machine
name            = $machine
location        = $location
description     = Cactus via Singularity ($(basename "$image")), srun --mpi=$mpi
status          = production

hostname        = $machine
aliaspattern    = ^$machine

# Spliced into `{ ... ; } && { cd ... && make ... }`, so it must not be
# empty -- an empty block is a bash syntax error, not a no-op.
envsetup        = <<EOT
$envsetup
EOT

sourcebasedir   = $sourcebasedir
basedir         = $basedir

optionlist      = $machine.cfg
submitscript    = $machine.sub
runscript       = $machine.run

# Build inside the image. The prefix exists because some sites install
# singularity only on the compute nodes, so make has to be shipped there.
make            = ${exec_prefix:+$exec_prefix }$sing make -j@MAKEJOBS@

ppn             = $ppn
max-num-threads = $ppn
num-threads     = $num_threads
memory          = $memory
nodes           = $nodes
queue           = $partition
allocation      = $allocation
maxwalltime     = $maxwalltime

submit          = sbatch @SCRIPTFILE@ 2>&1
getstatus       = squeue -j @JOB_ID@
stop            = scancel @JOB_ID@
submitpattern   = Submitted batch job (\\d+)
statuspattern   = '@JOB_ID@ '
queuedpattern   = ' PD '
runningpattern  = ' (CF|CG|R|TO) '
holdingpattern  = '\\(JobHeldUser\\)'
exechost        = hostname -s
exechostpattern = (\\S+)
stdout          = cat @SIMULATION_NAME@.out
stderr          = cat @SIMULATION_NAME@.err
stdout-follow   = tail -n 100 -f @SIMULATION_NAME@.out @SIMULATION_NAME@.err
EOF

write "$run" <<EOF
#! /bin/bash
# Generated by sim-config.sh -- runs Cactus inside $image via srun.
echo "Preparing:"
set -x
set -e

cd @RUNDIR@-active

echo "Checking:"
pwd
hostname
date

echo "Environment:"
export CACTUS_NUM_PROCS=@NUM_PROCS@
export CACTUS_NUM_THREADS=@NUM_THREADS@
export OMP_NUM_THREADS=@NUM_THREADS@
export OMP_PLACES=cores
export TESTSUITE_NPROCS=@NUM_PROCS@
env | sort > SIMFACTORY/ENVIRONMENT

# Fail here rather than as N single-rank jobs: if the plugin this
# configuration was generated for is not offered, srun silently declines to
# bootstrap MPI and every task becomes rank 0 of its own world.
if ! srun --mpi=list 2>&1 | grep -qw -- "$mpi"; then
    echo "ERROR: srun does not offer --mpi=$mpi on this machine." >&2
    echo "       Offered here:" >&2
    srun --mpi=list 2>&1 | sed 's/^/         /' >&2
    echo "       Run mpi-matrix.sh against the image to find a working" >&2
    echo "       plugin/flavor pair, then regenerate this machine entry." >&2
    exit 1
fi

echo "Starting:"
export CACTUS_STARTTIME=\$(date +%s)

# NOTE: no --cleanenv. srun hands the PMI handshake to the ranks purely
# through environment variables, and --cleanenv drops them before the
# container sees them -- which shows up as "Need exactly 2 ranks", or as a
# job that runs with every task believing it is alone.
time srun -u --mpi=$mpi$alloc_flag$part_flag \\
    -N @NODES@ -n @NUM_PROCS@ \\
    --cpus-per-task @NUM_THREADS@$gpu_run \\
    $sing \\
    @EXECUTABLE@ -L 3 @PARFILE@

echo "Stopping:"
date
echo "Done."
EOF

write "$sub" <<EOF
#! /bin/bash
# Generated by sim-config.sh
#SBATCH -A @ALLOCATION@
#SBATCH -p @QUEUE@
#SBATCH -t @WALLTIME@
#SBATCH -N @NODES@ -n @NUM_PROCS@
#SBATCH --cpus-per-task @NUM_THREADS@
$gpu_sub
#SBATCH @("@CHAINED_JOB_ID@" != "" ? "-d afterany:@CHAINED_JOB_ID@" : "")@
#SBATCH -J @SHORT_SIMULATION_NAME@
#SBATCH -o @RUNDIR@/@SIMULATION_NAME@.out
#SBATCH -e @RUNDIR@/@SIMULATION_NAME@.err
cd @SOURCEDIR@
@SIMFACTORY@ run @SIMULATION_NAME@ --basedir=@BASEDIR@ --restart-id=@RESTART_ID@ @FROM_RESTART_COMMAND@
EOF

if [ -n "$dry_run" ]; then
    echo "--- would write $cfg (extracted optionlist, $(wc -l < "$tmp/ol.cfg") lines) ---"
else
    cp "$tmp/ol.cfg" "$cfg"
    chmod +x "$run" 2>/dev/null
    echo
    echo "wrote:"
    for f in "$ini" "$cfg" "$run" "$sub"; do echo "  $f"; done
    echo
    echo "next:"
    echo "  ./simfactory/bin/sim setup                      # if not done yet"
    echo "  ./simfactory/bin/sim build --machine=$machine --thornlist=<list>"
    echo "  ./simfactory/bin/sim create-submit <name> --machine=$machine \\"
    echo "        --parfile=<par> --procs=<n> --num-threads=$num_threads --walltime=1:00:00"
fi
