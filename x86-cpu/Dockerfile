# Base image the client agent runs per session. Keep JUPYTERHUB_VERSION in sync
# with whatever `jupyterhub` version is installed on the Hub -- mismatches break
# OAuth scope handling and activity reporting.
#
# Pinned to the Debian 13 "trixie" variant (rather than the floating
# `python:3.14-slim` tag) purely so the package/toolchain versions this image
# ships are reproducible across rebuilds.
#
# Note on the >=4.18 host kernel target: that floor comes from
# Singularity/Apptainer's own requirements on the *host* (unprivileged user
# namespaces + overlayfs-in-userns, backported into RHEL8/CentOS8's 4.18
# kernel and commonly cited as its practical minimum) -- it is not something
# this base image (or any base image) determines. Containers always run
# under the host's kernel, never one of their own, and glibc's syscall
# wrappers (rseq, clone3, etc.) fall back gracefully on kernels that predate
# them, so a newer Debian release here doesn't raise the floor a host needs.
ARG MPI_BASE=stevenrbrandt/mpi-base:trixie
FROM ${MPI_BASE}

ARG JUPYTERHUB_VERSION=5.5.1

ENV DEBIAN_FRONTEND=noninteractive

# CactusUtils/Formaline commits the built source tree to a local git repo
# for build provenance, which fails with "empty ident name" if git has no
# configured identity. A baked-in ~/.gitconfig wouldn't help here -- it'd
# just get shadowed once docker-compose bind-mounts a host directory onto
# jovyan's home (see the docker-compose.yml volume fix from earlier) -- so
# this is set as an env var instead, which isn't affected by that mount.
ENV GIT_AUTHOR_NAME="Cactus Builder" \
    GIT_AUTHOR_EMAIL="cactus-builder@localhost" \
    GIT_COMMITTER_NAME="Cactus Builder" \
    GIT_COMMITTER_EMAIL="cactus-builder@localhost"

# Toolchain + Einstein Toolkit build deps.
#
# MPI/PMI: both MPICH and OpenMPI are installed side by side (Debian keeps
# their headers/libs/pkg-config files in separate `mpich`/`openmpi`
# directories and manages the generic mpicc/mpirun/h5pcc names via
# update-alternatives, so this is a supported, conflict-free combo -- use
# `mpicc.mpich`/`mpirun.mpich` or `mpicc.openmpi`/`mpirun.openmpi` to target
# one explicitly, or `update-alternatives --config mpi` to change the
# default). Together they cover the PMI variants an HPC site's Slurm is
# likely to expose:
#   - Debian's OpenMPI is built --with-pmix=external --with-slurm, so it can
#     be launched directly by `srun --mpi=pmix` and talks PMIx.
#   - Debian's MPICH/Hydra is linked against libslurm and speaks PMI-1/PMI-2
#     natively, covering `srun --mpi=pmi2`.
#   - libpmi2-0-dev and libpmix-dev/libpmix-bin add the standalone PMI2
#     (Slurm) and PMIx client libs/headers, for anything else that wants to
#     link against a PMI implementation directly, or to bind-mount over with
#     a host-matched version at runtime.
# HDF5 is installed in serial, OpenMPI, and MPICH flavors (also
# conflict-free via the same alternatives mechanism) so builds can pick
# whichever MPI stack they're using.
RUN apt update -y && apt install -y curl \
    cmake ninja-build gfortran gcc g++ libpapi-dev libgsl-dev liblapack-dev libblas-dev \
    libhdf5-dev libhdf5-openmpi-dev \
    libhdf5-mpich-dev \
    libpmi2-0-dev libpmix-dev libpmix-bin \
    pkg-config subversion git python3 patch make numactl libhwloc-dev \
    hwloc libssl-dev libfftw3-dev rsync libboost-all-dev vim \
    zlib1g-dev libjpeg-dev libyaml-cpp-dev libsilo-dev nlohmann-json3-dev \
    && apt clean

# Sanity-check the toolchain versions this image is meant to guarantee.
RUN gcc_major=$(gcc -dumpversion | cut -d. -f1) && \
    if [ "$gcc_major" -lt 10 ]; then \
        echo "ERROR: gcc $gcc_major.x is older than the required gcc 10+" >&2; exit 1; \
    fi && \
    gcc --version | head -1 && python3.14 --version

