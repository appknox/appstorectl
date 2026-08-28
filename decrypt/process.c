#include "internal.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern int ptrace(int request, pid_t pid, void *address, int data);
extern int proc_listallpids(void *buffer, int buffer_size);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffer_size);

enum {
    PT_TRACE_ME = 0,
    PT_KILL = 8,
    PT_CONTINUE = 7,
};

uint32_t decrypt_running_os_version(void) {
    char value[64];
    size_t size = sizeof(value);
    if (sysctlbyname("kern.osproductversion", value, &size, NULL, 0) != 0)
        return 0;
    unsigned major = 0, minor = 0, patch = 0;
    if (sscanf(value, "%u.%u.%u", &major, &minor, &patch) < 1)
        return 0;
    // Same xxxx.yy.zz packing the load commands use, so the two compare directly.
    return (major & 0xffff) << 16 | (minor & 0xff) << 8 | (patch & 0xff);
}

const char *decrypt_format_os_version(uint32_t version, char *buffer, size_t size) {
    unsigned patch = version & 0xff;
    if (patch)
        snprintf(buffer, size, "%u.%u.%u", version >> 16, version >> 8 & 0xff, patch);
    else
        snprintf(buffer, size, "%u.%u", version >> 16, version >> 8 & 0xff);
    return buffer;
}

typedef void *cf_string_t;
typedef cf_string_t (*cf_string_create_fn)(void *, const char *, unsigned);
typedef void (*cf_release_fn)(const void *);
typedef int (*sbs_launch_fn)(cf_string_t, unsigned char);

static bool paths_equal(const char *left, const char *right) {
    if (strcmp(left, right) == 0)
        return true;
    static const char prefix[] = "/private";
    size_t prefix_size = sizeof(prefix) - 1;
    if (strncmp(left, prefix, prefix_size) == 0 &&
        strcmp(left + prefix_size, right) == 0)
        return true;
    return strncmp(right, prefix, prefix_size) == 0 &&
           strcmp(right + prefix_size, left) == 0;
}

static pid_t find_pid(const char *executable_path) {
    for (unsigned attempt = 0; attempt < 40; attempt++) {
        int count = proc_listallpids(NULL, 0);
        if (count > 0) {
            size_t bytes = (size_t)count * sizeof(pid_t);
            pid_t *pids = malloc(bytes);
            if (!pids)
                return 0;
            int received = proc_listallpids(pids, (int)bytes);
            for (int index = 0; index < received; index++) {
                char path[4096];
                if (pids[index] > 0 &&
                    proc_pidpath(pids[index], path, sizeof(path)) > 0 &&
                    paths_equal(path, executable_path)) {
                    pid_t result = pids[index];
                    free(pids);
                    return result;
                }
            }
            free(pids);
        }
        usleep(50000);
    }
    return 0;
}

static decrypt_status_t open_ptrace_once(decrypt_process_t *process,
                                         const char *executable_path);

// Apple ships some appex binaries without the execute bit — every iOS 18 Instagram extension on the
// test device is mode 644. execve refuses those with EACCES, the child reaches _exit(127), and the
// result is indistinguishable from a binary the kernel rejected for any other reason. Retrying does
// not grow an execute bit, so this has to be fixed rather than waited out.
//
// The mode is put back in decrypt_process_close. The implementation this replaced chmod'd and left
// it, which silently turns every later run into a different experiment from the first.
static void ensure_executable(decrypt_process_t *process,
                              const char *executable_path,
                              decrypt_logger_t *logger) {
    struct stat st;
    if (stat(executable_path, &st) != 0)
        return;
    mode_t wanted = st.st_mode | S_IXUSR | S_IXGRP | S_IXOTH;
    if (wanted == st.st_mode || chmod(executable_path, wanted) != 0)
        return;

    process->original_mode = st.st_mode;
    process->mode_restore_pending =
        snprintf(process->original_mode_path, sizeof(process->original_mode_path),
                 "%s", executable_path) < (int)sizeof(process->original_mode_path);

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "path", executable_path);
    decrypt_attrs_int(&attrs, "was_mode", st.st_mode & 07777);
    decrypt_event(logger, DECRYPT_LOG_INFO, "spawn.chmod", &attrs,
                  "added +x to spawn %s (was mode %o), will restore",
                  executable_path, st.st_mode & 07777);
}

