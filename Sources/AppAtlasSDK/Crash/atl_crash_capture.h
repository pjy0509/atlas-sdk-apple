// atl_crash_capture.h: the native capture core, plain C so the Objective-C
// runtime is never on the crash path. Installed once from ATLCrash; a crash
// writes a line-based report to the path given, read by ATLNativeReport at
// the next start.
#ifndef ATL_CRASH_CAPTURE_H
#define ATL_CRASH_CAPTURE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// What to install. Under a debugger neither is (LLDB and a mach exception
// server fight over the port and both lose), and the caller is told so.
#define ATL_CRASH_MACH 1u
#define ATL_CRASH_SIGNALS 2u

// Installs the mach exception server and the signal handlers, and takes the
// snapshot of loaded images every later frame is resolved against. Returns
// a bitmask of what was actually installed; 0 under a debugger or when the
// path does not fit. Call on the main thread, once.
unsigned atl_crash_install(const char *report_path, unsigned wanted);

// True when a debugger has the process (sysctl P_TRACED).
int atl_crash_debugger_attached(void);

// True once a report has been written in this process: the next handler in
// line steps aside instead of writing a second one.
int atl_crash_did_crash(void);

// The uncaught-exception path. Called from the NSException handler after
// every Objective-C read is done: the name and reason are copied C strings
// (no newlines), the addresses are the exception's own return addresses.
// Writes the report with every other thread suspended, then returns so the
// caller can chain to the previous handler.
void atl_crash_write_exception(const char *name, const char *reason, const uintptr_t *addresses, int count);

// One resolved frame, for code that is not crashing (the hang watchdog): the
// address relative to its image, the image's UUID as 32 lowercase hex
// characters, and its path. Zero-length strings when the address is in no
// known image.
typedef struct {
    uintptr_t address;
    uintptr_t relative;
    char uuid[33];
    char path[512];
} atl_crash_frame_t;

int atl_crash_locate(uintptr_t address, atl_crash_frame_t *out);

// Suspends the main thread, walks its frame pointers, resumes it. For the
// hang watchdog; returns the number of addresses written.
int atl_crash_snapshot_main(uintptr_t *addresses, int max);

// Refreshes the thread-name cache from a thread that is not crashing (the
// watchdog's tick): another thread's name cannot be read safely at crash
// time, so the report uses what was seen last.
void atl_crash_refresh_thread_names(void);

#ifdef __cplusplus
}
#endif

#endif
