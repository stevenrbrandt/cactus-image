#!/bin/bash
# End-to-end test of a Singularity image on the two-node cluster.
#
#   ./load-image.sh stevenrbrandt/cactus-cuda cactus-cuda
#   ./smoke.sh cactus-cuda
#
# Two launch paths have to work, and they are independent:
#
#   (1) mpirun.py from inside a running image inside a running SLURM job.
#       Bootstraps over ssh via singssh, so it does not care what the site's
#       PMI situation is. This is a hard requirement -- it is our own code.
#
#   (2) srun -n N singularity exec <image> cactus_sim ...
#       Bootstraps over SLURM's PMI. WHICH --mpi= plugin works is a property
#       of the site, not of the image: on Deep Bayou only OpenMPI with
#       pmix_v4 works and pmix_v5 hangs. So the requirement here is that at
#       least one combination works, and mpi-matrix.sh reports the rest.
set -uo pipefail

name="${1:-cactus-cuda}"
sif="/work/images/${name}.sif"
bind="--bind /work"
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -12 | sed 's/^/          /'; fail=$((fail+1)); }
run() { timeout "${2:-300}" docker compose exec -T --user sbrandt node1 bash -lc "$1" 2>&1; }

echo "== cluster =="
out=$(run "sinfo -h -o '%D %t'")
[ "$out" = "2 idle" ] && ok "two nodes idle" || bad "two nodes idle" "$out"

echo "== image =="
out=$(run "srun -N 2 -n 2 singularity exec $bind $sif hostname")
[ "$(printf '%s' "$out" | sort -u | wc -l)" = 2 ] && ok "runs on both nodes: $(echo $out)" \
    || bad "runs on both nodes" "$out"
printf '%s' "$out" | grep -q "^${name}-node" \
    && ok "hostname shim reports ${name}-<node>" || bad "hostname shim" "$out"

out=$(run "LANG=en_US.UTF-8 srun -N 1 -n 1 singularity exec $bind $sif perl -e 'print 1'")
printf '%s' "$out" | grep -q 'Setting locale failed' \
    && bad "no perl locale warning" "$out" || ok "no perl locale warning"

echo
echo "== path 2: srun + singularity, over SLURM's PMI =="
# Extract the probe from the image under test, so the matrix and the
# pmi-test binaries it launches always come from the same build.
run "singularity exec $bind $sif mpi-matrix.sh --emit > /work/mpi-matrix.sh && chmod +x /work/mpi-matrix.sh" 120 >/dev/null
matrix=$(run "/work/mpi-matrix.sh $sif '$bind'" 1200)
printf '%s\n' "$matrix" | sed 's/^/  /'
printf '%s' "$matrix" | grep -q '^working combination' \
    && ok "at least one --mpi= combination bootstraps 2 ranks" \
    || bad "no --mpi= combination works" ""

echo
echo "== path 1: mpirun.py from inside the image, over singssh =="
out=$(run "salloc -N 2 -n 2 --quiet singularity exec $bind $sif \
           env MPI_FLAVOR=mpich SINGSSH_EXEC_ARGS='$bind' \
           mpirun.py /opt/cactus-deps/bin/pmi-test-mpich" 600)
printf '%s' "$out" | grep -q 'PMI-TEST: PASS' \
    && ok "mpirun.py: 2-rank message exchange" || bad "mpirun.py: 2-rank message exchange" "$out"

out=$(run "salloc -N 2 -n 2 --quiet singularity exec $bind $sif \
           env MPI_FLAVOR=mpich SINGSSH_EXEC_ARGS='$bind' \
           mpirun.py hostname" 600)
n=$(printf '%s' "$out" | grep -c "^${name}-node")
u=$(printf '%s' "$out" | grep "^${name}-node" | sort -u | wc -l)
{ [ "$n" -ge 2 ] && [ "$u" -ge 2 ]; } \
    && ok "mpirun.py ranks landed on distinct nodes: $(echo $out)" \
    || bad "mpirun.py ranks on distinct nodes" "$out"

# No SINGSSH_EXEC_ARGS: singssh must recover the binds from the runtime's
# own SINGULARITY_BIND. This is the path a user gets when they forget to
# export it -- which is easy, because the remote singularity exec inherits
# none of the flags used to enter the container here.
out=$(run "salloc -N 2 -n 2 --quiet singularity exec $bind $sif \
           env MPI_FLAVOR=mpich mpirun.py /opt/cactus-deps/bin/pmi-test-mpich" 600)
printf '%s' "$out" | grep -q 'PMI-TEST: PASS' \
    && ok "mpirun.py with binds auto-derived (no SINGSSH_EXEC_ARGS)" \
    || bad "mpirun.py with binds auto-derived" "$out"

# A node-local FUSE rootfs in SINGULARITY_CONTAINER (as SingularityCE
# reports on Deep Bayou) must fail fast with a clear message, not launch.
out=$(run "singularity exec $bind $sif env SINGULARITY_CONTAINER=/tmp/rootfs-123/root \
           MPI_FLAVOR=mpich singssh --print-image" 120)
printf '%s' "$out" | grep -q 'not a shared image file' \
    && ok "FUSE rootfs path rejected with a diagnosis" \
    || bad "FUSE rootfs path rejected" "$out"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
