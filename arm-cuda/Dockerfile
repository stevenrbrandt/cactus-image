# ARM (aarch64) + CUDA variant of the Cactus/Einstein Toolkit build image,
# targeting NVIDIA Grace Hopper. Derived from ../x86-cuda/Dockerfile; the
# comments here cover only what differs from it, and it in turn covers only
# what differs from ../x86-cpu/Dockerfile.
#
# Two things change relative to x86-cuda, and they are linked:
#
#   - Architecture. Built for linux/arm64. NVIDIA publishes ARM server CUDA
#     under the "sbsa" (Server Base System Architecture) path, not arm64 or
#     aarch64 -- .../repos/debian12/sbsa/ -- and its packages are
#     Architecture: arm64. The per-target toolkit directory is named
#     targets/sbsa-linux rather than targets/x86_64-linux, and Debian's
#     multiarch triplet is aarch64-linux-gnu.
#
#   - CUDA 13, not 12.9. This is forced, not chosen: the debian12/sbsa repo
#     publishes ONLY CUDA 13.1 through 13.4, with no 12.x at all, whereas
#     debian12/x86_64 carries 12.3 through 13.4. x86-cuda pins 12.9 solely
#     because sm_70 (Volta) support ends there; Grace Hopper is sm_90, which
#     CUDA 13 supports fully, so nothing is lost. CUDA 13 has dropped sm_70
#     and below entirely -- this image therefore cannot target Volta, by
#     design rather than by omission.
#
# GPU architecture is sm_90 alone (Hopper H100/GH200), not a fat binary over
# several generations: unlike the x86 image, which has to serve V100 and
# A100 from one library, the Grace Hopper target is a single known
# architecture. AMReX is prebuilt for it here.
#
# NSIMD is still NOT prebuilt. images.md notes that Grace's vector width is
# known (Neoverse V2, SVE2) so it could be, but that is a separate change
# from porting this image, and the CPU-side SIMD choice is still better made
# against the machine Cactus is finally compiled on.
#
# Base remains Debian 12 "bookworm" for consistency with x86-cuda rather
# than for CUDA's sake: with sm_70 out of the picture, trixie + CUDA 13
# would also be an option, but keeping one base across the CUDA images keeps
# the two optionlists and their library paths comparable.
ARG MPI_BASE=stevenrbrandt/mpi-base:bookworm-arm64
FROM ${MPI_BASE}

ARG JUPYTERHUB_VERSION=5.5.1

ENV DEBIAN_FRONTEND=noninteractive

# CactusUtils/Formaline commits the built source tree to a local git repo
# for build provenance, which fails with "empty ident name" if git has no
# configured identity. A baked-in ~/.gitconfig wouldn't help here -- it'd
# just get shadowed once docker-compose bind-mounts a host directory onto
# jovyan's home -- so this is set as an env var instead, which isn't
# affected by that mount.
ENV GIT_AUTHOR_NAME="Cactus Builder" \
    GIT_AUTHOR_EMAIL="cactus-builder@localhost" \
    GIT_COMMITTER_NAME="Cactus Builder" \
    GIT_COMMITTER_EMAIL="cactus-builder@localhost"

# Toolchain + Einstein Toolkit build deps -- same package set as
# x86-cpu/Dockerfile (see there for the full per-package rationale);
# bookworm ships slightly older versions of some of these than trixie does,
# which is an expected, accepted consequence of the OS choice above.
#
# One place that bites, hence `libboost1.81-all-dev` rather than the plain
# `libboost-all-dev` used by x86-cpu: the unversioned metapackage pulls
# bookworm's *default* Boost, which is 1.74, and the ET_2026_05 Boost thorn
# cannot detect that. Its find_lib requires the header `boost/system.hpp`,
# a convenience header Boost only added in 1.79 (the thorn dropped
# libboost_system from its *library* list because newer Boost removed it,
# but still demands that header) -- and Cactus's find_files requires ALL
# listed headers, so one missing header makes Boost "not found" even though
# every required library is present. bookworm main carries 1.81 alongside
# 1.74, so asking for it by version fixes this with no backports. trixie's
# default is already 1.83, which is why x86-cpu doesn't need this.
RUN apt update -y && apt install -y curl \
    cmake ninja-build gfortran gcc g++ libpapi-dev libgsl-dev liblapack-dev libblas-dev \
    libhdf5-dev libhdf5-openmpi-dev \
    libhdf5-mpich-dev \
    libpmi2-0-dev libpmix-dev libpmix-bin \
    pkg-config subversion git python3 patch make numactl libhwloc-dev \
    hwloc libssl-dev libfftw3-dev rsync libboost1.81-all-dev vim \
    zlib1g-dev libjpeg-dev libyaml-cpp-dev libsilo-dev nlohmann-json3-dev \
    && apt clean

