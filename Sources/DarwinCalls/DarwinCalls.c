#include "DarwinCalls.h"
#include <servers/bootstrap.h>

// Deprecated since the day launchd arrived, and still what CFMessagePortCreateLocal does
// under the hood; there is no other way to publish a name without a launchd job.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
kern_return_t lt_bootstrap_register(const char *name, mach_port_t port) {
    return bootstrap_register(bootstrap_port, (char *)name, port);
}
#pragma clang diagnostic pop

kern_return_t lt_bootstrap_look_up(const char *name, mach_port_t *port) {
    return bootstrap_look_up(bootstrap_port, name, port);
}

mach_msg_option_t lt_receive_with_audit_trailer(void) {
    return MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
}

mach_msg_bits_t lt_msgh_bits(mach_msg_type_name_t remote, mach_msg_type_name_t local) {
    return MACH_MSGH_BITS(remote, local);
}

mach_msg_type_name_t lt_msgh_bits_remote(mach_msg_bits_t bits) {
    return MACH_MSGH_BITS_REMOTE(bits);
}
