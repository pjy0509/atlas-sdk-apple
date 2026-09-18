// atl_crash_capture.c: native crash capture for Darwin.
//
// Three hooks, in the order the kernel fires them: a mach exception server
// (the faults — EXC_BAD_ACCESS and friends — arrive here first, on a thread
// of our own, before any signal is made of them), POSIX signal handlers on an
// alternate stack (SIGABRT never comes through mach; EXC_CRASH is not ours to
// take), and the NSException path, entered from Objective-C once the runtime
// has copied everything into C.
//
// Everything reachable from a handler is async-signal-safe: no allocation, no
// stdio, no locks, no Objective-C; only open/write/close, mach traps, and
// memory reserved at install. The report is line-based text the Objective-C
// half reads at the next start (ATLNativeReport.m). FROZEN once shipped: the
// line vocabulary.
//
// The recipe is docs/sdk-cautions.md §1.2 of the server repo, in that order.
#include "atl_crash_capture.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

#if !defined(__LP64__)
// iOS 12 and macOS 10.13 are 64-bit only; a 32-bit slice gets the stubs so
// the module still links, and reports nothing.
unsigned atl_crash_install(const char *report_path, unsigned wanted) { (void) report_path; (void) wanted; return 0; }
int atl_crash_debugger_attached(void) { return 0; }
int atl_crash_did_crash(void) { return 0; }
void atl_crash_write_exception(const char *n, const char *r, const uintptr_t *a, int c) { (void) n; (void) r; (void) a; (void) c; }
int atl_crash_locate(uintptr_t address, atl_crash_frame_t *out) { (void) address; (void) out; return 0; }
int atl_crash_snapshot_main(uintptr_t *addresses, int max) { (void) addresses; (void) max; return 0; }
void atl_crash_refresh_thread_names(void) {}
#else

#define MAX_FRAMES 128
#define MAX_IMAGES 1024
#define MAX_PATH 1024
#define MAX_THREAD_NAMES 256
#define MAX_TEXT 1024
#define ALT_STACK_BYTES (256 * 1024)
#define HANDLER_STACK_BYTES (256 * 1024)
#define PAGE_ALIGNED __attribute__((aligned(16384)))

// The five the kernel will actually deliver to a task port. EXC_CRASH and
// EXC_RESOURCE are excluded on purpose: the kernel never hands EXC_CRASH to
// the task that raised it, which is why the SIGABRT handler stays essential.
#define MACH_MASK (EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_SOFTWARE \
                   | EXC_MASK_BREAKPOINT)

static const int SIGNALS[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGPIPE, SIGSEGV, SIGSYS, SIGTRAP};
#define SIGNAL_COUNT ((int) (sizeof(SIGNALS) / sizeof(SIGNALS[0])))

// --- state reserved at install ------------------------------------------------------

struct image {
    uintptr_t load;      // the mach header, where __TEXT is mapped
    uintptr_t size;      // __TEXT's vmsize
    uintptr_t crash_info; // __DATA,__crash_info, or 0
    uint8_t uuid[16];
    char has_uuid;
    char path[MAX_PATH];
};

struct thread_name {
    uint64_t id;
    char name[64];
};

static char report_path[MAX_PATH];
static volatile sig_atomic_t handling;
static volatile sig_atomic_t crashed;
static unsigned installed_kinds;

static struct image images[MAX_IMAGES];
static volatile int image_count;

static struct thread_name thread_names[MAX_THREAD_NAMES];
static volatile int thread_name_count;
static uint64_t main_thread_id;
static mach_port_t main_thread_port;

// The signal side.
static struct sigaction previous_actions[SIGNAL_COUNT];
static char signal_installed[SIGNAL_COUNT];
static unsigned char alt_stack[ALT_STACK_BYTES] PAGE_ALIGNED;

// The mach side.
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t NDR;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    mach_exception_data_type_t code[2];
    char padding[512];
} atl_mach_message_t;

typedef struct {
    mach_msg_header_t header;
    NDR_record_t NDR;
    kern_return_t return_code;
} atl_mach_reply_t;

struct saved_ports {
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count;
};

static mach_port_t exception_port = MACH_PORT_NULL;
static struct saved_ports saved;
// The kernel appends a trailer the struct does not declare; receiving into
// a buffer eight times the message keeps MACH_RCV_LARGE from ever tripping.
static char mach_buffers[2][8 * sizeof(atl_mach_message_t)] __attribute__((aligned(8)));
static unsigned char handler_stacks[2][HANDLER_STACK_BYTES] PAGE_ALIGNED;
static pthread_t handler_threads[2];
static mach_port_t handler_ports[2];
static uint64_t handler_ids[2];
static volatile int secondary_parked;

// --- output: a small buffer over write() -------------------------------------------

static int out_fd = -1;
static char out_buf[4096];
static size_t out_len;

static void out_flush(void) {
    size_t done = 0;

    while (out_fd >= 0 && done < out_len) {
        ssize_t wrote = write(out_fd, out_buf + done, out_len - done);

        if (wrote < 0) {
            if (errno == EINTR) continue;
            break;
        }

        done += (size_t) wrote;
    }

    out_len = 0;
}

