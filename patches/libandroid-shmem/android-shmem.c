/*
 * libandroid-shmem for Debian ARM64 chroot on Android (no CONFIG_SYSVIPC).
 *
 * 100% wire-compatible with Termux:X11's libandroid-shmem protocol:
 *   - Abstract Unix domain socket: "\0/dev/shm/%08x" (addrlen = 3 + strlen(path))
 *   - shmid encoding: (socket_id << 16) | (idx & 0x7fff), with socket_id in [1..0x7fff]
 *     so shmid is always strictly positive (> 0) and matches Termux sdiv decoding.
 *   - Handshake: client sends int32 shmid -> server writes int32 key ->
 *     server sends ashmem/memfd fd via sendmsg(SCM_RIGHTS) with 1-byte '!' payload.
 *   - Hardened per security/concurrency review:
 *       * pthread_atfork() prepare/parent/child handlers (no deadlock on fork)
 *       * F_DUPFD_CLOEXEC before unlock in listener (no fd-reuse race)
 *       * SO_PEERCRED UID allowlist (own uid, root, droid 1000, Termux 10459, Termux:X11 10146)
 *       * 1s SO_RCVTIMEO / SO_SNDTIMEO; remote socket I/O runs OUTSIDE g_mutex
 *       * MSG_CMSG_CLOEXEC + MSG_CTRUNC + extra-fd leak cleanup in recv_fd()
 *       * Per-attachment table supporting multiple shmat() per shmid & MAP_FIXED/SHM_RND
 *       * Remote segments automatically released on last shmdt() (zero fd/RAM leak)
 *       * Non-owners never unlink the owner's key symlink on IPC_RMID
 *       * Signal-masked listener thread with transient accept4() retry
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define ASHMEM_NAME_LEN 256
#define __ASHMEMIOC     0x77
#define ASHMEM_SET_NAME _IOW(__ASHMEMIOC, 1, char[ASHMEM_NAME_LEN])
#define ASHMEM_SET_SIZE _IOW(__ASHMEMIOC, 3, size_t)
#define ASHMEM_GET_SIZE _IO(__ASHMEMIOC, 4)

#define KEY_SYMLINK_FMT "/tmp/ashv_key_%d"
#define SOCK_TIMEOUT_SEC 1

typedef struct {
    int      id;
    int      fd;
    size_t   size;
    bool     marked_for_delete;
    bool     is_local;
    key_t    key;
    int      attach_count;
} shmem_t;

typedef struct {
    void    *addr;
    int      shmid;
    size_t   size;
} attach_t;

static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t  g_atfork_once = PTHREAD_ONCE_INIT;

static shmem_t  *g_shmem = NULL;
static size_t    g_shmem_count = 0;

static attach_t *g_attaches = NULL;
static size_t    g_attach_count = 0;

static int       g_socket_id = 0;
static int       g_listen_sock = -1;
static int       g_shmid_counter = 0;
static bool      g_server_started = false;
static pid_t     g_owner_pid = 0;

static void atfork_prepare(void) {
    pthread_mutex_lock(&g_mutex);
}

static void atfork_parent(void) {
    pthread_mutex_unlock(&g_mutex);
}

static void atfork_child(void) {
    /* Re-initialize mutex cleanly in child and detach from parent's listener socket */
    pthread_mutex_init(&g_mutex, NULL);
    if (g_listen_sock >= 0) {
        close(g_listen_sock);
        g_listen_sock = -1;
    }
    g_server_started = false;
    g_socket_id = 0;
    g_shmid_counter = 0;
    g_owner_pid = getpid();
    /* Child is NOT the owner of parent's segments (prevents child unlinking parent's keys) */
    for (size_t i = 0; i < g_shmem_count; i++) {
        g_shmem[i].is_local = false;
    }
}

static void register_atfork_once(void) {
    pthread_atfork(atfork_prepare, atfork_parent, atfork_child);
}

static void init_atfork(void) {
    pthread_once(&g_atfork_once, register_atfork_once);
}

static size_t page_align(size_t sz) {
    long ps = sysconf(_SC_PAGESIZE);
    size_t p = (ps > 0) ? (size_t)ps : 4096;
    if (sz == 0) return p;
    return (sz + p - 1) & ~(p - 1);
}

