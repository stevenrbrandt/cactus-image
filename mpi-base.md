# mpi-base

A minimal container image carrying two complete MPI stacks and the machinery
for launching ranks across a cluster. Nothing in it is specific to Cactus or
the Einstein Toolkit; it exists to be built on.

```
669 MB (bookworm)   921 MB (trixie)   669 MB (bookworm-arm64)
```

## Why two MPIs

Which MPI a site can bootstrap is a property of the site, not of your
program. A cluster's `srun --mpi=` plugins may start one implementation and
silently fail the other — and it fails in the worst possible way: every task
comes up as rank 0 of its own 1-rank world, so the job *appears* to run, at
N times the cost and with none of the communication.

Measured on a two-node Slurm cluster, one binary, both flavors:

| plugin | flavor | result | |
|---|---|---|---|
| `pmi2` | mpich | **PASS** | |
| `pmi2` | openmpi | ERROR | `OPAL ERROR: Unreachable ext3x_client.c:112` |
| `pmix` | mpich | SPLIT | ran as independent 1-rank jobs |
| `pmix` | openmpi | **PASS** | |
| `pmix_v5` | mpich | SPLIT | |
| `pmix_v5` | openmpi | **PASS** | |
| `cray_shasta`, `none` | either | SPLIT / ERROR | |

Six of ten combinations fail and only four fail loudly. Shipping both MPIs
means there is always something to fall back to; `mpi-matrix.sh` tells you
which.

## What is in it

| path | |
|---|---|
| `/opt/mpi/openmpi`, `/opt/mpi/mpich` | self-consistent prefixes: `bin/`, `include/`, `lib/` |
| `pmi-test-openmpi`, `pmi-test-mpich` | two-rank message-exchange test (on `PATH`) |
| `mpi-matrix.sh` | report which `--mpi=` plugin / flavor pairs work on this machine |
| `mpirun.py` | launch across a Slurm allocation over ssh, bypassing PMI entirely |
| `singssh` | the ssh launcher `mpirun.py` hands to Hydra; re-enters the image per node |
| `unslurm.py` | expand `$SLURM_NODELIST` into explicit host names |

Debian's MPI packages are used rather than compiled ones because they are
built `--with-pmix`/`--with-slurm` (OpenMPI) and `--with-slurm` (MPICH, with
hydra linked against libslurm) — the integration a cluster actually needs.

## Why the prefixes exist

Debian puts both MPIs in one namespace. Headers and libraries are separated,
but the binaries all land in `/usr/bin` with `.openmpi`/`.mpich` suffixes,
and the unsuffixed names are a single `update-alternatives` symlink pointing
at **one** implementation. A bare `/usr` therefore silently means "OpenMPI"
to anything resolving generic names — including CMake's `FindMPI`, which
given no hints resolves `/usr/bin/mpicc` → alternatives → OpenMPI
unconditionally. A consumer passing only `-I<mpich include dir>` gets MPICH
headers with OpenMPI libraries: an ABI mismatch that compiles cleanly and
then misbehaves.

`/opt/mpi/<flavor>` gives each implementation a real root, so `MPI_HOME`
names exactly one and nothing has to guess.

## Building on it

```dockerfile
ARG MPI_BASE=stevenrbrandt/mpi-base:bookworm
FROM ${MPI_BASE}

# Build against one flavor explicitly. Never the bare mpicc.
RUN /opt/mpi/mpich/bin/mpicc -O2 -o /usr/local/bin/myprog myprog.c
```

`ARG MPI_BASE` rather than a literal `FROM` because one tag cannot serve
every consumer: pick `:bookworm`, `:trixie`, or `:bookworm-arm64` to match
your own base. This repo's three Cactus images do exactly this.

If you need both flavors, build your application twice into separate
prefixes, once per `/opt/mpi/<flavor>`, the way the Cactus images build
AMReX/ADIOS2/openPMD per flavor.

Verify the base is really underneath, so a mistyped tag fails at build time
rather than at launch:

