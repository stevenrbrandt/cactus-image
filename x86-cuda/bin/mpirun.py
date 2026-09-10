#!/usr/bin/env python3
"""Run an MPI job across a SLURM allocation, with every rank inside this image.

Intended flow:

    # 1. get an interactive allocation on the cluster
    salloc -N 2 -n 8 -p gpu2 -A $ACCOUNT
    # 2. enter the image once
    singularity shell --nv --bind /work --bind /project /work/.../cactus-cuda.simg
    # 3. inside it, launch across the whole allocation
    export MPI_FLAVOR=mpich
    export SINGSSH_EXEC_ARGS="--nv --bind /work --bind /project"
    mpirun.py ./cactus_sim par.par

It reads the allocation out of the SLURM_* variables, expands
$SLURM_NODELIST with unslurm, and hands Hydra an explicit -hosts list plus
a launcher that re-enters the container on each node (see singssh).

The SLURM_* and MODULE* variables are then removed from the environment
passed on, so that Hydra bootstraps over its own ssh launcher rather than
half-detecting SLURM's PMI and trying to use it -- mixing the two is what
produces the "Need exactly 2 ranks" and hang symptoms.

Which MPI, in order of precedence:
    $MPI_CMD     -- explicit path to an mpirun/mpiexec
    $MPI_FLAVOR  -- 'mpich' or 'openmpi', resolved to /opt/mpi/<f>/bin/mpirun
    autodetect   -- only if PATH yields exactly one MPI

Set $MPIRUN_DRY_RUN=1 to print the command that would run and exit.
"""
import os
import re
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from unslurm import unslurm  # noqa: E402

MPI_PREFIX = "/opt/mpi"
SINGSSH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "singssh")


def die(*msg):
    sys.exit("mpirun.py: " + "\n            ".join(msg))


def resolve_mpi_cmd():
    if os.environ.get("MPI_CMD"):
        return os.environ["MPI_CMD"]

    flavor = os.environ.get("MPI_FLAVOR")
    if flavor:
        cand = os.path.join(MPI_PREFIX, flavor, "bin", "mpirun")
        if not os.access(cand, os.X_OK):
            die("MPI_FLAVOR=%s, but %s is not executable." % (flavor, cand),
                "Available: " + ", ".join(sorted(os.listdir(MPI_PREFIX)))
                if os.path.isdir(MPI_PREFIX) else "No %s directory." % MPI_PREFIX)
        return cand

    me = os.path.realpath(__file__)
    found = set()
    for path in os.environ.get("PATH", "").split(os.pathsep):
        if not os.path.isdir(path):
            continue
        for f in os.listdir(path):
            if not re.search(r"mpirun|mpiexec", f):
                continue
            fn = os.path.join(path, f)
            if os.access(fn, os.X_OK) and os.path.realpath(fn) != me:
                found.add(os.path.realpath(fn))
    if len(found) == 1:
        return found.pop()
    die("Cannot pick an MPI automatically: PATH yields %d." % len(found),
        "Set MPI_FLAVOR=mpich or MPI_FLAVOR=openmpi (preferred), or MPI_CMD.",
        *["  candidate: " + f for f in sorted(found)])


def mpi_family(mpi_cmd):
    """'mpich' or 'openmpi', decided by the resolved binary."""
    p = os.path.realpath(mpi_cmd)
    if re.search(r"hydra|mpich", p):
        return "mpich"
    if re.search(r"orterun|prte|openmpi|ompi", p):
        return "openmpi"
    try:
        out = subprocess.run([mpi_cmd, "--version"], capture_output=True,
                             text=True, timeout=15).stdout.lower()
    except Exception:
        out = ""
    if "open mpi" in out or "open-mpi" in out:
        return "openmpi"
    if "hydra" in out or "mpich" in out:
        return "mpich"
    return "unknown"


mpi_cmd = resolve_mpi_cmd()
family = mpi_family(mpi_cmd)

if family != "mpich":
    die("resolved MPI is %r (%s)." % (mpi_cmd, family),
        "This launcher builds MPICH/Hydra options (-launcher, -launcher-exec,",
        "-hosts, -ppn) which OpenMPI does not accept. Running anyway would let",
        "OpenMPI fall back to plain ssh, starting ranks OUTSIDE the container",
        "instead of failing -- so this stops here rather than launching a job",
        "that looks fine and is not.",
        "Use the MPICH build: MPI_FLAVOR=mpich mpirun.py ...")

# Ask singssh to resolve the image now. Without this, a bad image path is
# discovered independently by every remote rank inside Hydra, which reports
# it as an opaque FATAL from a node you did not name; here it is one clear
# message before anything launches.
probe = subprocess.run([SINGSSH, "--print-image"], capture_output=True, text=True)
if probe.returncode != 0:
    sys.stderr.write(probe.stdout + probe.stderr)
    die("singssh could not determine the image for the remote ranks (above).")

# Snapshot the allocation before stripping, so the values cannot depend on
# the order os.environ happens to iterate in. The prototype read num_procs
# from SLURM_NPROCS and then again from SLURM_JOB_NUM_NODES into the same
# variable, so `-N 2 -n 8` launched 2 ranks instead of 8.
env = dict(os.environ)


def as_int(name):
    try:
        return int(env[name])
    except (KeyError, ValueError):
        return None


num_procs = as_int("SLURM_NPROCS") or as_int("SLURM_NTASKS") or 1
tasks_per_node = as_int("SLURM_NTASKS_PER_NODE")
node_list = ",".join(unslurm(env["SLURM_NODELIST"])) if env.get("SLURM_NODELIST") else None

for ev in list(os.environ):
    if re.search(r"SLURM", ev) or re.search(r"MODULE", ev):
        del os.environ[ev]

user_args = sys.argv[1:]
has_np = any(re.match(r"^-?-np?(=.*)?$", a) for a in user_args)
has_ppn = any(re.match(r"^-?-ppn(=.*)?$", a) for a in user_args)

args = []
if not has_np:
    args += ["-np", str(num_procs)]
if not has_ppn and tasks_per_node is not None:
    args += ["-ppn", str(tasks_per_node)]
if node_list is not None:
    args += ["-hosts", node_list]

full = [mpi_cmd, "-launcher", "ssh", "-launcher-exec", SINGSSH] + args + user_args

if os.environ.get("MPIRUN_DRY_RUN"):
    print(" ".join(shlex.quote(a) for a in full))
    sys.exit(0)

sys.exit(subprocess.call(full))