static void set_sock_timeouts(int fd) {
    struct timeval tv;
    tv.tv_sec = SOCK_TIMEOUT_SEC;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static bool peer_uid_allowed(int sock) {
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(sock, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
        return false;
    }
    uid_t me = geteuid();
    if (cred.uid == me || cred.uid == 0 || cred.uid == 1000 ||
        cred.uid == 10459 /* Termux */ || cred.uid == 10146 /* Termux:X11 */) {
        return true;
    }
    const char *extra = getenv("ANDROID_SHMEM_ALLOW_UID");
    if (extra && *extra) {
        char *end = NULL;
        unsigned long u = strtoul(extra, &end, 10);
        if (end != extra && (uid_t)u == cred.uid) {
            return true;
        }
    }
    return false;
}

static int create_backing_fd(const char *name, size_t size) {
    size = page_align(size);
    int fd = open("/dev/ashmem", O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
        char buf[ASHMEM_NAME_LEN];
        memset(buf, 0, sizeof(buf));
        snprintf(buf, sizeof(buf) - 1, "%s", name ? name : "shmem");
        ioctl(fd, ASHMEM_SET_NAME, buf);
        if (ioctl(fd, ASHMEM_SET_SIZE, size) == 0) {
            return fd;
        }
        close(fd);
    }
#ifdef __NR_memfd_create
    fd = (int)syscall(__NR_memfd_create, name ? name : "shmem", 1U /* MFD_CLOEXEC */);
    if (fd >= 0) {
        if (ftruncate(fd, (off_t)size) == 0) {
            return fd;
        }
        close(fd);
    }
#endif
    return -1;
}

static ssize_t get_backing_size(int fd) {
    int sz = ioctl(fd, ASHMEM_GET_SIZE, 0);
    if (sz > 0) return (ssize_t)sz;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 0) {
        return (ssize_t)st.st_size;
    }
    return -1;
}

static int find_segment_locked(int shmid) {
    for (size_t i = 0; i < g_shmem_count; i++) {
        if (g_shmem[i].id == shmid) return (int)i;
    }
    return -1;
}

static int alloc_shmid_locked(void) {
    for (int tries = 0; tries < 0x7fff; tries++) {
        g_shmid_counter = (g_shmid_counter + 1) & 0x7fff;
        if (g_shmid_counter == 0) g_shmid_counter = 1;
        int cand = (g_socket_id << 16) | g_shmid_counter;
        if (find_segment_locked(cand) < 0) {
            return cand;
        }
    }
    return -1;
}

static void delete_segment_locked(size_t idx) {
    if (idx >= g_shmem_count) return;
    if (g_shmem[idx].fd >= 0) {
        close(g_shmem[idx].fd);
        g_shmem[idx].fd = -1;
    }
    /* Only the segment's owning process may unlink the shared key symlink */
    if (g_shmem[idx].is_local && g_shmem[idx].key != IPC_PRIVATE) {
        char path[128];
        snprintf(path, sizeof(path), KEY_SYMLINK_FMT, (int)g_shmem[idx].key);
        unlink(path);
    }
    if (idx + 1 < g_shmem_count) {
        memmove(&g_shmem[idx], &g_shmem[idx + 1],
                (g_shmem_count - idx - 1) * sizeof(shmem_t));
    }
    g_shmem_count--;
}

static int send_fd(int sock, int fd) {
    char dummy = '!';
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } u;
    memset(&u, 0, sizeof(u));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = u.buf;
    msg.msg_controllen = sizeof(u.buf);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));

    return (sendmsg(sock, &msg, MSG_NOSIGNAL) >= 0) ? 0 : -1;
}