static void out_char(char c) {
    if (out_len == sizeof(out_buf)) out_flush();
    out_buf[out_len++] = c;
}

static void out_str(const char *text) {
    while (*text) out_char(*text++);
}

// Newlines end a line of the report; a message may not carry them.
static void out_text(const char *text, size_t limit) {
    for (size_t i = 0; i < limit && text[i]; i++) out_char(text[i] == '\n' || text[i] == '\r' ? ' ' : text[i]);
}

static void out_hex(uint64_t value) {
    char digits[16];
    int count = 0;

    do {
        digits[count++] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    } while (value);

    while (count) out_char(digits[--count]);
}

static void out_dec(int64_t value) {
    char digits[24];
    int count = 0;
    uint64_t rest = value < 0 ? (uint64_t) (-(value + 1)) + 1 : (uint64_t) value;

    if (value < 0) out_char('-');

    do {
        digits[count++] = (char) ('0' + rest % 10);
        rest /= 10;
    } while (rest);

    while (count) out_char(digits[--count]);
}

static void out_uuid(const uint8_t *uuid) {
    for (int i = 0; i < 16; i++) {
        out_char("0123456789abcdef"[uuid[i] >> 4]);
        out_char("0123456789abcdef"[uuid[i] & 0xf]);
    }
}

// --- safe memory ---------------------------------------------------------------------

// A read that cannot fault: the kernel copies, or says no.
static int safe_read(uintptr_t address, void *into, size_t size) {
    vm_size_t got = 0;

    return vm_read_overwrite(mach_task_self(), (vm_address_t) address, size, (vm_address_t) into, &got) == KERN_SUCCESS
        && got == size;
}

static int safe_read_word(uintptr_t address, uintptr_t *word) {
    return safe_read(address, word, sizeof(*word));
}

static uintptr_t strip_pointer_auth(uintptr_t address) {
#if defined(__arm64__)
    // A signed return address carries its signature above the user range.
    return address & ((UINT64_C(1) << 48) - 1);
#else
    return address;
#endif
}

// --- the image cache -------------------------------------------------------------------

static const struct image *image_of(uintptr_t address) {
    int count = image_count;

    for (int i = 0; i < count; i++) {
        if (address >= images[i].load && address < images[i].load + images[i].size) return &images[i];
    }

    return NULL;
}

// Runs at install for every image already loaded, and from dyld's own
// callback for every later one; both outside any crash. dladdr and
// getsectiondata are fine here and never called from a handler.
static void remember_image(const struct mach_header *header, intptr_t slide) {
    (void) slide;

    if (header == NULL || header->magic != MH_MAGIC_64 || image_count >= MAX_IMAGES) return;

    const struct mach_header_64 *mh = (const struct mach_header_64 *) header;
    struct image entry;
    memset(&entry, 0, sizeof(entry));
    entry.load = (uintptr_t) mh;

    const uint8_t *cursor = (const uint8_t *) mh + sizeof(*mh);

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *command = (const struct load_command *) cursor;

        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *) command;

            if (strcmp(segment->segname, SEG_TEXT) == 0) entry.size = (uintptr_t) segment->vmsize;
        } else if (command->cmd == LC_UUID) {
            memcpy(entry.uuid, ((const struct uuid_command *) command)->uuid, sizeof(entry.uuid));
            entry.has_uuid = 1;
        }

        cursor += command->cmdsize;
    }

    if (entry.size == 0) return;

    Dl_info info;

    if (dladdr((const void *) mh, &info) != 0 && info.dli_fname != NULL) {
        strncpy(entry.path, info.dli_fname, sizeof(entry.path) - 1);
    }

    unsigned long size = 0;
    uint8_t *section = getsectiondata(mh, "__DATA", "__crash_info", &size);

    if (section != NULL && size >= 64) entry.crash_info = (uintptr_t) section;

    for (int i = 0; i < image_count; i++) {
        if (images[i].load == entry.load) return;
    }

    images[image_count] = entry;
    // Count last: a reader that sees the count sees a whole entry.
    __sync_synchronize();
    image_count++;
}

static void on_image_added(const struct mach_header *header, intptr_t slide) {
    remember_image(header, slide);
}

static void cache_images(void) {
    uint32_t count = _dyld_image_count();

    for (uint32_t i = 0; i < count; i++) {
        remember_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }

    // Replays every loaded image, then fires for later loads.
    _dyld_register_func_for_add_image(on_image_added);
}

// frame <pc> <lookup address relative to the image|-> <uuid|-> <path|->
//
// `lookup` is the address the symbolicator should resolve: the pc itself for
// the faulting frame, one byte inside the call for a return address (the
// return lands on the next instruction, which may already be the next line).
static void out_frame(uintptr_t pc, int is_return) {
    const struct image *image = image_of(pc);
    uintptr_t lookup = is_return ? pc - 1 : pc;

    out_str("frame ");
    out_hex(pc);
    out_char(' ');

    if (image != NULL) {
        out_hex(lookup - image->load);
        out_char(' ');

        if (image->has_uuid) out_uuid(image->uuid); else out_char('-');

        out_char(' ');
        out_str(image->path[0] ? image->path : "-");
    } else {
        out_str("- - -");
    }

    out_char('\n');
}

