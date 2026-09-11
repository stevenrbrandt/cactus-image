# A minimal dual-MPI base image.
#
# It carries the part of the Cactus/Einstein Toolkit images that has nothing
# to do with Cactus: two complete, separated MPI stacks, a two-rank test
# binary for each, and the launcher machinery for starting ranks across a
# cluster. Other projects can build on it directly.
#
# Why two MPIs. Which MPI a site can bootstrap is a property of the site,
# not of the application: a cluster's `srun --mpi=` plugins may start one
# implementation and silently fail the other, leaving every task as rank 0
# of its own 1-rank world. Shipping both, each in a self-consistent prefix,
# means there is always something to fall back to -- and mpi-matrix.sh
# reports which combinations actually work on a given machine.
#
# Deliberately NOT here: anything application-specific. No Cactus, no CUDA,
# no HDF5/AMReX/ADIOS2, no hostname shim, no locale handling.
#
# Debian's MPI packages are used rather than compiled ones because they are
# built --with-pmix/--with-slurm (OpenMPI) and --with-slurm (MPICH, hydra
# linked against libslurm), which is the integration a cluster needs.
#
#   docker build -t mpi-base:bookworm .
#   docker build -t mpi-base:trixie --build-arg BASE_IMAGE=python:3.14-slim-trixie .
ARG BASE_IMAGE=python:3.14-slim-bookworm
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# openssh-client is not optional: singssh starts remote ranks with ssh from
# *inside* the container, so the client has to be in the image. python3
# comes from the base image and is what mpirun.py/unslurm.py need.
RUN apt update -y && apt install -y --no-install-recommends \
        build-essential gfortran \
        libopenmpi-dev openmpi-bin \
        mpich libmpich-dev \
        openssh-client ca-certificates \
        procps \
    && apt clean && rm -rf /var/lib/apt/lists/*

COPY pmi-test.c /tmp/pmi-test.c

# The two-rank test, built against each MPI, installed on PATH.
#
# /usr/local/bin rather than /opt/mpi/bin: the prefix builder below opens
# with `rm -rf /opt/mpi` to stay idempotent, which would delete them. On
# PATH they also run by bare name.
#
# This is what mpi-matrix.sh
# launches, and what distinguishes a working site from one where the ranks
# never join a single MPI_COMM_WORLD.
RUN set -ex; \
    /usr/bin/mpicc.openmpi -O2 -o /usr/local/bin/pmi-test-openmpi /tmp/pmi-test.c; \
    /usr/bin/mpicc.mpich   -O2 -o /usr/local/bin/pmi-test-mpich   /tmp/pmi-test.c; \
    rm -f /tmp/pmi-test.c

# Per-flavor MPI prefixes: /opt/mpi/openmpi and /opt/mpi/mpich.
#
# Debian installs both MPIs into one shared namespace. Headers and libs are
# already separated (/usr/lib/<triplet>/{openmpi,mpich}/), but the binaries
# all land in /usr/bin with `.openmpi`/`.mpich` suffixes, and the unsuffixed
# names (mpicc, mpicxx, mpirun, mpiexec) are a single update-alternatives
# symlink that can only point at ONE implementation -- OpenMPI, by default.
# That makes a bare /usr ambiguous: it silently means "OpenMPI" to anything
# resolving the generic names, and `find /usr -name mpirun` turns up only
# the one alternatives symlink.
#
# That is not cosmetic. CMake's FindMPI, given no hints, resolves
# /usr/bin/mpicc -> alternatives -> OpenMPI unconditionally (verified). A
# consumer that passes CMake no MPI hints -- only -I<mpi include dir> --
# would therefore get MPICH *headers* with OpenMPI *libraries*: an ABI
# mismatch that compiles and then misbehaves.
#
# These prefixes give each implementation a real, self-consistent root with
# a working bin/, include/ and lib/, so MPI_HOME names exactly one
# implementation and nothing has to guess. The underlying binaries are still
# Debian's.
#
# Two details this has to get right, both found by running it rather than
# reading it:
#
#   - MPICH's mpirun is hydra, which execs hydra_pmi_proxy and friends by
#     bare name. Without those linked in alongside it, a 2-rank run dies
#     with "hydra_pmi_proxy: not found".
#
#   - include/ and lib/ are derived from `mpicc.<flavor> -show` rather than
#     assumed, because the per-flavor layout differs between Debian
#     releases; hardcoding one release's paths silently breaks the other.

RUN set -ex; \
    rm -rf /opt/mpi; \
    for flavor in openmpi mpich; do \
        mkdir -p "/opt/mpi/$flavor/bin"; \
        for tool in mpicc mpicxx mpic++ mpif77 mpif90 mpifort mpirun mpiexec; do \
            if [ -e "/usr/bin/$tool.$flavor" ]; then \
                ln -sf "/usr/bin/$tool.$flavor" "/opt/mpi/$flavor/bin/$tool"; \
            fi; \
        done; \
        if [ "$flavor" = mpich ]; then \
            for helper in /usr/bin/hydra_*; do \
                ln -sf "$helper" "/opt/mpi/mpich/bin/$(basename "$helper")"; \
            done; \
        fi; \
        for alias_pair in "mpic++:mpicxx" "mpiCC:mpicxx" "mpifc:mpifort"; do \
            a="${alias_pair%%:*}"; real="${alias_pair##*:}"; \
            if [ ! -e "/opt/mpi/$flavor/bin/$a" ] && [ -e "/opt/mpi/$flavor/bin/$real" ]; then \
                ln -sf "$real" "/opt/mpi/$flavor/bin/$a"; \
            fi; \
        done; \
        incdir=$(mpicc.$flavor -show | xargs -n1 | grep "^-I" | head -1 | cut -c3-); \
        libdir=$(mpicc.$flavor -show | xargs -n1 | grep "^-L" | head -1 | cut -c3-); \
        ln -sfn "$incdir" "/opt/mpi/$flavor/include"; \
        case "$libdir" in \
            */$flavor|*/$flavor/*) \
                ln -sfn "$libdir" "/opt/mpi/$flavor/lib" ;; \
            *)  mkdir -p "/opt/mpi/$flavor/lib"; \
                for w in mpicc mpicxx mpif90; do \
                    [ -e "/usr/bin/$w.$flavor" ] && $w.$flavor -show | xargs -n1 | grep "^-lmpi" | cut -c3-; \
                done | sort -u | while read -r l; do \
                    for so in "$libdir/lib$l".so*; do \
                        [ -e "$so" ] && ln -sf "$so" "/opt/mpi/$flavor/lib/"; \
                    done; \
                done ;; \
        esac; \
        test -x "/opt/mpi/$flavor/bin/mpirun"; \
        test -f "/opt/mpi/$flavor/include/mpi.h"; \
        ls "/opt/mpi/$flavor/lib/"libmpi*.so* > /dev/null; \
    done; \
    /opt/mpi/mpich/bin/mpirun -np 2 "/usr/local/bin/pmi-test-mpich" | grep -q "PMI-TEST: PASS"; \
    /opt/mpi/openmpi/bin/mpirun --allow-run-as-root -np 2 "/usr/local/bin/pmi-test-openmpi" | grep -q "PMI-TEST: PASS"

# The launcher machinery. mpi-matrix.sh runs OUTSIDE the container but
# ships inside it, so the probe and the pmi-test binaries it launches can
# never be version-skewed; --emit lifts it back out.
COPY bin/unslurm.py bin/singssh bin/mpirun.py bin/mpi-matrix.sh /usr/local/bin/
RUN set -ex; \
    chmod +x /usr/local/bin/unslurm.py /usr/local/bin/singssh \
             /usr/local/bin/mpirun.py /usr/local/bin/mpi-matrix.sh; \
    touch /i.simg; \
    test "$(unslurm.py 'n[001-003],x05')" = "n001,n002,n003,x05"; \
    test "$(SLURM_NODELIST='n[01-02,05]' unslurm.py)" = "n01,n02,n05"; \
    test "$(SINGULARITY_CONTAINER=/i.simg SINGSSH_DRY_RUN=1 SINGSSH_SSH_OPTS= \
            singssh -x --external-launcher h1 hn)" \
       = "ssh -x h1 singularity exec /i.simg hn"; \
    SINGULARITY_CONTAINER=/i.simg SINGSSH_DRY_RUN=1 singssh h1 hn \
        | grep -q 'StrictHostKeyChecking=no'; \
    SINGULARITY_CONTAINER=/tmp/rootfs-123/root singssh --print-image 2>&1 \
        | grep -q 'not a shared image file'; \
    test "$(SLURM_NPROCS=8 SLURM_NTASKS_PER_NODE=4 SLURM_NODELIST='n[001-002]' \
            MPI_FLAVOR=mpich MPIRUN_DRY_RUN=1 SINGSSH_IMAGE=/i.simg mpirun.py ./exe)" \
       = "/opt/mpi/mpich/bin/mpirun -launcher ssh -launcher-exec /usr/local/bin/singssh -np 8 -ppn 4 -hosts n001,n002 ./exe"; \
    SLURM_NPROCS=2 MPI_FLAVOR=mpich SINGSSH_IMAGE=/i.simg \
        mpirun.py /usr/local/bin/pmi-test-mpich | grep -q "PMI-TEST: PASS"; \
    mpi-matrix.sh --emit | cmp -s - /usr/local/bin/mpi-matrix.sh; \
    mpi-matrix.sh --help | grep -q 'partition'; \
    rm -f /i.simg
