#!/bin/bash
#
# check-deps.sh -- verify every ExternalLibrary this image's optionlists
# point at is actually present, and present in the specific shape Cactus
# looks for.
#
# Why this exists: "the package is installed" and "Cactus can detect it"
# are different questions. Each ExternalLibraries thorn's detect.sh calls
# find_lib with an explicit list of headers AND libraries, and Cactus's
# find_files requires *all* of them -- so a single missing header makes an
# otherwise fully-installed library undetectable, and the failure only
# surfaces much later, during a real build on a cluster. That is exactly
# what happened with Boost on Debian bookworm: every required library was
# present, but the default Boost (1.74) lacks boost/system.hpp, which the
# ET_2026_05 thorn demands (added upstream in Boost 1.79).
#
# The requirement lists below are copied from each thorn's own find_lib
# call in ExternalLibraries-<Thorn>/src/detect.sh (ET_2026_05), so they
# check what Cactus actually checks rather than what seems reasonable.
#
# Run at image build time (the build fails if anything is missing), and
# usable later against a deployed image:
#     singularity exec image.simg /opt/cactus-deps/check-deps.sh
#
set -u

fail=0
note() { printf '  %-14s %s\n' "$1" "$2"; }
bad()  { printf '  MISSING %-6s %s\n' "$1" "$2"; fail=1; }

# have_header <dir> <relative/header.h>
have_header() { [ -f "$1/include/$2" ]; }

# have_lib <libname> <dir...>
have_lib() {
    local l="$1"; shift
    local d
    for d in "$@"; do
        [ -n "$(echo "$d/lib$l".so* "$d/lib$l".a 2>/dev/null | tr ' ' '\n' | while read -r f; do [ -e "$f" ] && echo "$f"; done)" ] && return 0
    done
    return 1
}

SYS_LIBDIRS="/usr/lib/x86_64-linux-gnu /usr/lib /usr/lib64"

# check_lib <label> <prefix> <headers...> -- <libs...>
check_lib() {
    local label="$1" prefix="$2"; shift 2
    local headers=() libs=() seen_sep=0 a
    for a in "$@"; do
        if [ "$a" = "--" ]; then seen_sep=1; continue; fi
        if [ $seen_sep -eq 0 ]; then headers+=("$a"); else libs+=("$a"); fi
    done
    local h l ok=1
    for h in "${headers[@]:-}"; do
        [ -z "$h" ] && continue
        have_header "$prefix" "$h" || { bad "HEADER" "$label: $prefix/include/$h"; ok=0; }
    done
    for l in "${libs[@]:-}"; do
        [ -z "$l" ] && continue
        have_lib "$l" $SYS_LIBDIRS "$prefix/lib" || { bad "LIB" "$label: lib$l"; ok=0; }
    done
    [ $ok -eq 1 ] && note "$label" "ok"
}

echo "== apt-provided ExternalLibraries =="

# Boost: the full list its find_lib demands. boost/system.hpp is the one
# that catches out distros shipping Boost < 1.79.
check_lib Boost /usr \
    boost/atomic.hpp boost/filesystem.hpp boost/math/constants/constants.hpp \
    boost/math/tr1.hpp boost/system.hpp \
    -- boost_atomic boost_filesystem boost_math_c99 boost_math_c99f \
       boost_math_c99l boost_math_tr1 boost_math_tr1f boost_math_tr1l

check_lib GSL      /usr gsl/gsl_version.h -- gsl
check_lib zlib     /usr zlib.h            -- z
check_lib yaml_cpp /usr yaml-cpp/yaml.h   -- yaml-cpp
check_lib Silo     /usr silo.h            -- siloh5
check_lib libjpeg  /usr jpeglib.h         -- jpeg
check_lib FFTW3    /usr fftw3.h           -- fftw3
check_lib hwloc    /usr hwloc.h           -- hwloc
check_lib OpenSSL  /usr openssl/ssl.h     -- ssl crypto
check_lib BLAS     /usr ''                -- blas
check_lib LAPACK   /usr ''                -- lapack

echo "== HDF5 (one build per MPI flavor) =="
for flavor in openmpi mpich; do
    inc="/usr/include/hdf5/$flavor"
    libdir="/usr/lib/x86_64-linux-gnu/hdf5/$flavor"
    ok=1
    [ -f "$inc/hdf5.h" ] || { bad "HEADER" "hdf5-$flavor: $inc/hdf5.h"; ok=0; }
    for l in hdf5 hdf5_hl hdf5_fortran hdf5hl_fortran; do
        have_lib "$l" "$libdir" || { bad "LIB" "hdf5-$flavor: lib$l"; ok=0; }
    done
    [ $ok -eq 1 ] && note "hdf5-$flavor" "ok"
done

echo "== MPI prefixes =="
for flavor in openmpi mpich; do
    p="/opt/mpi/$flavor"
    ok=1
    [ -x "$p/bin/mpirun" ]   || { bad "BIN" "$flavor: $p/bin/mpirun"; ok=0; }
    [ -f "$p/include/mpi.h" ] || { bad "HEADER" "$flavor: $p/include/mpi.h"; ok=0; }
    ls "$p/lib/"libmpi*.so* >/dev/null 2>&1 || { bad "LIB" "$flavor: $p/lib/libmpi*"; ok=0; }
    [ $ok -eq 1 ] && note "mpi-$flavor" "ok"
done

echo "== prebuilt stacks (per MPI flavor) =="
for flavor in openmpi mpich; do
    for pkg in "amrex:include/AMReX.H" "adios2:include/adios2.h" "openpmd:include/openPMD/openPMD.hpp"; do
        name="${pkg%%:*}"; probe="${pkg#*:}"
        d="/opt/cactus-deps/$name-$flavor"
        if [ -f "$d/$probe" ]; then note "$name-$flavor" "ok"; else bad "PKG" "$name-$flavor: $d/$probe"; fi
    done
done

echo "== optionlist cross-check =="
# Anything an optionlist names via *_DIR must actually exist. This catches
# a cfg pointing at a path that isn't in the image (e.g. copying another
# distro's layout, where MPICH's libs live somewhere else).
for cfg in /opt/cactus-deps/*.cfg; do
    [ -e "$cfg" ] || continue
    while IFS= read -r line; do
        key=${line%%=*}; key=${key// /}
        val=${line#*=}; val=${val# }; val=${val% }
        case "$val" in
            NO_BUILD|BUILD|'') continue ;;
        esac
        for d in $val; do
            case "$d" in
                /*) [ -e "$d" ] || bad "PATH" "$(basename "$cfg"): $key = $d" ;;
            esac
        done
    done < <(grep -E '^[A-Z_0-9]+_(DIR|DIRS)[[:space:]]*=' "$cfg")
    note "$(basename "$cfg")" "paths ok"
done

echo
if [ $fail -eq 0 ]; then
    echo "check-deps: OK -- every dependency the optionlists reference is present"
else
    echo "check-deps: FAILED -- see MISSING entries above" >&2
fi
exit $fail