static int recv_fd(int sock) {
    char dummy = 0;
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };
    union {
        char buf[CMSG_SPACE(sizeof(int) * 4)];
        struct cmsghdr align;
    } u;
    memset(&u, 0, sizeof(u));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = u.buf;
    msg.msg_controllen = sizeof(u.buf);

    ssize_t r = recvmsg(sock, &msg, MSG_CMSG_CLOEXEC);
    if (r <= 0) return -1;

    int got_fd = -1;
    bool bad = (msg.msg_flags & MSG_CTRUNC) != 0;

    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
            size_t data_len = (cmsg->cmsg_len >= CMSG_LEN(0)) ? (cmsg->cmsg_len - CMSG_LEN(0)) : 0;
            size_t n_fds = data_len / sizeof(int);
            int *fds = (int *)CMSG_DATA(cmsg);
            for (size_t i = 0; i < n_fds; i++) {
                if (!bad && got_fd < 0 && i == 0 && n_fds == 1) {
                    got_fd = fds[i];
                } else {
                    if (fds[i] >= 0) close(fds[i]);
                    bad = true;
                }
            }
        }
    }
    if (bad && got_fd >= 0) {
        close(got_fd);
        return -1;
    }
    return got_fd;
}

static void *ashv_thread_function(void *arg) {
    int listen_sock = *(int *)arg;
    free(arg);

    /* Block all signals in background listener thread */
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);

    for (;;) {
        struct sockaddr_un peer;
        socklen_t peer_len = sizeof(peer);
        int client = accept4(listen_sock, (struct sockaddr *)&peer, &peer_len, SOCK_CLOEXEC);
        if (client < 0) {
            if (errno == EINTR || errno == ECONNABORTED || errno == EAGAIN) {
                continue;
            }
            if (errno == EMFILE || errno == ENFILE) {
                usleep(10000);
                continue;
            }
            /* Fatal error on listening socket: allow future restart */
            pthread_mutex_lock(&g_mutex);
            if (g_listen_sock == listen_sock) {
                close(g_listen_sock);
                g_listen_sock = -1;
                g_server_started = false;
            }
            pthread_mutex_unlock(&g_mutex);
            break;
        }

        if (!peer_uid_allowed(client)) {
            close(client);
            continue;
        }
        set_sock_timeouts(client);

        int32_t req_shmid = 0;
        ssize_t n = recv(client, &req_shmid, sizeof(req_shmid), MSG_WAITALL);
        if (n == (ssize_t)sizeof(req_shmid)) {
            int dup_fd = -1;
            int32_t key_val = 0;

            pthread_mutex_lock(&g_mutex);
            int idx = find_segment_locked((int)req_shmid);
            if (idx >= 0 && g_shmem[idx].fd >= 0) {
                key_val = (int32_t)g_shmem[idx].key;
                /* Duplicate fd while holding lock to eliminate fd-reuse race after unlock */
                dup_fd = fcntl(g_shmem[idx].fd, F_DUPFD_CLOEXEC, 0);
            }
            pthread_mutex_unlock(&g_mutex);

            if (dup_fd >= 0) {
                ssize_t w = send(client, &key_val, sizeof(key_val), MSG_NOSIGNAL);
                if (w == (ssize_t)sizeof(key_val)) {
                    send_fd(client, dup_fd);
                }
                close(dup_fd);
            }
        }
        close(client);
    }
    return NULL;
}

static int ensure_server_locked(void) {
    pid_t me = getpid();
    if (g_owner_pid == 0) g_owner_pid = me;
    if (g_server_started) return 0;

    int sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (sock < 0) return -1;

    /* Restrict socket_id to [1..0x7fff] so shmid = (socket_id << 16) | idx is always > 0 */
    int base_id = (me % 0x7fff);
    bool bound = false;
    for (int tries = 0; tries < 4096; tries++) {
        int cand = ((base_id + tries) % 0x7fff) + 1;
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        int len = snprintf(addr.sun_path + 1, sizeof(addr.sun_path) - 1,
                           "/dev/shm/%08x", (unsigned int)cand);
        socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + len);
        if (bind(sock, (struct sockaddr *)&addr, alen) == 0) {
            g_socket_id = cand;
            bound = true;
            break;
        }
    }
    if (!bound || listen(sock, 16) != 0) {
        close(sock);
        return -1;
    }

    int *arg = malloc(sizeof(int));
    if (!arg) {
        close(sock);
        return -1;
    }
    *arg = sock;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t th;
    if (pthread_create(&th, &attr, ashv_thread_function, arg) != 0) {
        pthread_attr_destroy(&attr);
        free(arg);
        close(sock);
        return -1;
    }
    pthread_attr_destroy(&attr);
    g_listen_sock = sock;
    g_server_started = true;
    return 0;
}