# Sanity-check the toolchain versions this image is meant to guarantee.
RUN gcc_major=$(gcc -dumpversion | cut -d. -f1) && \
    if [ "$gcc_major" -lt 10 ]; then \
        echo "ERROR: gcc $gcc_major.x is older than the required gcc 10+" >&2; exit 1; \
    fi && \
    gcc --version | head -1 && python3.14 --version

# ---------------------------------------------------------------------------
# CUDA toolkit + Nsight Systems/Compute, via NVIDIA's official Debian-12 apt
# repo (cuda-keyring is NVIDIA's current standard method for adding the
# repo + signing key). The sbsa keyring installs a sources.list pointing at
# .../debian12/sbsa/, which is the ARM server repo -- confirmed by
# unpacking the .deb rather than assumed.
#
# Pinned to the 13-4 branch specifically, not the floating
# `cuda-toolkit`/`cuda` meta-packages, for the same reproducibility reason
# AMReX/ADIOS2/openPMD below are pinned to exact versions. 13.4 is the
# newest the sbsa repo carries; 13.1-13.3 are also present if a fallback is
# ever needed (e.g. an AMReX release that predates a CUDA 13 change).
# ---------------------------------------------------------------------------
RUN curl -sSLO https://developer.download.nvidia.com/compute/cuda/repos/debian12/sbsa/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && rm cuda-keyring_1.1-1_all.deb && \
    apt update -y && \
    apt install -y cuda-toolkit-13-4 cuda-nsight-systems-13-4 cuda-nsight-compute-13-4 && \
    apt clean

ENV PATH=/usr/local/cuda-13.4/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda-13.4/lib64

# Confirm this toolkit really can target Grace Hopper, and really cannot
# target Volta -- the second half matters because it is the cost of being on
# CUDA 13, and a silent change there would mean the image quietly stopped
# being what its optionlists claim.
RUN nvcc --version | tail -2 && \
    echo '__global__ void k(){}' > /tmp/t.cu && \
    nvcc -arch=sm_90 -c /tmp/t.cu -o /tmp/t.o && \
    echo "sm_90 compile: OK" && \
    if nvcc -arch=sm_70 -c /tmp/t.cu -o /tmp/t70.o 2>/dev/null; then \
        echo "ERROR: sm_70 compiled; this is not the CUDA 13 this image documents" >&2; \
        exit 1; \
    fi && \
    echo "sm_70 correctly rejected by CUDA 13" && \
    rm -f /tmp/t.cu /tmp/t.o /tmp/t70.o && \
    nsys --version && ncu --version | tail -2 && \
    # LIBDIRS in both optionlists names /usr/local/cuda/lib64, which on this
    # arch is a symlink into targets/sbsa-linux/lib. Check it here rather
    # than in check-deps.sh, which runs after the hour-long AMReX build.
    test -d /usr/local/cuda/lib64 && \
    ls /usr/local/cuda/lib64/libcurand.so >/dev/null && \
    echo "cuda lib64 -> $(readlink -f /usr/local/cuda/lib64): OK"

