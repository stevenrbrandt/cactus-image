#!/bin/bash
#
# amrex-cuda-smoke.sh -- compile and link a small AMReX CUDA program using
# the *exact* CUCC/CUCCFLAGS/LIBS from an optionlist in this image, against
# that optionlist's prebuilt AMReX and MPI.
#
# The point is drift: the optionlists' CUDA flags and the flags libamrex was
# actually built with have to agree, and when they don't the failure is
# invisible until someone compiles a CarpetX thorn on a cluster. Every flag
# this checks was added in response to a real failure found this way:
#   - no -Xcompiler -fopenmp        -> AMReX_Config_3D.H #error, "libamrex
#                                      was built with OpenMP, so the
#                                      downstream project must activate it"
#   - no --extended-lambda          -> "__host__ or __device__ annotation on
#                                      lambda requires --extended-lambda"
#   - no --relocatable-device-code  -> device-link mismatch against an
#                                      RDC-built libamrex
#   - no `LIBS = curand`            -> "undefined reference to
#                                      curandCreateGenerator" at final link
#                                      (AMReX_Random.cpp calls cuRAND)
#   - no -diag-suppress=20012       -> a dozen copies per TU of "__host__
#                                      annotation is ignored on a
#                                      function(\"IndexTypeND\")", from
#                                      AMReX's headers, burying real
#                                      diagnostics
#   - no `LIBS = ... gfortran`      -> "undefined reference to symbol
#                                      '_gfortran_string_scan@@GFORTRAN_8'
#                                      ... DSO missing from command line",
#                                      hit on a real A100 build from the
#                                      EHFinder thorn. LD is nvcc->g++, not
#                                      gfortran, so libgfortran is only on
#                                      the link line if LIBS says so.
#
# It does NOT run anything: compiling and linking needs no GPU, but
# executing does, and the image build has none. Running on real hardware is
# still the last unproven step.
#
# Usage: amrex-cuda-smoke.sh <optionlist.cfg> <openmpi|mpich>
#
set -eu

cfg="${1:?usage: amrex-cuda-smoke.sh <optionlist.cfg> <openmpi|mpich>}"
flavor="${2:?usage: amrex-cuda-smoke.sh <optionlist.cfg> <openmpi|mpich>}"

# Pull values straight out of the optionlist, so this tests what Cactus
# would actually use rather than a copy that can rot.
cfg_get() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$cfg" | head -1; }

CUCC=$(cfg_get CUCC)
CUCCFLAGS=$(cfg_get CUCCFLAGS)
LD_LINE=$(cfg_get LD)
LIBS=$(cfg_get LIBS)
AMREX_DIR=$(cfg_get AMREX_DIR)
MPI_INC_DIRS=$(cfg_get MPI_INC_DIRS)
MPI_LIB_DIRS=$(cfg_get MPI_LIB_DIRS)
MPI_LIBS=$(cfg_get MPI_LIBS)
LIBDIRS=$(cfg_get LIBDIRS)

[ -n "$CUCC" ]      || { echo "smoke: no CUCC in $cfg" >&2; exit 1; }
[ -n "$AMREX_DIR" ] || { echo "smoke: no AMREX_DIR in $cfg" >&2; exit 1; }

inc_flags=""
for d in $MPI_INC_DIRS; do inc_flags="$inc_flags -I$d"; done
inc_flags="-I$AMREX_DIR/include $inc_flags"

lib_flags="-L$AMREX_DIR/lib -lamrex"
for d in $MPI_LIB_DIRS; do lib_flags="$lib_flags -L$d"; done
for l in $MPI_LIBS; do lib_flags="$lib_flags -l$l"; done
# Mirror what Cactus does with LIBDIRS: its GENERAL_LIBRARIES emits both
# LIBDIR_PREFIX (-L) and RUNDIR_PREFIX (-Wl,-rpath,) for every entry.
for d in $LIBDIRS; do lib_flags="$lib_flags -L$d -Wl,-rpath,$d"; done
for l in $LIBS; do lib_flags="$lib_flags -l$l"; done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/smoke.cpp" <<'EOF'
#include <AMReX.H>
#include <AMReX_MultiFab.H>
#include <AMReX_Print.H>