// --- thread names --------------------------------------------------------------------------

static uint64_t thread_id_of(thread_t thread) {
    thread_identifier_info_data_t info;
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;

    if (thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t) &info, &count) != KERN_SUCCESS) return 0;

    return info.thread_id;
}

static const char *cached_thread_name(uint64_t id) {
    int count = thread_name_count;

    for (int i = 0; i < count; i++) {
        if (thread_names[i].id == id) return thread_names[i].name;
    }

    return NULL;
}

void atl_crash_refresh_thread_names(void) {
    thread_act_array_t list = NULL;
    mach_msg_type_number_t count = 0;

    if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) return;

    struct thread_name fresh[MAX_THREAD_NAMES];
    int found = 0;

    for (mach_msg_type_number_t i = 0; i < count && found < MAX_THREAD_NAMES; i++) {
        uint64_t id = thread_id_of(list[i]);
        pthread_t owner = pthread_from_mach_thread_np(list[i]);
        char name[64] = {0};

        if (id != 0 && owner != NULL && pthread_getname_np(owner, name, sizeof(name)) == 0 && name[0]) {
            fresh[found].id = id;
            memcpy(fresh[found].name, name, sizeof(name));
            found++;
        }

        mach_port_deallocate(mach_task_self(), list[i]);
    }

    vm_deallocate(mach_task_self(), (vm_address_t) list, count * sizeof(thread_t));

    // Whole entries first, the count last, so a crash mid-refresh reads a
    // consistent prefix.
    thread_name_count = 0;
    __sync_synchronize();
    memcpy(thread_names, fresh, sizeof(struct thread_name) * (size_t) found);
    __sync_synchronize();
    thread_name_count = found;
}

static void out_thread_name(thread_t thread, uint64_t id) {
    const char *cached = id == main_thread_id ? "main" : cached_thread_name(id);

    if (cached != NULL) {
        out_str(cached);

        return;
    }

    // Not seen by the watchdog yet: the pthread's own copy, read the way
    // KSCrash reads it. Only ever on a miss.
    pthread_t owner = pthread_from_mach_thread_np(thread);
    char name[64] = {0};

    if (owner != NULL && pthread_getname_np(owner, name, sizeof(name)) == 0 && name[0]) {
        out_text(name, sizeof(name));
    } else {
        out_str("thread-");
        out_dec((int64_t) id);
    }
}

// --- registers and the walk ------------------------------------------------------------------

struct registers {
    uintptr_t pc;
    uintptr_t sp;
    uintptr_t fp;
    uintptr_t lr;
};

#if defined(__arm64__)
typedef arm_thread_state64_t atl_thread_state_t;
#define ATL_THREAD_STATE ARM_THREAD_STATE64
#define ATL_THREAD_STATE_COUNT ARM_THREAD_STATE64_COUNT

static void registers_of_state(const atl_thread_state_t *state, struct registers *regs) {
    regs->pc = strip_pointer_auth((uintptr_t) arm_thread_state64_get_pc(*state));
    regs->sp = (uintptr_t) arm_thread_state64_get_sp(*state);
    regs->fp = (uintptr_t) arm_thread_state64_get_fp(*state);
    regs->lr = strip_pointer_auth((uintptr_t) arm_thread_state64_get_lr(*state));
}

static void out_registers_of_state(const atl_thread_state_t *state) {
    out_str("registers");

    for (int i = 0; i < 29; i++) {
        out_str(" x");
        out_dec(i);
        out_str("=0x");
        out_hex(state->__x[i]);
    }

    out_str(" fp=0x");
    out_hex((uint64_t) arm_thread_state64_get_fp(*state));
    out_str(" lr=0x");
    out_hex(strip_pointer_auth((uintptr_t) arm_thread_state64_get_lr(*state)));
    out_str(" sp=0x");
    out_hex((uint64_t) arm_thread_state64_get_sp(*state));
    out_str(" pc=0x");
    out_hex(strip_pointer_auth((uintptr_t) arm_thread_state64_get_pc(*state)));
    out_str(" cpsr=0x");
    out_hex(state->__cpsr);
    out_char('\n');
}

static void state_of_context(const ucontext_t *context, atl_thread_state_t *state) {
    memcpy(state, &context->uc_mcontext->__ss, sizeof(*state));
}
#elif defined(__x86_64__)
typedef x86_thread_state64_t atl_thread_state_t;
#define ATL_THREAD_STATE x86_THREAD_STATE64
#define ATL_THREAD_STATE_COUNT x86_THREAD_STATE64_COUNT

static void registers_of_state(const atl_thread_state_t *state, struct registers *regs) {
    regs->pc = (uintptr_t) state->__rip;
    regs->sp = (uintptr_t) state->__rsp;
    regs->fp = (uintptr_t) state->__rbp;
    regs->lr = 0;
}

