/* Interposed ahead of CUDA's own cuda_runtime.h on the include path, via
 * -I/opt/cactus-deps/cuda-compat in CUCCFLAGS.
 *
 * CUDA declares two deprecated warp-vote helpers at GLOBAL scope:
 *
 *   __device__ bool any(bool cond);
 *   __device__ bool all(bool cond);
 *
 * (device_atomic_functions.h, unconditionally -- CUDA 12.9 and 13.4 alike).
 * CarpetX's Arith declares constexpr bool all(bool) / any(bool) of its own,
 * and CarpetX code calls them unqualified with `using namespace Arith` in
 * scope. Two identical signatures in one overload set is ambiguous, and the
 * build dies in boundaries_impl.hxx with
 *
 *   error: more than one instance of overloaded function "all" matches
 *          the argument list ... argument types are: (bool)
 *
 * The fix has to be compiler-side: the Cactus sources are not ours to
 * change, and every other lever was tried and rejected --
 *   -include <shadow>            nvcc pre-includes cuda_runtime.h first,
 *                                so the rename lands too late
 *   -D__DEVICE_ATOMIC_FUNCTIONS_H__  skips the whole header, taking
 *                                atomicAdd() and friends with it
 *   -D on the command line       renames Arith's copy too, so the pair
 *                                stays ambiguous
 *
 * Interposition works because nvcc's implicit `#include "cuda_runtime.h"`
 * finds this file first: the two names are renamed for the duration of
 * CUDA's own headers and restored immediately afterwards, so CUDA's
 * versions simply are not called `all`/`any` any more and nothing else in
 * the translation unit is affected. Verified that std::any, std::all_of,
 * and members named all/any still compile, and that atomicAdd survives.
 *
 * The renamed functions remain reachable as __cuda_deprecated_vote_{any,all}
 * for anyone who genuinely wants the pre-Volta warp vote; use the
 * __any_sync()/__all_sync() intrinsics instead.
 */
#define any __cuda_deprecated_vote_any
#define all __cuda_deprecated_vote_all
#include_next <cuda_runtime.h>
#undef any
#undef all