// Mirrors how CarpetX actually writes kernels: a device lambda launched
// through amrex::ParallelFor. This is what needs --extended-lambda.
int main(int argc, char *argv[]) {
  amrex::Initialize(argc, argv);
  amrex::Box bx(amrex::IntVect(0), amrex::IntVect(3));
  amrex::ParallelFor(bx, [=] AMREX_GPU_DEVICE(int i, int j, int k) noexcept {
    (void)i; (void)j; (void)k;
  });
  amrex::Print() << "amrex-cuda-smoke ok\n";
  amrex::Finalize();
  return 0;
}
EOF

# Cactus links Fortran thorns into the same executable, and LD here is
# nvcc->g++ rather than gfortran, so nothing pulls in libgfortran unless
# LIBS says so. Linking a Fortran TU here is what makes a missing
# `gfortran` in LIBS fail the image build instead of surfacing as
# "undefined reference to _gfortran_string_scan" during a real Cactus
# build on a cluster.
cat > "$work/smoke_f.f90" <<'EOF'
      subroutine smoke_scan(s, n)
      character(len=*) :: s
      integer :: n
      n = scan(s, "abc")
      end subroutine
EOF
echo "smoke[$flavor]: compiling Fortran TU with F90/F90FLAGS from $(basename "$cfg")"
F90=$(cfg_get F90); F90FLAGS=$(cfg_get F90FLAGS)
# shellcheck disable=SC2086
${F90:-gfortran} $F90FLAGS -c "$work/smoke_f.f90" -o "$work/smoke_f.o"

echo "smoke[$flavor]: compiling with CUCCFLAGS from $(basename "$cfg")"
# shellcheck disable=SC2086
# Not piped to tee: under `set -e` a pipeline's status is tee's, which
# would turn a failed compile into a silent pass.
$CUCC $CUCCFLAGS -c "$work/smoke.cpp" -o "$work/smoke.o" $inc_flags \
    > "$work/cucc.log" 2>&1 || { cat "$work/cucc.log" >&2; exit 1; }
cat "$work/cucc.log"

# smoke.cpp includes AMReX_MultiFab.H, which is exactly what makes nvcc
# emit a dozen copies of #20012-D per translation unit. Failing here means
# `-diag-suppress=20012` fell out of CUCCFLAGS, and every CarpetX thorn
# compile would go back to burying real diagnostics under it.
if grep -q "warning #20012-D" "$work/cucc.log"; then
    echo "smoke[$flavor]: FAIL -- #20012-D not suppressed; is -diag-suppress=20012 still in CUCCFLAGS?" >&2
    exit 1
fi

echo "smoke[$flavor]: linking with LD/LIBS from $(basename "$cfg")"
# The optionlist's LD carries nvcc plus its host-compiler forwarding; the
# gencode flags have to come along so the device link emits both arches.
gencode=$(printf '%s\n' $CUCCFLAGS | grep -E '^-gencode' | tr '\n' ' ')
# shellcheck disable=SC2086
$LD_LINE $gencode -Wno-deprecated-gpu-targets -Xcompiler -fopenmp \
    "$work/smoke.o" "$work/smoke_f.o" -o "$work/smoke" $lib_flags

# LIBDIRS exists in the optionlist for its rpath, not its -L (nvcc passes
# an equivalent -L on its own). An executable that links but records no
# RUNPATH is the silent failure mode: it runs here and then dies with
# "libcurand.so.10: cannot open shared object file" on a cluster whose
# LD_LIBRARY_PATH does not happen to name the toolkit -- which is the
# normal case under Singularity. So assert the rpath actually landed.
for d in $LIBDIRS; do
    if ! readelf -d "$work/smoke" | grep -qE '(RUNPATH|RPATH).*'"$d"; then
        echo "smoke[$flavor]: FAIL -- $d absent from RUNPATH/RPATH of the linked executable" >&2
        readelf -d "$work/smoke" | grep -E 'RUNPATH|RPATH' >&2 || echo "  (no RUNPATH/RPATH at all)" >&2
        exit 1
    fi
    echo "smoke[$flavor]: rpath contains $d"
done

# The whole point of the fat binary: both architectures must survive the
# device link into the final executable, not just into libamrex.
archs=$(cuobjdump --list-elf "$work/smoke" | grep -oE 'sm_[0-9]+' | sort -u | tr '\n' ' ')
echo "smoke[$flavor]: linked executable contains: $archs"
for want in $(printf '%s\n' $CUCCFLAGS | grep -oE 'code=sm_[0-9]+' | cut -d= -f2 | sort -u); do
    case " $archs " in
        *" $want "*) ;;
        *) echo "smoke[$flavor]: FAIL -- executable has no $want device code" >&2; exit 1 ;;
    esac
done

echo "smoke[$flavor]: OK"