static void out_registers_of_state(const atl_thread_state_t *state) {
    out_str("registers rax=0x"); out_hex(state->__rax);
    out_str(" rbx=0x"); out_hex(state->__rbx);
    out_str(" rcx=0x"); out_hex(state->__rcx);
    out_str(" rdx=0x"); out_hex(state->__rdx);
    out_str(" rdi=0x"); out_hex(state->__rdi);
    out_str(" rsi=0x"); out_hex(state->__rsi);
    out_str(" rbp=0x"); out_hex(state->__rbp);
    out_str(" rsp=0x"); out_hex(state->__rsp);
    out_str(" r8=0x"); out_hex(state->__r8);
    out_str(" r9=0x"); out_hex(state->__r9);
    out_str(" r10=0x"); out_hex(state->__r10);
    out_str(" r11=0x"); out_hex(state->__r11);
    out_str(" r12=0x"); out_hex(state->__r12);
    out_str(" r13=0x"); out_hex(state->__r13);
    out_str(" r14=0x"); out_hex(state->__r14);
    out_str(" r15=0x"); out_hex(state->__r15);
    out_str(" rip=0x"); out_hex(state->__rip);
    out_str(" rflags=0x"); out_hex(state->__rflags);
    out_char('\n');
}

static void state_of_context(const ucontext_t *context, atl_thread_state_t *state) {
    memcpy(state, &context->uc_mcontext->__ss, sizeof(*state));
}
#else
#error "atl_crash_capture: unsupported architecture"
#endif

static int state_of_thread(thread_t thread, atl_thread_state_t *state) {
    mach_msg_type_number_t count = ATL_THREAD_STATE_COUNT;

    return thread_get_state(thread, ATL_THREAD_STATE, (thread_state_t) state, &count) == KERN_SUCCESS;
}

// Frame pointers are the ABI on every Apple 64-bit target, so the chain is
// the truth; every read goes through the kernel, so a smashed stack ends the
// walk instead of faulting inside the handler.
static int collect_frames(const struct registers *regs, uintptr_t *out, int max) {
    int count = 0;
    uintptr_t fp = regs->fp;
    uintptr_t first_return = 0;

    if (max == 0) return 0;

    out[count++] = regs->pc;

    if (fp != 0 && (fp & (sizeof(uintptr_t) - 1)) == 0) safe_read_word(fp + sizeof(uintptr_t), &first_return);

    // A leaf that has not pushed its link register yet: the caller is only
    // in lr. When lr already sits at fp+8, it is the same frame — once.
    if (regs->lr != 0 && strip_pointer_auth(first_return) != regs->lr && count < max) out[count++] = regs->lr;

    while (count < max && fp != 0 && (fp & (sizeof(uintptr_t) - 1)) == 0) {
        uintptr_t next = 0;
        uintptr_t ret = 0;

        if (!safe_read_word(fp, &next) || !safe_read_word(fp + sizeof(uintptr_t), &ret)) break;

        ret = strip_pointer_auth(ret);

        if (ret == 0 || image_of(ret) == NULL) break;

        out[count++] = ret;

        // The chain only ever climbs; anything else is a corrupt record.
        if (next <= fp) break;

        fp = next;
    }

    return count;
}

static void out_frames(const uintptr_t *frames, int count) {
    for (int i = 0; i < count; i++) out_frame(frames[i], i > 0);
}

static void out_walk(const struct registers *regs) {
    uintptr_t frames[MAX_FRAMES];
    int count = collect_frames(regs, frames, MAX_FRAMES);

    out_frames(frames, count);
}

// --- the other threads -------------------------------------------------------------------------

struct thread_list {
    thread_act_array_t threads;
    mach_msg_type_number_t count;
};

static int is_reserved(uint64_t id, uint64_t self_id, uint64_t crashed_id) {
    return id == self_id || id == crashed_id || id == handler_ids[0] || id == handler_ids[1];
}

// Stops every thread but the reserved ones — this one, the crashed one (the
// kernel holds it already on the mach path), and the two handler threads.
static void suspend_others(struct thread_list *list, uint64_t self_id, uint64_t crashed_id) {
    list->threads = NULL;
    list->count = 0;

    if (task_threads(mach_task_self(), &list->threads, &list->count) != KERN_SUCCESS) {
        list->count = 0;

        return;
    }

    for (mach_msg_type_number_t i = 0; i < list->count; i++) {
        if (!is_reserved(thread_id_of(list->threads[i]), self_id, crashed_id)) thread_suspend(list->threads[i]);
    }
}

static void resume_others(struct thread_list *list, uint64_t self_id, uint64_t crashed_id) {
    for (mach_msg_type_number_t i = 0; i < list->count; i++) {
        if (!is_reserved(thread_id_of(list->threads[i]), self_id, crashed_id)) thread_resume(list->threads[i]);
    }

    // Without these two, every capture leaks a port per thread.
    for (mach_msg_type_number_t i = 0; i < list->count; i++) mach_port_deallocate(mach_task_self(), list->threads[i]);

    if (list->threads != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t) list->threads, list->count * sizeof(thread_t));
    }
}

