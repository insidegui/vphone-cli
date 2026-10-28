#pragma once
#include <unistd.h>

// libSystem exports fork on darwinOS, although the iPhoneOS SDK marks it
// unavailable to applications. Research-guest tools use the native export.
pid_t vp_ssh_fork(void);
#define fork vp_ssh_fork
// Use a full address-space copy for dash's vfork optimization too.
#define vfork vp_ssh_fork
