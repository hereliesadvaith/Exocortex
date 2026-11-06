/* Minimal SysV shm emulation for PostgreSQL under PRoot (shmget returns EIO there).
   Only supports what postgres uses for its small interlock segment. */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>
#include <stddef.h>

#define MAXSEG 64
static struct { int used; key_t key; size_t size; void *addr; int nattch; } segs[MAXSEG];

int shmget(key_t key, size_t size, int flg) {
    for (int i = 0; i < MAXSEG; i++)
        if (segs[i].used && key != IPC_PRIVATE && segs[i].key == key) {
            if ((flg & IPC_CREAT) && (flg & IPC_EXCL)) { errno = EEXIST; return -1; }
            return i + 1;
        }
    if (!(flg & IPC_CREAT)) { errno = ENOENT; return -1; }
    for (int i = 0; i < MAXSEG; i++)
        if (!segs[i].used) {
            void *p = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
            if (p == MAP_FAILED) return -1;
            segs[i].used = 1; segs[i].key = key; segs[i].size = size; segs[i].addr = p; segs[i].nattch = 0;
            return i + 1;
        }
    errno = ENOSPC; return -1;
}

void *shmat(int id, const void *addr, int flg) {
    (void)addr; (void)flg;
    if (id < 1 || id > MAXSEG || !segs[id-1].used) { errno = EINVAL; return (void*)-1; }
    segs[id-1].nattch++;
    return segs[id-1].addr;
}

int shmdt(const void *addr) {
    for (int i = 0; i < MAXSEG; i++)
        if (segs[i].used && segs[i].addr == addr) { if (segs[i].nattch) segs[i].nattch--; return 0; }
    errno = EINVAL; return -1;
}

int shmctl(int id, int cmd, struct shmid_ds *buf) {
    if (id < 1 || id > MAXSEG || !segs[id-1].used) { errno = EINVAL; return -1; }
    if (cmd == IPC_STAT && buf) {
        memset(buf, 0, sizeof *buf);
        buf->shm_segsz = segs[id-1].size;
        buf->shm_nattch = segs[id-1].nattch;
        return 0;
    }
    if (cmd == IPC_RMID) { /* keep mapping alive for attached procs; just forget the key */
        segs[id-1].key = IPC_PRIVATE; return 0;
    }
    return 0;
}
