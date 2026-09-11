# mpi-base

A minimal container image carrying two complete MPI stacks and the
machinery for launching ranks across a cluster. It has nothing to do with
Cactus, and other projects can build on it directly.

```
669 MB (bookworm) / 921 MB (trixie)
```

## Why two MPIs

Which MPI a site can bootstrap is a property of the site, not the
application. A cluster's `srun --mpi=` plugins may start one implementation
and silently fail the other — and the failure is silent in the worst way:
every task comes up as rank 0 of its own 1-rank world, so the job appears
to run. Shipping both means there is always something to fall back to.

Measured on a two-node Slurm cluster, the same binary, both flavors:

```
PLUGIN         FLAVOR     RESULT
pmi2           mpich      PASS
pmi2           openmpi    ERROR   OPAL ERROR: Unreachable ext3x_client.c:112
pmix           mpich      SPLIT   tasks ran as independent 1-rank jobs
pmix           openmpi    PASS
cray_shasta    mpich      SPLIT
none           mpich      SPLIT
```

Six of ten combinations fail, and only two of those fail loudly.

## Contents

| path | what |
|------|------|
| `/opt/mpi/openmpi`, `/opt/mpi/mpich` | self-consistent prefixes: `bin/`, `include/`, `lib/` |
| `/usr/local/bin/pmi-test-{openmpi,mpich}` | two-rank message-exchange test |
| `/usr/local/bin/mpi-matrix.sh` | report which `--mpi=` plugin / flavor pairs work here |
| `/usr/local/bin/mpirun.py` | launch across a Slurm allocation over ssh, bypassing PMI |
| `/usr/local/bin/singssh` | the ssh launcher `mpirun.py` hands to Hydra |
| `/usr/local/bin/unslurm.py` | expand `$SLURM_NODELIST` |

Debian's MPI packages are used rather than compiled ones because they are
built `--with-pmix`/`--with-slurm` (OpenMPI) and `--with-slurm` (MPICH,
hydra linked against libslurm) — the integration a cluster needs.

## The prefixes exist for a reason

Debian puts both MPIs in one namespace. Headers and libraries are already
separated, but the binaries all land in `/usr/bin` with `.openmpi`/`.mpich`
suffixes, and the unsuffixed names are a single `update-alternatives`
symlink pointing at **one** implementation. So a bare `/usr` silently means
"OpenMPI" to anything resolving generic names — including CMake's `FindMPI`,
which given no hints resolves `/usr/bin/mpicc` → alternatives → OpenMPI
unconditionally. A consumer passing only `-I<mpich include dir>` would get
MPICH headers with OpenMPI libraries: an ABI mismatch that compiles.

`/opt/mpi/<flavor>` gives each implementation a real root, so `MPI_HOME`
names exactly one and nothing guesses.

## Build

```bash
docker build -t mpi-base:bookworm .
docker build -t mpi-base:trixie --build-arg BASE_IMAGE=python:3.14-slim-trixie .
```

`BASE_IMAGE` exists so dependent images can match their own base; the
default is `python:3.14-slim-bookworm`.

## Use

```dockerfile
FROM mpi-base:bookworm
# ... your application, built against /opt/mpi/<flavor>
```

Find out what works on the target machine first — `mpi-matrix.sh` ships
inside the image but runs outside it:

```bash
singularity exec image.sif mpi-matrix.sh --emit > mpi-matrix.sh && chmod +x mpi-matrix.sh
./mpi-matrix.sh image.sif "--bind /work" -A <account> -p <partition>
```

If nothing passes, `mpirun.py` bootstraps over ssh instead and does not use
the site's PMI at all:

```bash
export MPI_FLAVOR=mpich SINGSSH_IMAGE=/path/image.sif SINGSSH_EXEC_ARGS="--bind /work"
singularity exec --bind /work image.sif mpirun.py -n 8 ./myprogram
```

Never add `--cleanenv`: Slurm passes the PMI handshake purely through
environment variables.