/* Perform blocking socket I/O OUTSIDE g_mutex to prevent cross-process deadlock */
static int fetch_remote_fd_unlocked(int shmid, int32_t *out_key, size_t *out_size) {
    if (shmid <= 0) return -1;
    int sock = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (sock < 0) return -1;
    set_sock_timeouts(sock);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    unsigned int remote_id = ((unsigned int)shmid >> 16) & 0x7fffU;
    if (remote_id == 0) {
        close(sock);
        return -1;
    }
    int len = snprintf(addr.sun_path + 1, sizeof(addr.sun_path) - 1,
                       "/dev/shm/%08x", remote_id);
    socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + len);

    if (connect(sock, (struct sockaddr *)&addr, alen) != 0) {
        close(sock);
        return -1;
    }

    int32_t req = (int32_t)shmid;
    if (send(sock, &req, sizeof(req), MSG_NOSIGNAL) != (ssize_t)sizeof(req)) {
        close(sock);
        return -1;
    }

    int32_t remote_key = 0;
    if (recv(sock, &remote_key, sizeof(remote_key), MSG_WAITALL) != (ssize_t)sizeof(remote_key)) {
        close(sock);
        return -1;
    }

    int fd = recv_fd(sock);
    close(sock);
    if (fd < 0) return -1;

    ssize_t sz = get_backing_size(fd);
    if (sz <= 0) {
        close(fd);
        return -1;
    }
    *out_key = remote_key;
    *out_size = (size_t)sz;
    return fd;
}

static int find_or_fetch_segment_locked(int shmid) {
    int idx = find_segment_locked(shmid);
    if (idx >= 0) return idx;

    /* Avoid talking to our own listener socket if shmid belongs to us and doesn't exist */
    unsigned int target_sock = ((unsigned int)shmid >> 16) & 0x7fffU;
    if (g_server_started && (int)target_sock == g_socket_id) {
        return -1;
    }

    pthread_mutex_unlock(&g_mutex);
    int32_t remote_key = 0;
    size_t remote_size = 0;
    int fd = fetch_remote_fd_unlocked(shmid, &remote_key, &remote_size);
    pthread_mutex_lock(&g_mutex);

    if (fd < 0) return -1;

    /* Re-check in case another thread inserted it while unlocked */
    idx = find_segment_locked(shmid);
    if (idx >= 0) {
        close(fd);
        return idx;
    }

    shmem_t *tmp = realloc(g_shmem, (g_shmem_count + 1) * sizeof(shmem_t));
    if (!tmp) {
        close(fd);
        return -1;
    }
    g_shmem = tmp;
    idx = (int)g_shmem_count++;
    g_shmem[idx].id = shmid;
    g_shmem[idx].fd = fd;
    g_shmem[idx].size = remote_size;
    g_shmem[idx].marked_for_delete = false;
    g_shmem[idx].is_local = false;
    g_shmem[idx].key = (key_t)remote_key;
    g_shmem[idx].attach_count = 0;
    return idx;
}

