#ifndef CATTRBULK_H
#define CATTRBULK_H

#include <stdint.h>
#include <stdbool.h>

/// One directory entry as read by getattrlistbulk(2).
typedef struct {
    char name[1024];
    bool isDirectory;
    bool isSymlink;
    uint64_t fileID;
    int32_t device;
    int64_t logicalSize;      /* ATTR_FILE_DATALENGTH */
    int64_t allocatedSize;    /* ATTR_FILE_ALLOCSIZE */
    int64_t privateSize;      /* ATTR_CMNEXT_PRIVATESIZE, -1 when unsupported */
    uint64_t cloneID;         /* ATTR_CMNEXT_CLONEID, 0 when none */
    uint64_t extFlags;        /* ATTR_CMNEXT_EXT_FLAGS (EF_SHARES_ALL_BLOCKS, EF_IS_SPARSE ...) */
    uint32_t bsdFlags;        /* ATTR_CMN_FLAGS (SF_DATALESS ...) */
    uint32_t linkCount;
    int64_t modifiedSeconds;
} SweepEntry;

/// Reads every entry of `dirfd`. Calls `visit` once per entry; returns 0 or errno.
/// Implementation: see attrbulk.c.
int sweep_read_dir(int dirfd, void *context, void (*visit)(void *context, const SweepEntry *entry));

/// The cancellable form checks `shouldCancel` between entries and returns ECANCELED.
int sweep_read_dir_cancellable(
    int dirfd,
    void *context,
    void (*visit)(void *context, const SweepEntry *entry),
    bool (*shouldCancel)(void *context)
);

#endif