```dockerfile
RUN for t in mpirun.py singssh mpi-matrix.sh pmi-test-mpich; do \
        command -v "$t" >/dev/null || { echo "ERROR: $t missing" >&2; exit 1; }; \
    done && \
    /opt/mpi/mpich/bin/mpirun -np 2 pmi-test-mpich | grep -q "PMI-TEST: PASS"
```

## Finding out what works on a machine

`mpi-matrix.sh` ships inside the image but runs **outside** it — `srun` and
`singularity` live on the host. `--emit` hands back its own source, so the
probe can never be version-skewed against the binaries it launches:

```bash
singularity exec image.sif mpi-matrix.sh --emit > mpi-matrix.sh
chmod +x mpi-matrix.sh
./mpi-matrix.sh image.sif "--bind /work" -A <account> -p <partition>
```

Outcomes: `PASS`, `SPLIT` (tasks ran as independent 1-rank jobs — the
failure that looks like success), `HANG`, `ERROR` (the launch itself
failed), `NOJOB` (the scheduler refused the allocation; nothing about MPI
was tested).

Do this *before* building your application, so you build against a flavor
the site can bootstrap.

## Launching

**Over the site's PMI**, from outside the image:

```bash
srun --mpi=pmi2 -N 2 -n 8 singularity exec --bind /work image.sif ./myprog
```

Never add `--cleanenv`: Slurm passes the PMI handshake purely through
environment variables, and stripping them produces `SPLIT`.

**Over ssh**, when no plugin works — `mpirun.py` re-enters the image on each
node and does not use the site's PMI at all. It runs from inside the image,
within an allocation:

```bash
salloc -N 2 -n 8 -A <account> -p <partition>

export MPI_FLAVOR=mpich                 # must match what you built against
export SINGSSH_IMAGE=/path/image.sif    # a path visible on every node
export SINGSSH_EXEC_ARGS="--bind /work" # the remote exec inherits none of yours

singularity exec --bind /work image.sif mpirun.py -n 8 ./myprog
```

`mpirun.py` currently drives MPICH's Hydra. With OpenMPI it stops with an
explanation rather than launching, because OpenMPI would ignore the launcher
and start ranks *outside* the container — a silent failure rather than a
loud one.

## Environment reference

| variable | |
|---|---|
| `MPI_FLAVOR` | `mpich` or `openmpi`; selects `/opt/mpi/<flavor>/bin/mpirun` |
| `MPI_CMD` | explicit path to an mpirun, overriding `MPI_FLAVOR` |
| `SINGSSH_IMAGE` | image the remote ranks should enter — **required** where the runtime FUSE-mounts (`INFO: Mounting image with FUSE`), because `SINGULARITY_CONTAINER` then names a node-local rootfs |
| `SINGSSH_EXEC_ARGS` | flags for the remote `singularity exec`; derived from `SINGULARITY_BIND` and `/dev/nvidia*` if unset |
| `SINGSSH_SSH_OPTS` | ssh options; defaults suit launching inside an allocation (`BatchMode`, no host-key checking) because the image has no `known_hosts` |
| `MPI_MATRIX_SRUN_FLAGS` | extra srun flags, same as `--srun-flags` |
| `MPI_MATRIX_TIMEOUT`, `MPI_MATRIX_NODES` | per-combination timeout and node count |
| `MPIRUN_DRY_RUN`, `SINGSSH_DRY_RUN` | print the command instead of running it |

## Building the image itself

```bash
cd mpi-base
docker build -t mpi-base:bookworm .
docker build -t mpi-base:trixie --build-arg BASE_IMAGE=python:3.14-slim-trixie .
docker build --platform linux/arm64 -t mpi-base:bookworm-arm64 .
```

The build asserts its own behavior: both prefixes resolve, a 2-rank job runs
through each, `unslurm.py` expands compound nodelists, `singssh` drops
Hydra's `--external-launcher` and rejects a node-local FUSE rootfs, and
`mpirun.py` builds the right Hydra command line and completes a real 2-rank
launch.

## Limits

- `mpirun.py`'s ssh route is MPICH-only.
- The ssh route assumes passwordless ssh between allocated nodes.
- Tested on Debian-family bases; the prefix builder reads `mpicc.<flavor>
  -show` rather than assuming paths, but it has only been run against
  Debian's packaging.
