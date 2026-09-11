# Cactus / Einstein Toolkit container images

Container images for building and running the [Einstein
Toolkit](https://einsteintoolkit.org) (Cactus, Carpet, CarpetX) on HPC
systems through Singularity/Apptainer, plus the tooling needed to launch
them across multiple nodes and a two-node test cluster for exercising all
of it locally.

The images ship the **dependencies** and a matching Cactus optionlist, but
deliberately **not a built Cactus**: the build is left to run inside the
container on the target machine, so the compiler can tune for the hardware
actually present. NSIMD is likewise not prebuilt, since its SIMD ISA is
hardware specific.

Every image contains **two complete MPI stacks**, MPICH and OpenMPI, each
with its own optionlist, its own `/opt/mpi/<flavor>` prefix and its own
prebuilt AMReX / ADIOS2 / openPMD. Which one works is a property of the
site: a cluster's `srun --mpi=` plugins may bootstrap one and silently fail
the other.

## Images

| directory  | base / toolkit                  | GPU arch      | state |
|------------|---------------------------------|---------------|-------|
| `x86-cpu`  | Debian trixie                   | —             | built |
| `x86-cuda` | Debian bookworm, CUDA 12.9      | sm_70, sm_80  | built |
| `arm-cuda` | Debian bookworm, CUDA 13.4, sbsa | sm_90        | written; build not yet verified |
| x86 + HIP  | —                               | —             | planned, see `images.md` |

`x86-cuda` pins CUDA 12.9 because sm_70 (Volta) support is required, and
prebuilds AMReX for `sm_70` and `sm_80`.

`arm-cuda` targets Grace Hopper (aarch64, sm_90) and is on CUDA 13 because
it has to be: NVIDIA's `debian12/sbsa` repo publishes only CUDA 13.x, with
no 12.x at all. That costs nothing here, since sm_70 was the only reason
for the 12.9 pin — but it does mean `arm-cuda` cannot target Volta, and the
build asserts that `sm_70` is rejected so the image cannot silently drift
from what its optionlists claim.

Each image directory holds a `Dockerfile`, a `docker-compose.yml`, one
optionlist per MPI flavor, and the check scripts the build runs against
itself.

## Tools inside the image

Installed in `/usr/local/bin`:

| tool | what it is for |
|------|----------------|
| `mpirun.py`     | launch across a SLURM allocation over ssh, bypassing the site's PMI entirely |
| `singssh`       | the ssh launcher `mpirun.py` gives to Hydra; re-enters the image on each node |
| `unslurm.py`    | expand `$SLURM_NODELIST` into explicit host names |
| `mpi-matrix.sh` | report which `srun --mpi=` plugin / MPI flavor pairs actually bootstrap here |
| `sim-config.sh` | generate a SimFactory machine configuration that builds and runs via the image |
| `hostname`      | shim reporting `<image>-<real hostname>`, so a shell can tell it is inside |

`mpi-matrix.sh` and `sim-config.sh` run *outside* the container but ship
inside it; `--emit` prints their source so they can be lifted out of any
image and cannot drift from the binaries they drive:

```bash
singularity exec cactus-cuda.simg mpi-matrix.sh --emit > mpi-matrix.sh
chmod +x mpi-matrix.sh
salloc -N 2 -n 2 && ./mpi-matrix.sh /path/to/cactus-cuda.simg
```

## Quick start

`QUICKSTART.md` walks through building and running Cactus with these images
without SimFactory: `make` inside the container, then `srun`, `mpirun` or
`mpirun.py` depending on the machine.

## Two ways to launch, and why there are two

**Over SLURM's PMI** — the normal route, but which plugin works varies by
site, and a mismatched one does not error: every task comes up as rank 0 of
its own 1-rank world.

```bash
srun --mpi=pmi2 -N 2 -n 2 singularity exec --bind /work image.simg ./cactus_sim par.par
```

Never add `--cleanenv`: srun passes the PMI handshake purely through
environment variables.

**Over ssh, from inside the image** — bootstraps through `singssh` and does
not depend on the site's PMI at all.

```bash
export MPI_FLAVOR=mpich
export SINGSSH_IMAGE=/work/you/images/cactus-cuda.simg
export SINGSSH_EXEC_ARGS="--nv --bind /work --bind /project"
singularity exec $SINGSSH_EXEC_ARGS "$SINGSSH_IMAGE" mpirun.py -n 4 ./cactus_sim par.par
```

`SINGSSH_IMAGE` is needed wherever the runtime FUSE-mounts the image
(SingularityCE prints `INFO: Mounting image with FUSE`), because it then
reports a node-local extracted rootfs in `SINGULARITY_CONTAINER` rather
than the `.simg` path.

## SimFactory

`sim-config.sh` generates the four files SimFactory needs, with the
optionlist extracted from the image itself so it cannot fall out of step
with the paths inside it:

```bash
sim-config.sh --machine db-sing-cuda \
  --image /work/you/images/cactus-cuda.simg \
  --flavor openmpi --mpi pmix_v4 \
  --sing-flags "--nv --bind /work --bind /project" \
  --allocation myalloc --partition gpu2 --gpus-per-task 1
```

## Test cluster

`cluster/` is a two-node SLURM cluster in Docker, with a shared filesystem
and Singularity, for exercising the multi-node paths without an
allocation. See `cluster/README.md`.

```bash
cd cluster
docker compose up -d --build
./load-image.sh stevenrbrandt/cactus-cuda cactus-cuda
./smoke.sh cactus-cuda
```

It has no GPU, so `--nv` and CUDA kernel execution cannot be tested there;
CUDA compilation can.

## License

GPL version 2 or later, matching the licence most Einstein Toolkit
components use (Carpet, EinsteinExact, CTThorns). Note the Cactus flesh is
LGPL v2 and CarpetX is LGPL v3; nothing from either is redistributed here.
See `LICENSE`.