# ---------------------------------------------------------------------------
# Cactus / Einstein Toolkit ExternalLibraries dependencies
#
# Scope: everything the official einsteintoolkit.th (ET_2026_05) manifest's
# ExternalLibraries enable, EXCEPT NSIMD (deliberately left unbuilt -- see
# below) and LORENE/SGRID (large, special-purpose initial-data codes with
# their own non-CMake build systems; out of scope for this general-purpose
# image by request).
#
# Split into two groups:
#   1. Apt packages -- HDF5, GSL, BLAS/LAPACK, FFTW3, Boost, hwloc, zlib,
#      libjpeg, OpenSSL, yaml-cpp, Silo. Debian trixie ships all of these,
#      so there's no reason to build them from source.
#   2. Source builds -- AMReX, ADIOS2, openPMD-api (the CarpetX I/O/driver
#      stack). No apt packages exist for these; built once here into
#      /opt/cactus-deps/<name> and left there for the optionlist below to
#      point Cactus's ExternalLibraries `detect.sh` scripts at (each one's
#      *_DIR skips its bundled download-and-build path entirely).
#
# NSIMD is intentionally NOT built here: it dispatches to specific SIMD ISA
# extensions (AVX2/AVX-512/SVE/...) detected from the *build* host's CPU, so
# baking it into this image would hard-code whatever CPU this `docker build`
# happened to run on -- not the HPC node that will eventually run the
# executable. Leave NSIMD_DIR unset (or BUILD) in the optionlist used for
# the actual singularity-time compile, so Cactus builds it there instead,
# against the real target hardware.
#
# All three source builds use plain gcc/g++ (not the mpicc/mpicxx wrapper)
# against one MPI implementation's compiler wrappers at a time
# (MPI_C_COMPILER/MPI_CXX_COMPILER below) -- their compiled objects bake in
# a specific MPI ABI, and OpenMPI/MPICH are not ABI-compatible with each
# other, so a single build of AMReX/ADIOS2/openPMD-api can only back one of
# them. Rather than pick just one, the whole stack -- AMReX, ADIOS2,
# openPMD-api, and a tiny PMI/MPI smoke-test binary (see pmi-test.c) -- is
# built TWICE below, once per MPI flavor, into parallel
# $CACTUS_DEPS_PREFIX/<name>-openmpi and $CACTUS_DEPS_PREFIX/<name>-mpich
# trees. cactus-openmpi.cfg / cactus-mpich.cfg (copied in below) each point
# at their matching tree; pick whichever the target HPC site's Slurm PMI
# plugin actually supports (verify with the pmi-test-* binaries -- see
# their header comment in pmi-test.c), same idea as rebuilding AMReX
# externally against a different MPI as described in cactus-build-ref.md
# §18.2, just done once here for both flavors instead of on demand.
#
# AMReX version: pinned to 25.11 -- the exact version the checked-out
# ExternalLibraries/AMReX thorn itself bundles as dist/amrex-25.11.tar (its
# own fallback if AMREX_DIR isn't set), i.e. what this vintage of CarpetX
# was actually written and tested against. An earlier build of this image
# used "latest" (26.08) instead, which broke: AMReX generalized Array4 into
# a templated ArrayND between these releases, and Array4::begin/end changed
# from a plain Dim3 struct (fields .x/.y/.z, what CarpetX/src/interpolate.cxx
# uses) to IntVectND<4> (no .x/.y/.z) -- "'const class amrex::IntVectND<4>'
# has no member named 'x'". Confirmed directly by diffing AMReX_Array4.H
# between the two tags. Lesson: match the thorn's own bundled/pinned
# version, don't assume "latest" is compatible.
#
# ADIOS2 is built without SST (streaming/staging engines; pulls in
# libfabric/evpath and isn't needed for ordinary file-based BP5 I/O) --
# ADIOS2_ENABLE_SST=no in both optionlists matches this.
ARG CACTUS_DEPS_PREFIX=/opt/cactus-deps
ARG AMREX_VERSION=25.11
ARG ADIOS2_VERSION=v2.12.1
ARG OPENPMD_VERSION=0.17.1