# ---------------------------------------------------------------------------
# Cactus / Einstein Toolkit ExternalLibraries dependencies -- same scope
# and rationale as x86-cpu/Dockerfile, prebuilding AMReX, ADIOS2 and
# openPMD-api once per MPI flavor.
#
# AMReX here is a CUDA build, and unlike a CPU build it has to name the GPU
# architectures it targets up front. Rather than defer the whole AMReX
# build to singularity time (which an earlier revision of the x86 image did,
# to stay GPU-agnostic), it is built for sm_90 -- see AMREX_CUDA_ARCHS
# below. Grace Hopper is a single known architecture, so unlike the x86
# image there is no fat binary to assemble here. Targeting anything else
# needs either a rebuild with AMREX_CUDA_ARCHS changed, or
# `AMREX_DIR = BUILD` in the optionlist to let Cactus build it at
# singularity time for that specific GPU.
#
# The architecture list is deliberately kept in sync with CUCCFLAGS /
# AMREX_CMAKE_CUDA_ARCHITECTURES in cactus-arm-cuda-openmpi.cfg and
# cactus-arm-cuda-mpich.cfg -- the thorns that consume AMReX are compiled by
# nvcc via those flags, so they must generate code for the same set of
# architectures this library was built for.
#
# ADIOS2 and openPMD-api are built without CUDA -- the GPU-arch dependency
# is specifically AMReX's; they are plain host-side I/O libraries.
ARG CACTUS_DEPS_PREFIX=/opt/cactus-deps
ARG AMREX_VERSION=25.11
ARG ADIOS2_VERSION=v2.12.1
ARG OPENPMD_VERSION=0.17.1
# Semicolon-separated, in CMAKE_CUDA_ARCHITECTURES form. sm_90 is current
# in CUDA 13, so -Wno-deprecated-gpu-targets is not silencing anything
# today; it is kept so that the flags stay identical in shape to the x86
# image's, and remains correct if an older architecture is ever added.
# -diag-suppress=20012 does the same for
# AMReX's own "__host__ annotation is ignored on a function(\"IndexTypeND\")
# that is explicitly defaulted on its first declaration", which it emits
# by the dozen from its headers and which no consumer can act on. Both
# match the CUCCFLAGS in the two optionlists, so the library and the
# thorns that consume it are compiled equally quietly.
ARG AMREX_CUDA_ARCHS="90"


# build_stack <flavor> <mpicc> <mpicxx> <h5pcc>
# One MPI-flavor's worth of AMReX + ADIOS2 + openPMD-api,
# installed under $CACTUS_DEPS_PREFIX/<name>-<flavor>. Called once per
# flavor below.
#
# The AMReX CUDA options mirror what Cactus's own AMReX build.sh passes
# when it builds the bundled copy (-DAMReX_GPU_BACKEND=CUDA plus the two
# AMReX_CUDA_ERROR_* settings), so this prebuilt library matches what the
# thorn would have produced -- with CMAKE_CUDA_ARCHITECTURES fixed to
# AMREX_CUDA_ARCHS instead of a single site-specific value.
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
            -DAMReX_ASSERTIONS=OFF -DAMReX_PIC=ON -DAMReX_HDF5=OFF -DAMReX_LINEAR_SOLVERS=ON \
            -DAMReX_GPU_BACKEND=CUDA \
            -DAMReX_CUDA_ERROR_CAPTURE_THIS=ON \
            -DAMReX_CUDA_ERROR_CROSS_EXECUTION_SPACE_CALL=ON \
            -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.4/bin/nvcc \
            -DCMAKE_CUDA_ARCHITECTURES="$AMREX_CUDA_ARCHS" \
            -DCMAKE_CUDA_FLAGS="-Wno-deprecated-gpu-targets -diag-suppress=20012"; \
        cmake --build "$build/amrex/build" -j"$(nproc)"; \
        cmake --install "$build/amrex/build"; \
        for arch in $(echo "$AMREX_CUDA_ARCHS" | tr ';' ' '); do \
            cuobjdump --list-elf "$CACTUS_DEPS_PREFIX/amrex-$flavor/lib/"libamrex*.a \
                | grep -q "sm_$arch" \
                || { echo "ERROR: libamrex ($flavor) contains no sm_$arch device code" >&2; exit 1; }; \
        done; \
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
# apart -- which they did, silently, when this was duplicated per image.
#
# What remains here is the Cactus half: HDF5 per flavor, the prebuilt
# AMReX/ADIOS2/openPMD, the optionlists, and sim-config.sh.