int libandroid_shmget(key_t key, size_t size, int flags) {
    init_atfork();
    if (key == IPC_PRIVATE && size == 0) {
        errno = EINVAL;
        return -1;
    }

    pthread_mutex_lock(&g_mutex);
    if (ensure_server_locked() != 0) {
        pthread_mutex_unlock(&g_mutex);
        errno = ENOSPC;
        return -1;
    }

    int shmid = -1;
    if (key != IPC_PRIVATE) {
        char linkpath[128], target[64];
        snprintf(linkpath, sizeof(linkpath), KEY_SYMLINK_FMT, (int)key);
        for (int tries = 0; tries < 4; tries++) {
            ssize_t r = readlink(linkpath, target, sizeof(target) - 1);
            if (r > 0) {
                target[r] = '\0';
                int existing_id = atoi(target);
                if (existing_id > 0) {
                    int idx = find_or_fetch_segment_locked(existing_id);
                    if (idx >= 0) {
                        if ((flags & (IPC_CREAT | IPC_EXCL)) == (IPC_CREAT | IPC_EXCL)) {
                            pthread_mutex_unlock(&g_mutex);
                            errno = EEXIST;
                            return -1;
                        }
                        if (size > 0 && size > g_shmem[idx].size) {
                            pthread_mutex_unlock(&g_mutex);
                            errno = EINVAL;
                            return -1;
                        }
                        pthread_mutex_unlock(&g_mutex);
                        return existing_id;
                    }
                }
                unlink(linkpath);
            }
            if (!(flags & IPC_CREAT)) {
                pthread_mutex_unlock(&g_mutex);
                errno = ENOENT;
                return -1;
            }
            if (size == 0) {
                pthread_mutex_unlock(&g_mutex);
                errno = EINVAL;
                return -1;
            }
            shmid = alloc_shmid_locked();
            if (shmid < 0) {
                pthread_mutex_unlock(&g_mutex);
                errno = ENOSPC;
                return -1;
            }
            snprintf(target, sizeof(target), "%d", shmid);
            if (symlink(target, linkpath) == 0) break;
            shmid = -1;
        }
        if (shmid < 0) {
            pthread_mutex_unlock(&g_mutex);
            errno = EEXIST;
            return -1;
        }
    } else {
        shmid = alloc_shmid_locked();
        if (shmid < 0) {
            pthread_mutex_unlock(&g_mutex);
            errno = ENOSPC;
            return -1;
        }
    }

    size_t aligned = page_align(size);
    char name[64];
    snprintf(name, sizeof(name), "/dev/shm/%08x-%zu", (unsigned int)g_socket_id, g_shmem_count);
    int fd = create_backing_fd(name, aligned);
    if (fd < 0) {
        if (key != IPC_PRIVATE) {
            char linkpath[128];
            snprintf(linkpath, sizeof(linkpath), KEY_SYMLINK_FMT, (int)key);
            unlink(linkpath);
        }
        pthread_mutex_unlock(&g_mutex);
        errno = ENOMEM;
        return -1;
    }

    shmem_t *tmp = realloc(g_shmem, (g_shmem_count + 1) * sizeof(shmem_t));
    if (!tmp) {
        close(fd);
        pthread_mutex_unlock(&g_mutex);
        errno = ENOMEM;
        return -1;
    }
    g_shmem = tmp;
    size_t idx = g_shmem_count++;
    g_shmem[idx].id = shmid;
    g_shmem[idx].fd = fd;
    g_shmem[idx].size = aligned;
    g_shmem[idx].marked_for_delete = false;
    g_shmem[idx].is_local = true;
    g_shmem[idx].key = key;
    g_shmem[idx].attach_count = 0;

    pthread_mutex_unlock(&g_mutex);
    return shmid;
}

void *libandroid_shmat(int shmid, const void *shmaddr, int shmflg) {
    init_atfork();
    pthread_mutex_lock(&g_mutex);

    int idx = find_or_fetch_segment_locked(shmid);
    if (idx < 0) {
        pthread_mutex_unlock(&g_mutex);
        errno = EINVAL;
        return (void *)-1;
    }

    int prot = (shmflg & SHM_RDONLY) ? PROT_READ : (PROT_READ | PROT_WRITE);
    int mflags = MAP_SHARED;
    void *req_addr = (void *)shmaddr;
    if (req_addr != NULL) {
        if (shmflg & SHM_RND) {
            uintptr_t ps = (uintptr_t)page_align(1);
            req_addr = (void *)((uintptr_t)req_addr & ~(ps - 1));
        }
#ifdef MAP_FIXED_NOREPLACE
        mflags |= (shmflg & SHM_REMAP) ? MAP_FIXED : MAP_FIXED_NOREPLACE;
#else
        mflags |= MAP_FIXED;
#endif
    }

    size_t map_size = g_shmem[idx].size;
    void *addr = mmap(req_addr, map_size, prot, mflags, g_shmem[idx].fd, 0);
    if (addr == MAP_FAILED) {
        pthread_mutex_unlock(&g_mutex);
        return (void *)-1;
    }

    attach_t *atmp = realloc(g_attaches, (g_attach_count + 1) * sizeof(attach_t));
    if (!atmp) {
        munmap(addr, map_size);
        pthread_mutex_unlock(&g_mutex);
        errno = ENOMEM;
        return (void *)-1;
    }
    g_attaches = atmp;
    g_attaches[g_attach_count].addr = addr;
    g_attaches[g_attach_count].shmid = shmid;
    g_attaches[g_attach_count].size = map_size;
    g_attach_count++;

    g_shmem[idx].attach_count++;
    pthread_mutex_unlock(&g_mutex);
    return addr;
}