static void restore_mode(decrypt_process_t *process) {
    if (!process->mode_restore_pending)
        return;
    chmod(process->original_mode_path, process->original_mode);
    process->mode_restore_pending = false;
}

// execve into an app binary fails intermittently on this device, and a single attempt turns that
// into a permanent verdict about the image. It is not: the same extension that exits 127 on one
// run spawns on the next. Retry before concluding anything about the binary itself.
static decrypt_status_t open_ptrace(decrypt_process_t *process,
                                    const char *executable_path,
                                    decrypt_logger_t *logger) {
    ensure_executable(process, executable_path, logger);
    decrypt_status_t status = DECRYPT_PLATFORM_ERROR;
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        status = open_ptrace_once(process, executable_path);
        if (status == DECRYPT_OK)
            return status;
        decrypt_event_attrs_t attrs;
        decrypt_attrs_init(&attrs);
        decrypt_attrs_int(&attrs, "attempt", attempt + 1);
        decrypt_attrs_int(&attrs, "exec_status", process->exec_status);
        decrypt_event(logger, DECRYPT_LOG_DEBUG, "launch.ptrace_retry", &attrs,
                      "ptrace launch attempt %u failed", attempt + 1);
        usleep(300000);
    }
    return status;
}

// Every failure here used to be one indistinguishable DECRYPT_PLATFORM_ERROR, which is why a
// fallback to ptrace could never be explained after the fact. Each step now names itself.
static decrypt_status_t sbs_failed(decrypt_logger_t *logger, const char *step, long detail) {
    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "step", step);
    decrypt_attrs_int(&attrs, "detail", detail);
    decrypt_event(logger, DECRYPT_LOG_WARNING, "launch.sbs_failed", &attrs,
                  "SBS launch failed at %s (%ld), falling back to ptrace", step, detail);
    return DECRYPT_PLATFORM_ERROR;
}

static decrypt_status_t open_sbs(decrypt_process_t *process,
                                 const char *bundle_id,
                                 const char *executable_path,
                                 decrypt_logger_t *logger) {
    void *core_foundation = dlopen(
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    void *springboard = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_NOW);
    if (!core_foundation || !springboard)
        return sbs_failed(logger, "dlopen", 0);

    cf_string_create_fn create_string =
        (cf_string_create_fn)dlsym(core_foundation, "CFStringCreateWithCString");
    cf_release_fn release = (cf_release_fn)dlsym(core_foundation, "CFRelease");
    sbs_launch_fn launch =
        (sbs_launch_fn)dlsym(springboard, "SBSLaunchApplicationWithIdentifier");
    if (!create_string || !release || !launch)
        return sbs_failed(logger, "dlsym", 0);

    cf_string_t identifier = create_string(NULL, bundle_id, 0x08000100);
    if (!identifier)
        return sbs_failed(logger, "cfstring", 0);
    int launch_result = launch(identifier, 1);
    release(identifier);
    if (launch_result != 0)
        return sbs_failed(logger, "SBSLaunchApplicationWithIdentifier", launch_result);

    pid_t pid = find_pid(executable_path);
    if (pid <= 0)
        return sbs_failed(logger, "find_pid", 0);

    task_t task = MACH_PORT_NULL;
    kern_return_t got_task = task_for_pid(mach_task_self(), pid, &task);
    if (got_task != KERN_SUCCESS) {
        kill(pid, SIGKILL);
        return sbs_failed(logger, "task_for_pid", got_task);
    }
    // Let dyld finish before freezing the target. Dumping the main image works either way, but
    // enumerating or calling into the loader does not: a target suspended mid-bootstrap has an
    // incomplete image list and a libdyld that is not ready to be called.
    uint32_t settled = decrypt_runtime_wait_for_images(task, pid);
    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_int(&attrs, "pid", pid);
    decrypt_attrs_int(&attrs, "images", settled);
    decrypt_event(logger, DECRYPT_LOG_DEBUG, "launch.settled", &attrs,
                  "dyld settled at %u image(s)", settled);

    kern_return_t suspended = task_suspend(task);
    if (suspended != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        kill(pid, SIGKILL);
        return sbs_failed(logger, "task_suspend", suspended);
    }

    process->pid = pid;
    process->task = task;
    process->method = DECRYPT_LAUNCH_SBS;
    process->loader_ready = settled > 0;
    process->alive = true;
    return DECRYPT_OK;
}