# Cactus optionlists pointing at the dependencies built/installed above --
# see the header comment in each file for the full explanation of every
# setting, and which one to pick for a given HPC site's PMI support.
# Interposed cuda_runtime.h -- see the header itself for why. CUCCFLAGS
# names this directory with -I, ahead of CUDA's own headers.
COPY cuda-compat/cuda_runtime.h /opt/cactus-deps/cuda-compat/cuda_runtime.h
RUN set -ex; \
    printf '%s\n' \
      '#include <cuda_runtime.h>' \
      'namespace Arith { __host__ __device__ constexpr bool all(bool x){return x;}' \
      '                  __host__ __device__ constexpr bool any(bool x){return x;} }' \
      'namespace CarpetX { using namespace Arith;' \
      '  __host__ __device__ inline void f(){ bool b=true; static_assert(all(true));' \
      '    (void)all(b); (void)any(b); } }' \
      '__global__ void k(int *p){ atomicAdd(p,1); CarpetX::f(); }' \
      > /tmp/ambig.cu; \
    # Without the interposer this is the CarpetX failure, verbatim:
    #   error: more than one instance of overloaded function "all" matches
    if nvcc -x cu -std=c++17 -arch=sm_90 -c /tmp/ambig.cu -o /tmp/ambig.o 2>/dev/null; then \
        echo "ERROR: the ambiguity did not reproduce; the interposer may be untested" >&2; exit 1; \
    fi; \
    nvcc -x cu -std=c++17 -arch=sm_90 -I/opt/cactus-deps/cuda-compat \
        -c /tmp/ambig.cu -o /tmp/ambig.o; \
    echo "cuda-compat: CarpetX all()/any() ambiguity resolved, atomicAdd intact"; \
    rm -f /tmp/ambig.cu /tmp/ambig.o

COPY cactus-arm-cuda-openmpi.cfg /opt/cactus-deps/cactus-arm-cuda-openmpi.cfg
COPY cactus-arm-cuda-mpich.cfg /opt/cactus-deps/cactus-arm-cuda-mpich.cfg

# Verify every dependency the optionlists reference is actually present, in
# the exact shape Cactus's find_lib looks for -- see check-deps.sh for why
# "installed" and "detectable" aren't the same question. Runs as part of
# the build so a gap fails here rather than surfacing during a real Cactus
# build on a cluster; also left in the image to re-run against a deployed
# container:  singularity exec image.simg /opt/cactus-deps/check-deps.sh
COPY check-deps.sh /opt/cactus-deps/check-deps.sh
RUN chmod +x /opt/cactus-deps/check-deps.sh && /opt/cactus-deps/check-deps.sh

# Compile and link a small AMReX CUDA program using each optionlist's own
# CUCC/CUCCFLAGS/LIBS against that optionlist's prebuilt AMReX -- so the
# flags in the cfgs and the flags libamrex was actually built with can't
# drift apart silently. See the script header for the specific failures
# each checked flag prevents. Compiling/linking needs no GPU; running does,
# which is why this stops at a linked executable.
COPY amrex-cuda-smoke.sh /opt/cactus-deps/amrex-cuda-smoke.sh
RUN chmod +x /opt/cactus-deps/amrex-cuda-smoke.sh && \
    /opt/cactus-deps/amrex-cuda-smoke.sh /opt/cactus-deps/cactus-arm-cuda-openmpi.cfg openmpi && \
    /opt/cactus-deps/amrex-cuda-smoke.sh /opt/cactus-deps/cactus-arm-cuda-mpich.cfg mpich

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
            -Dpapi=enabled -Dhpcprof_mpi=enabled -Dcuda=enabled \
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