int libandroid_shmdt(const void *shmaddr) {
    init_atfork();
    pthread_mutex_lock(&g_mutex);

    for (size_t a = 0; a < g_attach_count; a++) {
        if (g_attaches[a].addr == shmaddr) {
            int shmid = g_attaches[a].shmid;
            size_t map_size = g_attaches[a].size;
            if (munmap((void *)shmaddr, map_size) != 0) {
                pthread_mutex_unlock(&g_mutex);
                return -1;
            }
            if (a + 1 < g_attach_count) {
                memmove(&g_attaches[a], &g_attaches[a + 1],
                        (g_attach_count - a - 1) * sizeof(attach_t));
            }
            g_attach_count--;

            int idx = find_segment_locked(shmid);
            if (idx >= 0) {
                if (g_shmem[idx].attach_count > 0) g_shmem[idx].attach_count--;
                /* Release segment when no mappings remain AND (marked for delete OR remote/non-owner) */
                if (g_shmem[idx].attach_count == 0 &&
                    (g_shmem[idx].marked_for_delete || !g_shmem[idx].is_local)) {
                    delete_segment_locked((size_t)idx);
                }
            }
            pthread_mutex_unlock(&g_mutex);
            return 0;
        }
    }

    pthread_mutex_unlock(&g_mutex);
    errno = EINVAL;
    return -1;
}

int libandroid_shmctl(int shmid, int cmd, struct shmid_ds *buf) {
    init_atfork();
    pthread_mutex_lock(&g_mutex);

    if (cmd == IPC_RMID) {
        int idx = find_segment_locked(shmid);
        if (idx < 0) {
            pthread_mutex_unlock(&g_mutex);
            return 0;
        }
        g_shmem[idx].marked_for_delete = true;
        if (g_shmem[idx].is_local && g_shmem[idx].key != IPC_PRIVATE) {
            char path[128];
            snprintf(path, sizeof(path), KEY_SYMLINK_FMT, (int)g_shmem[idx].key);
            unlink(path);
            g_shmem[idx].key = IPC_PRIVATE;
        }
        if (g_shmem[idx].attach_count == 0) {
            delete_segment_locked((size_t)idx);
        }
        pthread_mutex_unlock(&g_mutex);
        return 0;
    }

    if (cmd == IPC_STAT || cmd == SHM_STAT) {
        if (!buf) {
            pthread_mutex_unlock(&g_mutex);
            errno = EFAULT;
            return -1;
        }
        int idx = find_or_fetch_segment_locked(shmid);
        if (idx < 0) {
            pthread_mutex_unlock(&g_mutex);
            errno = EINVAL;
            return -1;
        }
        memset(buf, 0, sizeof(*buf));
        buf->shm_segsz = g_shmem[idx].size;
        buf->shm_nattch = (shmatt_t)g_shmem[idx].attach_count;
        buf->shm_perm.__key = g_shmem[idx].key;
        buf->shm_perm.uid = geteuid();
        buf->shm_perm.gid = getegid();
        buf->shm_perm.cuid = geteuid();
        buf->shm_perm.cgid = getegid();
        buf->shm_perm.mode = 0666;
        pthread_mutex_unlock(&g_mutex);
        return 0;
    }

    pthread_mutex_unlock(&g_mutex);
    errno = EINVAL;
    return -1;
}

/* Standard SysV IPC symbol exports (for LD_PRELOAD interposition) */
int   shmget(key_t key, size_t size, int flags) __attribute__((alias("libandroid_shmget")));
void *shmat(int shmid, const void *shmaddr, int shmflg) __attribute__((alias("libandroid_shmat")));
int   shmdt(const void *shmaddr) __attribute__((alias("libandroid_shmdt")));
int   shmctl(int shmid, int cmd, struct shmid_ds *buf) __attribute__((alias("libandroid_shmctl")));