// thread <index> <id> <crashed 0|1> <name>, then its frames.
static void out_other_threads(const struct thread_list *list, uint64_t self_id, uint64_t crashed_id, int from_index) {
    int index = from_index;

    for (mach_msg_type_number_t i = 0; i < list->count; i++) {
        uint64_t id = thread_id_of(list->threads[i]);

        if (id == 0 || is_reserved(id, self_id, crashed_id)) continue;

        atl_thread_state_t state;

        if (!state_of_thread(list->threads[i], &state)) continue;

        struct registers regs;
        registers_of_state(&state, &regs);

        out_str("thread ");
        out_dec(index++);
        out_char(' ');
        out_dec((int64_t) id);
        out_str(" 0 ");
        out_thread_name(list->threads[i], id);
        out_char('\n');
        out_walk(&regs);
    }
}

// --- __crash_info: what the runtimes say about an abort ----------------------------------

// libswiftCore holds the fatalError text here, libobjc the uncaught-exception
// banner, libsystem_c the abort() reason. Read only after the fact, through
// the kernel, from the section addresses cached at load.
static void out_crash_info(void) {
    int count = image_count;

    for (int i = 0; i < count; i++) {
        if (images[i].crash_info == 0) continue;

        uint64_t record[8];

        if (!safe_read(images[i].crash_info, record, sizeof(record))) continue;

        uint64_t version = record[0];

        if (version < 4 || version > 7) continue;

        // message, then message2; each a pointer to a C string, or null.
        const uint64_t pointers[2] = {record[1], record[4]};

        for (int p = 0; p < 2; p++) {
            if (pointers[p] == 0) continue;

            // Read in small chunks through the kernel; the first NUL ends it.
            char text[MAX_TEXT];
            size_t length = 0;
            int ended = 0;

            while (!ended && length + 64 < sizeof(text)) {
                if (!safe_read((uintptr_t) pointers[p] + length, text + length, 64)) break;

                for (size_t k = 0; k < 64; k++) {
                    if (text[length + k] == 0) {
                        length += k;
                        ended = 1;
                        break;
                    }
                }

                if (!ended) length += 64;
            }

            text[length] = 0;

            if (length == 0) continue;

            out_str("crashinfo ");
            out_text(text, length);
            out_char('\n');
        }
    }
}

// --- the report ----------------------------------------------------------------------------------

static int open_report(void) {
    out_fd = open(report_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);

    return out_fd >= 0;
}

static void close_report(void) {
    out_str("end\n");
    out_flush();
    close(out_fd);
    out_fd = -1;
}

static void out_head(void) {
    struct timespec now = {0, 0};
    clock_gettime(CLOCK_REALTIME, &now);

    out_str("atlas-apple-crash 1\ntime ");
    out_dec((int64_t) now.tv_sec);
    out_str("\npid ");
    out_dec(getpid());
    out_char('\n');
}

static uint64_t self_thread_id(void) {
    return thread_id_of(pthread_mach_thread_np(pthread_self()));
}

// A fault a few pages below the stack pointer is the guard page: the stack
// overflowed. The kernel reports it as a protection failure, which reads as
// a stray write until this says otherwise.
static int looks_like_stack_overflow(uintptr_t fault, uintptr_t sp) {
    return fault != 0 && sp != 0 && fault <= sp + 4096 && fault + 64 * 1024 > sp;
}

// --- the mach exception server ----------------------------------------------------------------

static void restore_ports(void) {
    task_t task = mach_task_self();

    task_set_exception_ports(task, MACH_MASK, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);

    for (mach_msg_type_number_t i = 0; i < saved.count; i++) {
        if (saved.ports[i] != MACH_PORT_NULL) {
            task_set_exception_ports(task, saved.masks[i], saved.ports[i], saved.behaviors[i], saved.flavors[i]);
        }
    }
}

// Whether a handler that was there before us takes this exception type: if
// so the thread may re-execute and re-fault into it, and the OS report it
// writes survives. Otherwise the kernel escalates to the host, which is
// also where the OS report comes from.
static int previous_port_takes(exception_type_t exception) {
    exception_mask_t bit = (exception_mask_t) (1u << exception);

    for (mach_msg_type_number_t i = 0; i < saved.count; i++) {
        if ((saved.masks[i] & bit) && saved.ports[i] != MACH_PORT_NULL) return 1;
    }

    return 0;
}

static void reply_to(const atl_mach_message_t *message, kern_return_t verdict) {
    atl_mach_reply_t reply;
    memset(&reply, 0, sizeof(reply));
    reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(message->header.msgh_bits), 0);
    reply.header.msgh_size = sizeof(reply);
    reply.header.msgh_remote_port = message->header.msgh_remote_port;
    reply.header.msgh_local_port = MACH_PORT_NULL;
    // The convention: the request id plus 100.
    reply.header.msgh_id = message->header.msgh_id + 100;
    reply.NDR = NDR_record;
    reply.return_code = verdict;

    // No reply at all leaves the thread hung in the kernel — and silences the
    // OS crash log and every other reporter behind us.
    mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
}

