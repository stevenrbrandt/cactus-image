// Reduced from CarpetX's boundaries_impl.hxx: the pattern whose failure
// decides which CUDA this image may use.
//
// Arith declares all() as a HIDDEN FRIEND of vect, findable only by
// argument-dependent lookup, alongside a namespace-scope all(bool); CUDA
// declares its own deprecated all(bool) at global scope. Finding the hidden
// friend is what makes the call unambiguous. nvcc 13.4 does not find it,
// and CarpetX cannot be compiled; 12.9 through 13.3 do.
#include <cuda_runtime.h>

namespace Arith {
template <typename T, int D> struct vect {
  T elts[D];
  friend constexpr __host__ __device__ auto operator==(const vect &x, T a) {
    vect<bool, D> r{};
    for (int i = 0; i < D; ++i)
      r.elts[i] = x.elts[i] == a;
    return r;
  }
  friend constexpr __host__ __device__ auto all(const vect &x) {
    bool r = true;
    for (int i = 0; i < D; ++i)
      r = r && bool(x.elts[i]);
    return r;
  }
};
constexpr __host__ __device__ bool all(bool x) { return x; } // defs.hxx
} // namespace Arith

namespace CarpetX {
using namespace Arith;
template <int NI, int NJ, int NK> void apply_on_face() {
  constexpr Arith::vect<int, 3> inormal{NI, NJ, NK};
  static_assert(!all(inormal == 0));
}
void go() { apply_on_face<0, -1, -1>(); }
} // namespace CarpetX
