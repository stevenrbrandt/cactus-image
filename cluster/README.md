# Two-node SLURM test cluster

A throwaway cluster in Docker for testing the Singularity images built in
this repo against the things that only break on a real machine: SLURM's PMI
bootstrap, ssh-based MPI launchers, and a shared filesystem.

It exists because the failures we kept hitting on deep bayou — `Need exactly
2 ranks`, jobs that time out with `--cleanenv` removed, ranks silently
launched outside the container — cannot be reproduced with `docker run`.

```
node1  slurmctld + slurmd + sshd + munge     (controller, also a compute node)
node2  slurmd + sshd + munge
both   Apptainer 1.5.3 (provides `singularity`), Slurm 24.11, Debian trixie
```

## Quick start

```bash
docker compose up -d --build     # ~2 min
docker compose exec --user sbrandt node1 bash
sinfo
srun -N 2 -n 2 hostname
```

## Testing an image

```bash
./load-image.sh stevenrbrandt/cactus-cuda cactus-cuda   # docker -> .sif
./smoke.sh cactus-cuda                                  # full test suite
```

`load-image.sh` goes through `docker save` and `docker-archive://` rather
than a registry, so it tests exactly the image you just built locally,
including changes not yet pushed.

`mpi-matrix.sh` ships inside the image rather than living here, so it can
never be version-skewed against the `pmi-test` binaries it launches. It runs
*outside* the container (srun is on the host); lift it out with

```bash
singularity exec cactus-cuda.sif mpi-matrix.sh --emit > mpi-matrix.sh
chmod +x mpi-matrix.sh
salloc -N 2 -n 2 && ./mpi-matrix.sh /path/to/cactus-cuda.sif
```

which is also how to run it on a real machine such as Deep Bayou.

`smoke.sh` checks, on two nodes: the image runs, the hostname shim reports
`cactus-cuda-<node>`, no perl locale warning, `srun --mpi=pmi2` with MPICH,
`srun --mpi=pmix` with OpenMPI, and `mpirun.py` fanning out over `singssh`
with ranks landing on distinct nodes.

## The equivalent of the deep bayou commands

```bash
# SLURM's own PMI bootstrap
srun --mpi=pmi2 -N 2 -n 2 singularity exec --bind /work \
     /work/images/cactus-cuda.sif /opt/cactus-deps/bin/pmi-test-mpich

# the ssh launcher path
salloc -N 2 -n 2
singularity exec --bind /work /work/images/cactus-cuda.sif bash
export MPI_FLAVOR=mpich SINGSSH_EXEC_ARGS="--bind /work"
mpirun.py /opt/cactus-deps/bin/pmi-test-mpich
```

Note `--bind /work` is required, exactly as on deep bayou: Apptainer binds
`$HOME`, `/tmp` and the cwd by default, and nothing else. This is deliberate
— auto-binding `/work` here would hide a class of bug that does bite on the
real machine.

## Shared filesystem

Two shared mounts, both visible from both nodes:

| path    | backing              | use                                        |
|---------|----------------------|--------------------------------------------|
| `/work` | host bind `./work`   | images, build trees; reachable from the host |
| `/home` | docker volume `home` | shared home, as on a real cluster            |

`/home` is a volume rather than a bind because the image seeds it with the
cluster user's ssh keys on first boot. `docker compose down -v` erases it.

## Deliberate divergences from a real cluster

- **`privileged: true`.** This is what lets Singularity run inside Docker.
  It is a real privilege grant; this is a local test cluster on a private
  bridge network, not a template for anything deployed.
- **cgroups disabled** (`CgroupPlugin=disabled`, `proctrack/linuxproc`,
  `task/none`). Slurm 24.11 otherwise tries to put `slurmstepd` in a systemd
  scope over dbus, which a container does not have, and slurmd exits with
  `fatal: systemd scope for slurmstepd could not be set`. Consequence: no
  memory/CPU confinement, so this cluster cannot test anything that depends
  on cgroup enforcement.
- **`SlurmdParameters=config_overrides`.** The containers see all 80 host
  CPUs; without this, a node whose hardware does not match `CPUs=8` is
  marked invalid and drained.
- **No GPU.** `--nv` will not work and no CUDA kernel can execute. Compiling
  CUDA code works fine (nvcc needs no device), so the CUDA image can be
  tested for everything except actually running a kernel.
- **munge key and ssh keys are baked into the image**, so both nodes trust
  each other with no provisioning step. Fine for a disposable cluster,
  disqualifying for anything else.
- **Both "nodes" share one host kernel**, so this cannot catch anything
  arising from genuinely separate machines (interconnect, NUMA, driver
  differences).

## Teardown

```bash
docker compose down          # keep /work and the home volume
docker compose down -v       # also erase the home volume
```