static decrypt_status_t open_ptrace_once(decrypt_process_t *process,
                                         const char *executable_path) {
    process->exec_status = -1;
    pid_t pid = fork();
    if (pid < 0)
        return DECRYPT_PLATFORM_ERROR;
    if (pid == 0) {
        if (ptrace(PT_TRACE_ME, 0, NULL, 0) != 0)
            _exit(127);
        int null_fd = open("/dev/null", O_RDWR);
        if (null_fd >= 0) {
            dup2(null_fd, STDIN_FILENO);
            dup2(null_fd, STDOUT_FILENO);
            dup2(null_fd, STDERR_FILENO);
            if (null_fd > STDERR_FILENO)
                close(null_fd);
        }
        char *arguments[] = {(char *)executable_path, NULL};
        execve(executable_path, arguments, environ);
        _exit(127);
    }

    int wait_status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &wait_status, WUNTRACED);
    } while (waited < 0 && errno == EINTR);
    if (waited != pid || !WIFSTOPPED(wait_status)) {
        // The child only reaches _exit(127) when execve refused the image. Anything else means it
        // ran and then died, which is a different problem, so keep the two distinguishable.
        if (waited == pid && WIFEXITED(wait_status))
            process->exec_status = WEXITSTATUS(wait_status);
        kill(pid, SIGKILL);
        return DECRYPT_PLATFORM_ERROR;
    }

    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        ptrace(PT_KILL, pid, NULL, 0);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return DECRYPT_PLATFORM_ERROR;
    }

    process->pid = pid;
    process->task = task;
    process->method = DECRYPT_LAUNCH_PTRACE;
    process->alive = true;
    return DECRYPT_OK;
}

decrypt_status_t decrypt_process_open(decrypt_process_t *process,
                                      const char *bundle_id,
                                      const char *executable_path,
                                      decrypt_logger_t *logger) {
    if (!process || !executable_path || !*executable_path)
        return DECRYPT_INVALID_ARGUMENT;
    memset(process, 0, sizeof(*process));
    process->pid = -1;

    decrypt_status_t status = DECRYPT_PLATFORM_ERROR;
    if (bundle_id && *bundle_id)
        status = open_sbs(process, bundle_id, executable_path, logger);
    if (status != DECRYPT_OK)
        status = open_ptrace(process, executable_path, logger);
    if (status != DECRYPT_OK)
        return status;

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "method",
                         process->method == DECRYPT_LAUNCH_SBS ? "sbs" : "ptrace");
    decrypt_attrs_int(&attrs, "pid", process->pid);
    if (bundle_id && *bundle_id)
        decrypt_attrs_string(&attrs, "bundle_id", bundle_id);
    else
        decrypt_attrs_string(&attrs, "exec", executable_path);
    decrypt_event(logger, DECRYPT_LOG_INFO, "target.spawned", &attrs,
                  "spawned %s via %s (pid=%d)",
                  bundle_id && *bundle_id ? bundle_id : executable_path,
                  process->method == DECRYPT_LAUNCH_SBS ? "SBS" : "ptrace",
                  process->pid);
    return DECRYPT_OK;
}