# build_stack <flavor> <mpicc> <mpicxx> <h5pcc>
# One MPI-flavor's worth of AMReX + ADIOS2 + openPMD-api + pmi-test,
# installed under $CACTUS_DEPS_PREFIX/<name>-<flavor>. Called once per
# flavor below -- see the block comment above for why this is duplicated
# instead of built once.
RUN set -ex; \
    build_stack() { \
        flavor="$1"; mpicc="$2"; mpicxx="$3"; h5pcc="$4"; \
        build="/tmp/build-$flavor"; \
        mkdir -p "$build"; \
        \
        git clone --depth 1 --branch "$AMREX_VERSION" https://github.com/AMReX-Codes/amrex.git "$build/amrex"; \
        cmake -G Ninja -S "$build/amrex" -B "$build/amrex/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$CACTUS_DEPS_PREFIX/amrex-$flavor" \
            -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
            -DMPI_C_COMPILER="$mpicc" -DMPI_CXX_COMPILER="$mpicxx" \
            -DAMReX_MPI=ON -DAMReX_OMP=ON -DAMReX_PARTICLES=ON -DAMReX_FORTRAN=OFF \
            -DAMReX_ASSERTIONS=OFF -DAMReX_PIC=ON -DAMReX_HDF5=OFF -DAMReX_LINEAR_SOLVERS=ON; \
        cmake --build "$build/amrex/build" -j"$(nproc)"; \
        cmake --install "$build/amrex/build"; \
        \
        git clone --depth 1 --branch "$ADIOS2_VERSION" https://github.com/ornladios/ADIOS2.git "$build/adios2"; \
        cmake -G Ninja -S "$build/adios2" -B "$build/adios2/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$CACTUS_DEPS_PREFIX/adios2-$flavor" \
            -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
            -DMPI_C_COMPILER="$mpicc" -DMPI_CXX_COMPILER="$mpicxx" \
            -DADIOS2_USE_MPI=ON -DADIOS2_USE_HDF5=OFF -DADIOS2_USE_Fortran=OFF -DADIOS2_USE_Python=OFF \
            -DADIOS2_USE_SST=OFF -DADIOS2_USE_ZFP=OFF -DADIOS2_USE_SZ=OFF -DADIOS2_USE_BZip2=OFF \
            -DADIOS2_USE_PNG=OFF -DADIOS2_USE_Blosc2=OFF -DADIOS2_USE_MGARD=OFF -DADIOS2_USE_CUDA=OFF \
            -DBUILD_TESTING=OFF -DADIOS2_BUILD_EXAMPLES=OFF; \
        cmake --build "$build/adios2/build" -j"$(nproc)"; \
        cmake --install "$build/adios2/build"; \
        \
        git clone --depth 1 --branch "$OPENPMD_VERSION" https://github.com/openPMD/openPMD-api.git "$build/openpmd"; \
        cmake -G Ninja -S "$build/openpmd" -B "$build/openpmd/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$CACTUS_DEPS_PREFIX/openpmd-$flavor" \
            -DCMAKE_PREFIX_PATH="$CACTUS_DEPS_PREFIX/adios2-$flavor" \
            -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
            -DMPI_C_COMPILER="$mpicc" -DMPI_CXX_COMPILER="$mpicxx" \
            -DHDF5_C_COMPILER_EXECUTABLE="$h5pcc" \
            -DopenPMD_USE_MPI=ON -DopenPMD_USE_HDF5=ON -DopenPMD_USE_ADIOS2=ON \
            -DopenPMD_USE_PYTHON=OFF -DopenPMD_BUILD_TESTING=OFF -DopenPMD_BUILD_EXAMPLES=OFF \
            -DopenPMD_BUILD_CLI_TOOLS=OFF; \
        cmake --build "$build/openpmd/build" -j"$(nproc)"; \
        cmake --install "$build/openpmd/build"; \
        \
        mkdir -p "$CACTUS_DEPS_PREFIX/bin"; \
        \
        rm -rf "$build"; \
    }; \
    mkdir -p "$CACTUS_DEPS_PREFIX"; \
    build_stack openmpi /usr/bin/mpicc.openmpi /usr/bin/mpicxx.openmpi /usr/bin/h5pcc.openmpi; \
    build_stack mpich   /usr/bin/mpicc.mpich   /usr/bin/mpicxx.mpich   /usr/bin/h5pcc.mpich;

# ---------------------------------------------------------------------------
# The two MPI stacks, their /opt/mpi/<flavor> prefixes, the two-rank
# pmi-test binaries and the mpirun.py/singssh/mpi-matrix.sh launcher
# machinery all come from mpi-base (see ../mpi-base). None of it was ever
# Cactus-specific, and keeping one copy is what stops the images drifting
# apart.
#
# Note this image previously shipped none of the launcher tools at all --
# they were added to the CUDA images only. Rebasing gives x86-cpu
# mpirun.py, singssh and mpi-matrix.sh for the first time.


# Cactus optionlists pointing at the dependencies built/installed above --
# see the header comment in each file for the full explanation of every
# setting, and which one to pick for a given HPC site's PMI support.
RUN set -ex; \
    for tool in unslurm.py singssh mpirun.py mpi-matrix.sh pmi-test-mpich pmi-test-openmpi; do \
        command -v "$tool" >/dev/null || { echo "ERROR: $tool missing -- is MPI_BASE right?" >&2; exit 1; }; \
    done; \
    /opt/mpi/mpich/bin/mpirun -np 2 pmi-test-mpich | grep -q "PMI-TEST: PASS"; \
    /opt/mpi/openmpi/bin/mpirun --allow-run-as-root -np 2 pmi-test-openmpi \
        | grep -q "PMI-TEST: PASS"

COPY cactus-openmpi.cfg /opt/cactus-deps/cactus-openmpi.cfg
COPY cactus-mpich.cfg /opt/cactus-deps/cactus-mpich.cfg

