#ifndef DARWIN_CALLS_H
#define DARWIN_CALLS_H

#include <mach/mach.h>
#include <sys/types.h>

// The parts of Darwin that Swift cannot reach on its own: the bootstrap calls, which the SDK
// marks unavailable to Swift; the function-like macros, which Swift does not import; and
// the kernel's code signing call, which no public header declares. Each is a pass-through,
// so the meaning stays with the Swift that calls it.

// Puts `port` in the session's bootstrap namespace under `name`, the way CFMessagePort's
// own local ports are published. A process macOS launches from a bundle has no launchd job
// to check a name in with, so registering is the only way it can be found.
kern_return_t lt_bootstrap_register(const char *name, mach_port_t port);

// A send right to whatever is registered under `name`.
kern_return_t lt_bootstrap_look_up(const char *name, mach_port_t *port);

// The receive option that asks the kernel to append the sender's audit token.
mach_msg_option_t lt_receive_with_audit_trailer(void);

// A header's bits for a message moving its remote right as `remote` and its local right
// as `local`.
mach_msg_bits_t lt_msgh_bits(mach_msg_type_name_t remote, mach_msg_type_name_t local);

// The right a received header carries in its remote (reply) field.
mach_msg_type_name_t lt_msgh_bits_remote(mach_msg_bits_t bits);

// What the kernel knows of the code a process runs, asked by audit token so the answer is
// about that process and no other. Declared in xnu's sys/codesign.h, which the SDK leaves
// out; the operations are that header's CS_OPS_ numbers.
int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token);

#endif
