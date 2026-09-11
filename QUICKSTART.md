# Quick start: build and run Cactus with these images

No SimFactory — just `make` inside the container, then `srun`, `mpirun`, or
`mpirun.py` depending on the machine. For the SimFactory route instead, see
`sim-config.sh` in the README.

Throughout, two shell variables stand for the choices you have to make:

```bash
IMG=/work/$USER/images/cactus-cuda.simg      # the image
FLAGS="--nv --bind /work --bind /project"    # binds it needs, --nv for GPU
```

`FLAGS` must bind every filesystem holding your Cactus tree, your parameter
files and your output. Nothing outside `$HOME`, `/tmp` and the current
directory is visible inside the container unless you bind it.

## 1. Pick an optionlist

Each image ships one per MPI flavor, already pointing at its own
dependencies:

| image        | MPICH                                        | OpenMPI                                        |
|--------------|----------------------------------------------|------------------------------------------------|
| `cactus`     | `/opt/cactus-deps/cactus-mpich.cfg`          | `/opt/cactus-deps/cactus-openmpi.cfg`          |
| `cactus-cuda`| `/opt/cactus-deps/cactus-cuda-mpich.cfg`     | `/opt/cactus-deps/cactus-cuda-openmpi.cfg`     |
| `cactus-arm-cuda` | `/opt/cactus-deps/cactus-arm-cuda-mpich.cfg` | `/opt/cactus-deps/cactus-arm-cuda-openmpi.cfg` |

Which flavor to build depends on how you will launch. **On a Slurm machine,
find out before you build** — the MPI you build against has to be one the
site can actually bootstrap:

```bash
salloc -N 2 -n 2 -A <account> -p <partition>
singularity exec $FLAGS $IMG mpi-matrix.sh --emit > mpi-matrix.sh && chmod +x mpi-matrix.sh
./mpi-matrix.sh $IMG "$FLAGS"
```

It prints a row per `--mpi=` plugin and MPI flavor. Build against a flavor
with a `PASS` row. If none passes, build either flavor and use `mpirun.py`
(section 4c), which does not use Slurm's PMI at all.

## 2. Get Cactus

```bash
curl -kLO https://raw.githubusercontent.com/gridaphobe/CRL/ET_2026_05/GetComponents
chmod +x GetComponents
./GetComponents --parallel \
  https://bitbucket.org/einsteintoolkit/manifest/raw/ET_2026_05/einsteintoolkit.th
cd Cactus
```

## 3. Build

The build must run **inside** the container: the optionlist names paths
(`/opt/cactus-deps`, `/opt/mpi`) that only exist there.

```bash
CFG=/opt/cactus-deps/cactus-cuda-mpich.cfg

singularity exec $FLAGS $IMG make sim-config \
    options=$CFG THORNLIST=thornlists/einsteintoolkit.th
singularity exec $FLAGS $IMG make -j$(nproc) sim
```

This produces `exe/cactus_sim`. `sim` is just a configuration name; use
whatever you like, and `exe/cactus_<name>` follows.

Two things that bite on clusters:

- **Singularity may only exist on the compute nodes.** Then every `make`
  has to be shipped there, and `-u` matters or the output arrives in
  blocks and a working build looks hung:

  ```bash
  srun -u -N 1 -n 1 -A <account> -p <partition> \
      singularity exec $FLAGS $IMG make -j$(nproc) sim
  ```

- **Run one make, not N.** `srun -n 8 ... make` starts eight independent
  makes in one directory; they race and fail with things like
  `mv: cannot stat '.../thorn-X.files.tmp'`. Parallelism comes from `-j`.

## 4. Run

Set threads per rank in all cases:

```bash
export OMP_NUM_THREADS=4
```

### (a) No Slurm — one machine

Use the `mpirun` belonging to the flavor you built against:

```bash
singularity exec $FLAGS $IMG \
    /opt/mpi/mpich/bin/mpirun -np 4 ./exe/cactus_sim par/mypar.par
```

With Docker instead of Singularity, from a directory containing the
repo's `docker-compose.yml`:

```bash
docker compose exec cactus-cuda-service \
    /opt/mpi/mpich/bin/mpirun -np 4 ./exe/cactus_sim par/mypar.par
```

### (b) Slurm, where `srun` can bootstrap MPI

Launch from **outside** the image; `srun` starts the ranks and each one
enters the container:

```bash
srun --mpi=pmi2 -N 2 -n 8 -A <account> -p <partition> \
    singularity exec $FLAGS $IMG ./exe/cactus_sim par/mypar.par
```

Use the `--mpi=` value that `mpi-matrix.sh` showed passing for your flavor.
Getting it wrong usually does **not** error: every task comes up as rank 0
of its own 1-rank world and the job appears to run.

**Never add `--cleanenv`.** Slurm hands the PMI handshake to the ranks
purely through environment variables, and `--cleanenv` drops them before
the container sees them.

### (c) Slurm, where it cannot

`mpirun.py` bootstraps over ssh instead, so it does not care what the
site's PMI does. It runs from **inside** the image, within an allocation:

```bash
salloc -N 2 -n 8 -A <account> -p <partition>

export MPI_FLAVOR=mpich                 # must match what you built against
export SINGSSH_IMAGE=$IMG               # path visible on every node
export SINGSSH_EXEC_ARGS="$FLAGS"       # the remote singularity gets none of yours

singularity exec $FLAGS $IMG mpirun.py -n 8 ./exe/cactus_sim par/mypar.par
```

`SINGSSH_IMAGE` is not optional where the runtime prints
`INFO: Mounting image with FUSE`: it then reports a node-local extracted
rootfs in `SINGULARITY_CONTAINER` rather than the image path, and the
remote ranks cannot open it.

## Which of (a), (b), (c)?

| situation                                    | use |
|----------------------------------------------|-----|
| laptop, workstation, single node, no Slurm    | (a) |
| Slurm, and `mpi-matrix.sh` shows a `PASS` row | (b) |
| Slurm, no `PASS` row, or ranks come up as 1-rank jobs | (c) |

## If it goes wrong

| symptom | cause |
|---------|-------|
| `Need exactly 2 ranks`, or every rank says it is rank 0 of 1 | PMI did not bootstrap: wrong `--mpi=`, or `--cleanenv` |
| ranks hang at startup | often ssh in (c): no `known_hosts` in the image, or a bad `SINGSSH_IMAGE` |
| `could not open image /tmp/rootfs-.../root` | set `SINGSSH_IMAGE` (see 4c) |
| executable or parfile "not found" inside the container | missing `--bind` in `FLAGS` / `SINGSSH_EXEC_ARGS` |
| `mv: cannot stat '...thorn-X.files.tmp'` | several `make`s running at once; use `-n 1` and `-j` |
| build output arrives in bursts, looks hung | add `-u` to `srun` |