# Verify every dependency the optionlists reference is actually present, in
# the exact shape Cactus's find_lib looks for -- see check-deps.sh for why
# "installed" and "detectable" aren't the same question. Runs as part of
# the build so a gap fails here rather than surfacing during a real Cactus
# build on a cluster; also left in the image to re-run against a deployed
# container:  singularity exec image.simg /opt/cactus-deps/check-deps.sh
COPY check-deps.sh /opt/cactus-deps/check-deps.sh
RUN chmod +x /opt/cactus-deps/check-deps.sh && /opt/cactus-deps/check-deps.sh

# ---------------------------------------------------------------------------
# HPCToolkit -- performance measurement tools (hpcrun, hpcstruct, hpcprof).
#
# Not packaged in Debian. Upstream's "recommended for users" path is Spack,
# which was measured here and rejected: it concretizes to 57 packages built
# from source, including its own Python and Perl and a JDK for the hpcviewer
# GUI -- hours of build time and gigabytes, nearly all of it duplicating
# libraries this image already has.
#
# This uses upstream's other documented path instead (README, "Building
# HPCToolkit from source with Meson"): Debian packages supply everything
# they can, and Meson "wraps" fetch and build only what Debian genuinely
# lacks -- Dyninst, Intel XED, jemalloc and a few small helpers, about seven
# subprojects. Measured: ~2 minutes to compile and 54MB installed, per
# flavor.
#
# hpcviewer (the Java GUI) lives in a separate repository and is
# deliberately not installed: the workflow is to copy the .hpctoolkit
# database off the cluster and view it on a workstation, so a GUI has no
# use inside a batch container.
#
# Built once per MPI flavor, like AMReX/ADIOS2/openPMD above, because
# hpcprof-mpi links MPI -- and with two MPIs present, letting it bind to
# whichever update-alternatives happens to point at is exactly the
# ambiguity the rest of this image takes pains to avoid. hpcrun, hpcstruct
# and (serial) hpcprof do not depend on the flavor, so PATH below just
# picks the OpenMPI tree for them; use the matching tree's hpcprof-mpi for
# whichever mpirun you launch it with.
#
# Placed after the AMReX/ADIOS2/openPMD builds so edits here don't
# invalidate their layer cache -- nothing above depends on it.
ARG HPCTOOLKIT_VERSION=2026.0.2

RUN apt update -y && apt install -y \
    libbz2-dev libtbb-dev libelf-dev libdw-dev libunwind-dev libxerces-c-dev \
    libiberty-dev libpfm4-dev libxxhash-dev ccache \
    && apt clean

RUN set -ex; \
    pip install --no-cache-dir "meson>=1.3.2"; \
    git clone --depth 1 --branch "$HPCTOOLKIT_VERSION" \
        https://gitlab.com/hpctoolkit/hpctoolkit.git /tmp/hpctoolkit; \
    for flavor in openmpi mpich; do \
        rm -rf /tmp/hpctoolkit/build-$flavor; \
        PATH="/opt/mpi/$flavor/bin:$PATH" \
        meson setup /tmp/hpctoolkit/build-$flavor /tmp/hpctoolkit \
            --prefix="/opt/hpctoolkit-$flavor" \
            --buildtype=release \
            -Dpapi=enabled -Dhpcprof_mpi=enabled -Dcuda=disabled \
            -Dtests=disabled -Dmanpages=disabled; \
        meson compile -C /tmp/hpctoolkit/build-$flavor -j"$(nproc)"; \
        meson install -C /tmp/hpctoolkit/build-$flavor; \
        "/opt/hpctoolkit-$flavor/bin/hpcrun" --version; \
        test -x "/opt/hpctoolkit-$flavor/bin/hpcstruct"; \
        test -x "/opt/hpctoolkit-$flavor/bin/hpcprof"; \
        test -x "/opt/hpctoolkit-$flavor/bin/hpcprof-mpi"; \
        case "$flavor" in \
            openmpi) want=libmpi.so ;; \
            mpich)   want=libmpich.so ;; \
        esac; \
        ldd "/opt/hpctoolkit-$flavor/bin/hpcprof-mpi" | grep -q "$want" \
            || { echo "ERROR: hpcprof-mpi ($flavor) does not link $want -- it resolved to:" >&2; \
                 ldd "/opt/hpctoolkit-$flavor/bin/hpcprof-mpi" | grep -iE "libmpi" >&2; exit 1; }; \
    done; \
    rm -rf /tmp/hpctoolkit

ENV PATH=/opt/hpctoolkit-openmpi/bin:${PATH}

RUN pip install --no-cache-dir \
        jupyterhub==${JUPYTERHUB_VERSION} \
        jupyterlab \
        notebook

RUN useradd -m -u 1168 -s /bin/bash jovyan

USER jovyan
WORKDIR /home/jovyan

EXPOSE 8888

CMD ["jupyterhub-singleuser"]
