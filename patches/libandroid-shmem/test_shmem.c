/*
 * Comprehensive cross-process SysV SHM + abstract-socket SCM_RIGHTS test suite.
 * Exercises:
 *   1. True separate-process execv() socket fetch (connect -> send -> recvmsg SCM_RIGHTS)
 *   2. Remote shmdt() fd cleanup (verifies zero fd leak in client!)
 *   3. Double shmat() of the same shmid + detaching first mapping cleanly
 *   4. IPC_RMID while attached, followed by cleanup on final shmdt()
 *   5. Keyed shmget() lookup & non-owner IPC_RMID preserving owner's key symlink
 *   6. Positive shmid invariant (> 0) and unknown shmctl() returning -1/EINVAL
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/wait.h>
#include <unistd.h>

static int count_open_fds(void) {
    DIR *d = opendir("/proc/self/fd");
    if (!d) return -1;
    int n = 0;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] != '.') n++;
    }
    closedir(d);
    return n - 1; /* exclude opendir's own fd */
}

static int run_client(int shmid, key_t key) {
    int fds_before = count_open_fds();

    /* 1. True remote fetch over abstract Unix socket (fresh exec'd process!) */
    char *p1 = (char *)shmat(shmid, NULL, 0);
    if (p1 == (void *)-1) {
        perror("client shmat #1");
        return 10;
    }
    if (strcmp(p1, "PARENT_SOCKET_PAYLOAD_OK") != 0) {
        fprintf(stderr, "client read mismatch: '%s'\n", p1);
        return 11;
    }

    /* 2. Double shmat of the same shmid */
    char *p2 = (char *)shmat(shmid, NULL, 0);
    if (p2 == (void *)-1) {
        perror("client shmat #2");
        return 12;
    }
    strcpy(p2, "CLIENT_REMOTE_SOCKET_WRITE_OK");
    if (strcmp(p1, "CLIENT_REMOTE_SOCKET_WRITE_OK") != 0) {
        fprintf(stderr, "double shmat alias mismatch\n");
        return 13;
    }

    /* Detach FIRST mapping, verify second still works, then detach second */
    if (shmdt(p1) != 0) {
        perror("client shmdt(p1)");
        return 14;
    }
    if (strcmp(p2, "CLIENT_REMOTE_SOCKET_WRITE_OK") != 0) {
        fprintf(stderr, "p2 corrupted after shmdt(p1)\n");
        return 15;
    }
    if (shmdt(p2) != 0) {
        perror("client shmdt(p2)");
        return 16;
    }

    /* 3. Verify remote shmdt() released the fetched fd (zero leak!) */
    int fds_after = count_open_fds();
    if (fds_after != fds_before) {
        fprintf(stderr, "FD LEAK on remote detach: before=%d after=%d\n", fds_before, fds_after);
        return 17;
    }

    /* 4. Keyed lookup + non-owner IPC_RMID must NOT delete owner's key symlink */
    int kid = shmget(key, 4096, 0666);
    if (kid <= 0) {
        perror("client keyed shmget");
        return 18;
    }
    shmctl(kid, IPC_RMID, NULL);

    /* 5. Unknown shmctl command must return -1 / EINVAL */
    errno = 0;
    if (shmctl(shmid, 9999, NULL) != -1 || errno != EINVAL) {
        fprintf(stderr, "unknown shmctl did not return -1/EINVAL (errno=%d)\n", errno);
        return 19;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--client") == 0) {
        return run_client(atoi(argv[2]), (key_t)atoi(argv[3]));
    }

    int id = shmget(IPC_PRIVATE, 65536, IPC_CREAT | 0666);
    if (id <= 0) {
        perror("parent shmget private");
        return 1;
    }

    key_t test_key = (key_t)(0x42000 + (getpid() & 0xfff));
    int kid = shmget(test_key, 4096, IPC_CREAT | IPC_EXCL | 0666);
    if (kid <= 0) {
        perror("parent shmget keyed");
        return 2;
    }

    char *p = (char *)shmat(id, NULL, 0);
    if (p == (void *)-1) {
        perror("parent shmat");
        return 3;
    }
    strcpy(p, "PARENT_SOCKET_PAYLOAD_OK");

    pid_t pid = fork();
    if (pid == 0) {
        char id_str[32], key_str[32];
        snprintf(id_str, sizeof(id_str), "%d", id);
        snprintf(key_str, sizeof(key_str), "%d", (int)test_key);
        char *cargv[] = { argv[0], "--client", id_str, key_str, NULL };
        execv(argv[0], cargv);
        perror("execv");
        _exit(99);
    }

    int st = 0;
    waitpid(pid, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fprintf(stderr, "Client failed (status=%d, exit=%d)\n", st, WIFEXITED(st) ? WEXITSTATUS(st) : -1);
        return 4;
    }
    if (strcmp(p, "CLIENT_REMOTE_SOCKET_WRITE_OK") != 0) {
        fprintf(stderr, "Parent read mismatch: '%s'\n", p);
        return 5;
    }

    /* Verify owner's key symlink still exists after non-owner IPC_RMID */
    int kid2 = shmget(test_key, 4096, 0666);
    if (kid2 != kid) {
        fprintf(stderr, "Owner key lost after non-owner IPC_RMID (kid=%d kid2=%d)\n", kid, kid2);
        return 6;
    }

    /* Test IPC_RMID while attached, then final shmdt() */
    struct shmid_ds ds;
    if (shmctl(id, IPC_STAT, &ds) != 0 || ds.shm_segsz < 65536) {
        fprintf(stderr, "IPC_STAT failed\n");
        return 7;
    }
    if (shmctl(id, IPC_RMID, NULL) != 0 || shmdt(p) != 0) {
        fprintf(stderr, "IPC_RMID / shmdt cleanup failed\n");
        return 8;
    }
    shmctl(kid, IPC_RMID, NULL);

    printf("SHMEM_ALL_TESTS_PASS shmid=0x%08x exec_socket=OK double_shmat=OK fd_leak=0 keyed_rmid=OK\n",
           (unsigned int)id);
    return 0;
}