static const char *mach_exception_name(exception_type_t exception) {
    switch (exception) {
        case EXC_BAD_ACCESS: return "EXC_BAD_ACCESS";
        case EXC_BAD_INSTRUCTION: return "EXC_BAD_INSTRUCTION";
        case EXC_ARITHMETIC: return "EXC_ARITHMETIC";
        case EXC_EMULATION: return "EXC_EMULATION";
        case EXC_SOFTWARE: return "EXC_SOFTWARE";
        case EXC_BREAKPOINT: return "EXC_BREAKPOINT";
        case EXC_SYSCALL: return "EXC_SYSCALL";
        case EXC_MACH_SYSCALL: return "EXC_MACH_SYSCALL";
        case EXC_RPC_ALERT: return "EXC_RPC_ALERT";
        case EXC_CRASH: return "EXC_CRASH";
        case EXC_RESOURCE: return "EXC_RESOURCE";
        case EXC_GUARD: return "EXC_GUARD";
        default: return "EXC_UNKNOWN";
    }
}

static void write_mach_report(const atl_mach_message_t *message, int which) {
    thread_t faulted = message->thread.name;
    uint64_t crashed_id = thread_id_of(faulted);
    uint64_t self_id = handler_ids[which];
    struct thread_list others;
    atl_thread_state_t state;
    struct registers regs;
    memset(&regs, 0, sizeof(regs));

    int have_state = state_of_thread(faulted, &state);

    if (have_state) registers_of_state(&state, &regs);

    suspend_others(&others, self_id, crashed_id);

    if (open_report()) {
        uintptr_t fault = message->code_count > 1 ? (uintptr_t) message->code[1] : 0;

        out_head();
        out_str("kind mach\nmach ");
        out_str(mach_exception_name(message->exception));
        out_char(' ');
        out_dec((int64_t) message->exception);
        out_char(' ');
        out_dec((int64_t) (message->code_count > 0 ? message->code[0] : 0));
        out_char(' ');
        out_hex((uint64_t) fault);
        out_char('\n');

        if (message->exception == EXC_BAD_ACCESS && looks_like_stack_overflow(fault, regs.sp)) {
            out_str("stackoverflow 1\n");
        }

        out_crash_info();
        out_str("thread 0 ");
        out_dec((int64_t) crashed_id);
        out_str(" 1 ");
        out_thread_name(faulted, crashed_id);
        out_char('\n');

        if (have_state) {
            out_registers_of_state(&state);
            out_walk(&regs);
        }

        out_flush();
        out_other_threads(&others, self_id, crashed_id, 1);
        close_report();
    }

    resume_others(&others, self_id, crashed_id);
}

static void on_mach_message(atl_mach_message_t *message, int which) {
    // A child inherits the task's exception ports; its faults are its own.
    if (message->task.name != mach_task_self()) {
        reply_to(message, KERN_FAILURE);

        return;
    }

    // A signal in mach clothing, delivered only to a traced task; the
    // signal handler is the one that reports those.
    if (message->exception == EXC_SOFTWARE && message->code_count > 0 && message->code[0] == EXC_SOFT_SIGNAL) {
        restore_ports();
        reply_to(message, KERN_FAILURE);

        return;
    }

    if (handling) {
        // The handler itself crashed, or another thread did behind it. What
        // is on disk stays; the OS gets the rest.
        if (out_fd >= 0) {
            out_str("\nrecrash\n");
            close_report();
        }

        restore_ports();
        reply_to(message, KERN_FAILURE);

        return;
    }

    handling = 1;
    crashed = 1;

    // The spare thread wakes so a crash inside this handler still has a
    // receiver — the one way to see a crash of the crash handler. It finds
    // `handling` set, notes the recrash, and hands the ports back.
    if (which == 0 && secondary_parked) {
        secondary_parked = 0;
        thread_resume(handler_ports[1]);
    } else {
        restore_ports();
    }

    write_mach_report(message, which);

    // Whoever held the ports before us holds them again from here: the
    // re-executed fault goes to them, or up to the host, never back to us.
    restore_ports();
    reply_to(message, previous_port_takes(message->exception) ? KERN_SUCCESS : KERN_FAILURE);
}

