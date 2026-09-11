# Quick start: build and run Cactus with these images

Build with `make` inside the container, then launch with `mpirun`, `srun`,
or `mpirun.py` depending on the machine.

Two shell variables stand for the choices you have to make:

```bash
IMG=/work/$USER/images/cactus-cuda.simg      # the image
FLAGS="--nv --bind /work --bind /project"    # binds it needs; --nv for GPU
NCPUS=$(nproc)
```

`FLAGS` must bind every filesystem holding your Cactus tree, your parameter
files and your output. Apart from `$HOME`, `/tmp` and the current
directory, nothing is visible inside the container unless you bind it.

## 1. Get Cactus

```bash
curl -kLO https://raw.githubusercontent.com/gridaphobe/CRL/ET_2026_05/GetComponents
chmod +x GetComponents
./GetComponents --parallel \
  https://bitbucket.org/einsteintoolkit/manifest/raw/ET_2026_05/einsteintoolkit.th
cd Cactus
```

## 2. Build

Each image ships one optionlist per MPI flavor, already pointing at its own
dependencies:

| image             | MPICH                                        | OpenMPI                                        |
|-------------------|----------------------------------------------|------------------------------------------------|
| `cactus`          | `/opt/cactus-deps/cactus-mpich.cfg`          | `/opt/cactus-deps/cactus-openmpi.cfg`          |
| `cactus-cuda`     | `/opt/cactus-deps/cactus-cuda-mpich.cfg`     | `/opt/cactus-deps/cactus-cuda-openmpi.cfg`     |
| `cactus-arm-cuda` | `/opt/cactus-deps/cactus-arm-cuda-mpich.cfg` | `/opt/cactus-deps/cactus-arm-cuda-openmpi.cfg` |

The build runs **inside** the container, because the optionlist names paths
(`/opt/cactus-deps`, `/opt/mpi`) that exist only there:

```bash
singularity exec $FLAGS $IMG \
    make -j${NCPUS} sim PROMPT=no \
         THORNLIST=thornlists/einsteintoolkit.th \
         options=/opt/cactus-deps/cactus-cuda-mpich.cfg
```

That one command creates the configuration and builds it, leaving
`exe/cactus_sim`. `sim` is just a name; `exe/cactus_<name>` follows it.

`PROMPT=no` is not optional. Cactus defaults to `PROMPT=yes`, which asks
`Setup configuration sim (yes)?` on stdin and then stops after configuring
with "Use make sim to build the configuration" — so without it you get a
configured tree and no executable.

To rebuild later, the name alone is enough: `make -j${NCPUS} sim`.

Two things that bite on clusters:

- **Singularity may only exist on the compute nodes**, so `make` has to be
  shipped there. `-u` matters, or output arrives in blocks and a working
  build looks hung:

  ```bash
  srun -u -N 1 -n 1 -A <account> -p <partition> \
      singularity exec $FLAGS $IMG make -j${NCPUS} sim
  ```

- **Run one make, not N.** `srun -n 8 ... make` starts eight independent
  makes in one directory; they race and fail with things like
  `mv: cannot stat '.../thorn-X.files.tmp'`. Parallelism comes from `-j`.

## 3. Run it on a laptop or workstation

One machine, no batch system. Use the `mpirun` belonging to the flavor you
built against — the image has both, so the bare name is ambiguous:

```bash
export OMP_NUM_THREADS=4

singularity exec $FLAGS $IMG \
    /opt/mpi/mpich/bin/mpirun -np 4 ./exe/cactus_sim par/mypar.par
```

With Docker rather than Singularity, from a directory holding the repo's
`docker-compose.yml`:

```bash
docker compose exec cactus-cuda-service \
    /opt/mpi/mpich/bin/mpirun -np 4 ./exe/cactus_sim par/mypar.par
```

## 4. Run it on a cluster: two ways to launch

On a batch system there are two routes, and which one works is a property
of the site rather than of the image.

### (a) `srun`, using the site's PMI

Launched from **outside** the image: `srun` starts the ranks, and each one
enters the container.

```bash
srun --mpi=pmi2 -N 2 -n 8 -A <account> -p <partition> \
    singularity exec $FLAGS $IMG ./exe/cactus_sim par/mypar.par
```

The `--mpi=` value has to match the MPI you built against, and the site has
to support it. Getting it wrong usually does **not** produce an error:
every task comes up as rank 0 of its own 1-rank world and the job appears
to run normally.

`mpi-matrix.sh` reports which combinations actually work here. It ships in
the image but runs outside it:

```bash
singularity exec $FLAGS $IMG mpi-matrix.sh --emit > mpi-matrix.sh
chmod +x mpi-matrix.sh
./mpi-matrix.sh $IMG "$FLAGS" -A <account> -p <partition>
```

Ideally run this *before* building, so you build against a flavor the site
can bootstrap.

**Never add `--cleanenv`.** Slurm passes the PMI handshake to the ranks
purely through environment variables, and `--cleanenv` drops them before
the container sees them.

### (b) `mpirun.py`, over ssh

When no `--mpi=` combination works — or you would rather not depend on the
site's PMI — `mpirun.py` bootstraps over ssh, re-entering the image on each
node. It runs from **inside** the image, within an allocation:

```bash
salloc -N 2 -n 8 -A <account> -p <partition>

export MPI_FLAVOR=mpich            # must match what you built against
export SINGSSH_IMAGE=$IMG          # a path visible on every node
export SINGSSH_EXEC_ARGS="$FLAGS"  # the remote singularity inherits none of yours

singularity exec $FLAGS $IMG \
    mpirun.py -n 8 ./exe/cactus_sim par/mypar.par
```

`SINGSSH_IMAGE` is required wherever the runtime prints
`INFO: Mounting image with FUSE`: it then reports a node-local extracted
rootfs in `SINGULARITY_CONTAINER` rather than the image path, and the
remote ranks cannot open it.

`SINGSSH_EXEC_ARGS` matters for the same reason binds do: the remote
`singularity exec` gets none of the flags you used locally, so without it
the ranks start without `/work` and cannot find the executable.

## If it goes wrong

| symptom | cause |
|---------|-------|
| configured, but no executable | `PROMPT=no` missing from the build command |
| `Need exactly 2 ranks`, or every rank says it is rank 0 of 1 | PMI did not bootstrap: wrong `--mpi=`, or `--cleanenv` |
| ranks hang at startup | usually ssh in (b): no `known_hosts` inside the image, or a bad `SINGSSH_IMAGE` |
| `could not open image /tmp/rootfs-.../root` | set `SINGSSH_IMAGE` |
| executable or parfile "not found" inside the container | missing `--bind` in `FLAGS` / `SINGSSH_EXEC_ARGS` |
| `mv: cannot stat '...thorn-X.files.tmp'` | several `make`s at once; use `-n 1` and `-j` |
| build output arrives in bursts, looks hung | add `-u` to `srun` |