# Debian slim ships only C, C.UTF-8 and POSIX. Singularity passes the host's
# environment into the container, so a login shell with LANG=en_US.UTF-8 --
# the overwhelmingly common HPC default -- lands in here naming a locale that
# does not exist, and every perl the Cactus build runs (CST, Formaline,
# simfactory) prefaces its output with "perl: warning: Setting locale
# failed". Harmless, but it buries the build output that matters.
#
# Two independent fixes, because which environment wins when Singularity
# merges host and image is version-dependent:
#   1. generate en_US.UTF-8, so the common host value is real;
#   2. ENV LANG below, so the image names a locale that always exists.
# A host locale other than these still warns; the escape hatch from outside
# is SINGULARITYENV_LANG=C.UTF-8, and a derived image can uncomment more
# lines in /etc/locale.gen and re-run locale-gen.
RUN set -ex; \
    apt update -y; \
    apt install -y --no-install-recommends locales; \
    apt clean; \
    sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    for l in en_US.UTF-8 C.UTF-8; do \
        out=$(LANG=$l perl -e 'print q{}' 2>&1); \
        test -z "$out" || { echo "ERROR: perl still warns under LANG=$l:" >&2; \
                            echo "$out" >&2; exit 1; }; \
    done
ENV LANG=C.UTF-8

# Make `hostname` self-identify as this image. CACTUS_IMAGE_NAME is the
# reliable programmatic hook (the hostname shim is a convenience for
# shells and for SimFactory's machine detection); see hostname-wrapper.sh
# for why gethostname(2) is deliberately left alone.
ENV CACTUS_IMAGE_NAME=cactus-arm-cuda
COPY hostname-wrapper.sh /usr/local/bin/hostname
RUN set -ex; \
    chmod +x /usr/local/bin/hostname; \
    real=$(/usr/bin/hostname); \
    test "$(hostname)" = "cactus-arm-cuda-$real"; \
    test "$(hostname -s)" = "cactus-arm-cuda-$(/usr/bin/hostname -s)"; \
    test "$(env -u CACTUS_IMAGE_NAME hostname)" = "cactus-arm-cuda-$real"; \
    test "$(hostname -I)" = "$(/usr/bin/hostname -I)"

# sim-config.sh is the one launcher-adjacent tool that IS Cactus-specific
# (it generates SimFactory machine entries), so it lives here rather than in
# mpi-base. The rest -- unslurm.py, singssh, mpirun.py, mpi-matrix.sh -- are
# inherited, along with their assertions; repeating those here would only
# create a second copy to drift.
COPY bin/sim-config.sh /usr/local/bin/
RUN set -ex; \
    chmod +x /usr/local/bin/sim-config.sh; \
    # sim-config.sh ships here but runs outside the container: --emit must
    # hand back its own source byte for byte, or the documented way of
    # getting it out of a deployed image is broken.
    sim-config.sh --emit | cmp -s - /usr/local/bin/sim-config.sh; \
    sim-config.sh --help | grep -q 'machine'; \
    ! sim-config.sh --machine m --image /i.simg --mpi pmi2 >/dev/null 2>&1; \
    # Confirm the base really is underneath: the inherited tools are on
    # PATH, both MPI prefixes work, and a 2-rank job runs. Cheap, and it
    # fails loudly if MPI_BASE is ever pointed at the wrong thing.
    for t in unslurm.py singssh mpirun.py mpi-matrix.sh pmi-test-mpich pmi-test-openmpi; do \
        command -v "$t" >/dev/null || { echo "ERROR: $t missing -- is MPI_BASE right?" >&2; exit 1; }; \
    done; \
    /opt/mpi/mpich/bin/mpirun -np 2 pmi-test-mpich | grep -q "PMI-TEST: PASS"; \
    /opt/mpi/openmpi/bin/mpirun --allow-run-as-root -np 2 pmi-test-openmpi \
        | grep -q "PMI-TEST: PASS"

RUN useradd -m -u 1168 -s /bin/bash jovyan

USER jovyan
WORKDIR /home/jovyan

EXPOSE 8888

CMD ["jupyterhub-singleuser"]