static void *mach_server(void *argument) {
    int which = (int) (intptr_t) argument;
    handler_ports[which] = mach_thread_self();
    handler_ids[which] = thread_id_of(handler_ports[which]);
    pthread_setname_np(which == 0 ? "atlas-crash-mach" : "atlas-crash-mach-spare");

    if (which == 1) {
        // Parked until the primary is busy with a crash.
        secondary_parked = 1;
        thread_suspend(handler_ports[1]);
    }

    for (;;) {
        atl_mach_message_t *message = (atl_mach_message_t *) mach_buffers[which];
        mach_msg_return_t received = mach_msg(&message->header, MACH_RCV_MSG | MACH_RCV_LARGE, 0,
                                              sizeof(mach_buffers[which]), exception_port,
                                              MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

        if (received != MACH_MSG_SUCCESS) {
            if (received == MACH_RCV_PORT_DIED || received == MACH_RCV_INVALID_NAME) break;
            continue;
        }

        on_mach_message(message, which);
    }

    return NULL;
}

static int install_mach(void) {
    task_t task = mach_task_self();

    if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &exception_port) != KERN_SUCCESS) return 0;

    if (mach_port_insert_right(task, exception_port, exception_port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_deallocate(task, exception_port);
        exception_port = MACH_PORT_NULL;

        return 0;
    }

    // Saved before we take them: the only way another reporter keeps
    // working beside us.
    saved.count = EXC_TYPES_COUNT;

    if (task_get_exception_ports(task, MACH_MASK, saved.masks, &saved.count, saved.ports, saved.behaviors,
                                 saved.flavors) != KERN_SUCCESS) {
        saved.count = 0;
    }

    // Two threads on their own preallocated stacks; the spare parks itself.
    for (int which = 0; which < 2; which++) {
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setstack(&attributes, handler_stacks[which], sizeof(handler_stacks[which]));
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);

        int failed = pthread_create(&handler_threads[which], &attributes, mach_server, (void *) (intptr_t) which);
        pthread_attr_destroy(&attributes);

        if (failed != 0) {
            mach_port_deallocate(task, exception_port);
            exception_port = MACH_PORT_NULL;

            return 0;
        }
    }

    // The spare must be parked before the ports point at us, or its wake-up
    // could race a crash.
    for (int spins = 0; spins < 2000 && !secondary_parked; spins++) usleep(100);

    if (task_set_exception_ports(task, MACH_MASK, exception_port, (exception_behavior_t) (EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                 THREAD_STATE_NONE) != KERN_SUCCESS) {
        return 0;
    }

    return 1;
}

// --- the signal handlers ----------------------------------------------------------------------------

static void hand_over(int index, int signo, siginfo_t *info) {
    // Whoever was here first gets the signal next. Their handler, or the
    // default that ends the process and lets the OS write its own log.
    if (signal_installed[index]) {
        sigaction(signo, &previous_actions[index], NULL);
    } else {
        signal(signo, SIG_DFL);
    }

    // Our handler is gone from the table now, so unmasking cannot loop back.
    sigset_t unmask;
    sigemptyset(&unmask);
    sigaddset(&unmask, signo);
    pthread_sigmask(SIG_UNBLOCK, &unmask, NULL);

    // A fault re-executes on return and lands in the restored handler; a
    // signal that was sent (abort, kill, raise) does not repeat by itself.
    if (signo == SIGABRT || signo == SIGPIPE || info == NULL || info->si_code <= 0) {
        raise(signo);
    }
}

static const char *signal_name(int signo) {
    switch (signo) {
        case SIGABRT: return "SIGABRT";
        case SIGBUS: return "SIGBUS";
        case SIGFPE: return "SIGFPE";
        case SIGILL: return "SIGILL";
        case SIGPIPE: return "SIGPIPE";
        case SIGSEGV: return "SIGSEGV";
        case SIGSYS: return "SIGSYS";
        case SIGTRAP: return "SIGTRAP";
        default: return "SIGNAL";
    }
}

static void on_signal(int signo, siginfo_t *info, void *raw_context) {
    int saved_errno = errno;
    int index = 0;

    while (index < SIGNAL_COUNT - 1 && SIGNALS[index] != signo) index++;

    // The mach server already wrote this crash (a fault becomes a signal
    // afterwards), or a second thread is dying behind the first: step aside.
    if (handling) {
        hand_over(index, signo, info);
        errno = saved_errno;

        return;
    }

    handling = 1;
    crashed = 1;

    atl_thread_state_t state;
    struct registers regs;
    memset(&regs, 0, sizeof(regs));
    int have_state = raw_context != NULL;

    if (have_state) {
        state_of_context((const ucontext_t *) raw_context, &state);
        registers_of_state(&state, &regs);
    }

    uint64_t self_id = self_thread_id();
    struct thread_list others;
    suspend_others(&others, self_id, 0);

    if (open_report()) {
        uintptr_t fault = info != NULL ? (uintptr_t) info->si_addr : 0;

        out_head();
        out_str("kind signal\nsignal ");
        out_str(signal_name(signo));
        out_char(' ');
        out_dec(signo);
        out_char(' ');
        out_dec(info != NULL ? info->si_code : 0);
        out_char(' ');
        out_hex((uint64_t) fault);
        out_char('\n');

        if ((signo == SIGSEGV || signo == SIGBUS) && looks_like_stack_overflow(fault, regs.sp)) {
            out_str("stackoverflow 1\n");
        }

        out_crash_info();
        out_str("thread 0 ");
        out_dec((int64_t) self_id);
        out_str(" 1 ");
        out_thread_name(pthread_mach_thread_np(pthread_self()), self_id);
        out_char('\n');

        if (have_state) {
            out_registers_of_state(&state);
            out_walk(&regs);
        }

        out_flush();
        out_other_threads(&others, self_id, 0, 1);
        close_report();
    }

    resume_others(&others, self_id, 0);
    hand_over(index, signo, info);
    errno = saved_errno;
}