bool decrypt_process_start_loader(decrypt_process_t *process, decrypt_logger_t *logger) {
    if (!process || process->task == MACH_PORT_NULL)
        return false;
    if (process->method == DECRYPT_LAUNCH_SBS)
        return process->loader_ready;   // already ran to a settled state before being suspended
    if (process->method != DECRYPT_LAUNCH_PTRACE || !process->alive)
        return false;

    // A ptrace child is stopped at execve, where only the main image and dyld are mapped. Nothing
    // that needs the loader can work from there, so let it run. Under ptrace an app that kills
    // itself stops instead of dying, which is what makes this recoverable: by the time it aborts,
    // dyld has already mapped the bundle's frameworks and the address space is still readable.
    if (ptrace(PT_CONTINUE, process->pid, (void *)1, 0) != 0) {
        decrypt_event_attrs_t attrs;
        decrypt_attrs_init(&attrs);
        decrypt_attrs_int(&attrs, "errno", errno);
        decrypt_event(logger, DECRYPT_LOG_WARNING, "loader.continue_failed", &attrs,
                      "could not resume the traced target past execve");
        return false;
    }

    uint32_t last = 0, best = 0;
    unsigned stable = 0;
    int stop_signal = 0;
    const char *outcome = "timeout";
    for (unsigned attempt = 0; attempt < 120; attempt++) {
        int wait_status = 0;
        pid_t waited = waitpid(process->pid, &wait_status, WNOHANG | WUNTRACED);
        if (waited == process->pid) {
            if (WIFSTOPPED(wait_status)) {
                // Halted on its own signal with everything loaded. This is the good outcome for an
                // app that refuses to run headless, not a failure.
                stop_signal = WSTOPSIG(wait_status);
                outcome = "halted";
                break;
            }
            if (WIFEXITED(wait_status) || WIFSIGNALED(wait_status)) {
                process->alive = false;
                outcome = "exited";
                break;
            }
        }
        uint32_t current = decrypt_runtime_image_count(process->task);
        if (current > best)
            best = current;
        if (current != 0 && current == last) {
            if (++stable >= 4) {
                outcome = "settled";
                break;
            }
        } else {
            stable = 0;
        }
        last = current;
        usleep(250000);
    }

    if (process->alive)
        task_suspend(process->task);
    // Read after suspending: a count taken while the target was still running can be stale by the
    // time anything acts on it.
    uint32_t final = process->alive ? decrypt_runtime_image_count(process->task) : 0;
    if (final > best)
        best = final;
    process->loader_ready = final > 0;

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "outcome", outcome);
    decrypt_attrs_int(&attrs, "images", final);
    decrypt_attrs_int(&attrs, "peak", best);
    decrypt_attrs_int(&attrs, "signal", stop_signal);
    decrypt_event(logger, process->loader_ready ? DECRYPT_LOG_INFO : DECRYPT_LOG_WARNING,
                  "loader.ready", &attrs,
                  "traced target %s with %u image(s) mapped", outcome, final);
    return process->loader_ready;
}

void decrypt_process_close(decrypt_process_t *process) {
    if (!process)
        return;
    // First, so the installed bundle is left as found even if something below goes wrong.
    restore_mode(process);
    // Before the task goes away, so the send right the target holds dies with it rather than
    // leaking a name into this process for every bundle we open.
    if (process->exception_port != MACH_PORT_NULL) {
        mach_port_mod_refs(mach_task_self(), process->exception_port,
                           MACH_PORT_RIGHT_RECEIVE, -1);
        process->exception_port = MACH_PORT_NULL;
    }
    if (process->alive && process->method == DECRYPT_LAUNCH_PTRACE)
        ptrace(PT_KILL, process->pid, NULL, 0);
    if (process->task != MACH_PORT_NULL)
        task_terminate(process->task);
    if (process->alive && process->pid > 0)
        kill(process->pid, SIGKILL);
    if (process->method == DECRYPT_LAUNCH_PTRACE && process->pid > 0) {
        pid_t waited;
        do {
            waited = waitpid(process->pid, NULL, 0);
        } while (waited < 0 && errno == EINTR);
    }
    if (process->task != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), process->task);
    memset(process, 0, sizeof(*process));
    process->pid = -1;
}
