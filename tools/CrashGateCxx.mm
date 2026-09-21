// CrashGateCxx.mm: the one C++ line the crash gate needs, kept out of the
// Objective-C gate so the gate itself stays ObjC. Throws what nobody
// catches, the way an app's C++ dependency would.
#include <stdexcept>

extern "C" void gate_throw_cxx(void) {
    throw std::runtime_error("gate cxx: thrown on purpose");
}