static int install_signals(void) {
    int set = 0;

    // The alternate stack first: a stack overflow has nowhere else to run.
    stack_t current;

    if (sigaltstack(NULL, &current) == 0 && (current.ss_flags & SS_DISABLE)) {
        stack_t stack;
        memset(&stack, 0, sizeof(stack));
        stack.ss_sp = alt_stack;
        stack.ss_size = sizeof(alt_stack);
        sigaltstack(&stack, NULL);
    }

    for (int i = 0; i < SIGNAL_COUNT; i++) {
        struct sigaction action;
        struct sigaction existing;

        // An ignored signal stays ignored: an app that ignores SIGPIPE has
        // not asked for SIGPIPE to become a crash.
        if (signal_installed[i] || sigaction(SIGNALS[i], NULL, &existing) != 0 || existing.sa_handler == SIG_IGN) continue;

        memset(&action, 0, sizeof(action));
        sigemptyset(&action.sa_mask);
        action.sa_sigaction = on_signal;
        // Not SA_RESETHAND: it misbehaves on Darwin, and hand_over restores
        // the previous action itself.
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;

        if (sigaction(SIGNALS[i], &action, &previous_actions[i]) == 0) {
            signal_installed[i] = 1;
            set++;
        }
    }

    return set > 0;
}

// --- the NSException path ----------------------------------------------------------------------------

void atl_crash_write_exception(const char *name, const char *reason, const uintptr_t *addresses, int count) {
    if (handling) return;

    handling = 1;
    crashed = 1;

    uint64_t self_id = self_thread_id();
    struct thread_list others;
    suspend_others(&others, self_id, 0);

    if (open_report()) {
        out_head();
        out_str("kind exception\nexception ");
        out_text(name != NULL ? name : "NSException", MAX_TEXT);
        out_str("\nreason ");
        out_text(reason != NULL ? reason : "", 4 * MAX_TEXT);
        out_char('\n');
        out_crash_info();
        out_str("thread 0 ");
        out_dec((int64_t) self_id);
        out_str(" 1 ");
        out_thread_name(pthread_mach_thread_np(pthread_self()), self_id);
        out_char('\n');

        // The runtime's own addresses are where the throw happened; the
        // first is inside the raise, the rest are the app's frames.
        for (int i = 0; i < count && i < MAX_FRAMES; i++) out_frame(strip_pointer_auth(addresses[i]), 1);

        out_flush();
        out_other_threads(&others, self_id, 0, 1);
        close_report();
    }

    resume_others(&others, self_id, 0);
}

// --- outside a crash: the watchdog's helpers ---------------------------------------------------------

int atl_crash_locate(uintptr_t address, atl_crash_frame_t *out) {
    const struct image *image = image_of(address);
    memset(out, 0, sizeof(*out));
    out->address = address;

    if (image == NULL) return 0;

    out->relative = address - image->load;

    if (image->has_uuid) {
        for (int i = 0; i < 16; i++) {
            out->uuid[i * 2] = "0123456789abcdef"[image->uuid[i] >> 4];
            out->uuid[i * 2 + 1] = "0123456789abcdef"[image->uuid[i] & 0xf];
        }
    }

    strncpy(out->path, image->path, sizeof(out->path) - 1);

    return 1;
}

int atl_crash_snapshot_main(uintptr_t *addresses, int max) {
    if (main_thread_port == MACH_PORT_NULL || max <= 0) return 0;

    // Never from the main thread itself: suspending self is forever.
    if (self_thread_id() == main_thread_id) return 0;

    if (thread_suspend(main_thread_port) != KERN_SUCCESS) return 0;

    atl_thread_state_t state;
    int count = 0;

    if (state_of_thread(main_thread_port, &state)) {
        struct registers regs;
        registers_of_state(&state, &regs);
        count = collect_frames(&regs, addresses, max);
    }

    thread_resume(main_thread_port);

    return count;
}

// --- install ------------------------------------------------------------------------------------------------

int atl_crash_debugger_attached(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));

    if (sysctl(name, 4, &info, &size, NULL, 0) != 0) return 0;

    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int atl_crash_did_crash(void) {
    return crashed != 0;
}

unsigned atl_crash_install(const char *path, unsigned wanted) {
    size_t length = path ? strlen(path) : 0;

    if (installed_kinds != 0) return installed_kinds;
    if (length == 0 || length >= sizeof(report_path)) return 0;
    if (atl_crash_debugger_attached()) return 0;

    memcpy(report_path, path, length + 1);

    main_thread_port = pthread_mach_thread_np(pthread_self());
    main_thread_id = thread_id_of(main_thread_port);
    cache_images();
    atl_crash_refresh_thread_names();

    unsigned got = 0;

    if ((wanted & ATL_CRASH_MACH) && install_mach()) got |= ATL_CRASH_MACH;
    if ((wanted & ATL_CRASH_SIGNALS) && install_signals()) got |= ATL_CRASH_SIGNALS;

    installed_kinds = got;

    return got;
}

#endif
