#include "CAttrBulk.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

enum { SWEEP_BULK_BUFFER_SIZE = 256 * 1024 };

typedef struct {
    const unsigned char *cursor;
    const unsigned char *end;
} SweepFields;

static bool sweep_take(SweepFields *fields, void *value, size_t size) {
    if (size > (size_t)(fields->end - fields->cursor)) {
        return false;
    }
    memcpy(value, fields->cursor, size);
    fields->cursor += size;
    return true;
}

static bool sweep_copy_name(
    SweepEntry *entry,
    const unsigned char *referenceAddress,
    const attrreference_t *reference,
    const unsigned char *entryStart,
    const unsigned char *entryEnd
) {
    if (reference->attr_dataoffset < 0 || reference->attr_length == 0) {
        return false;
    }

    size_t offset = (size_t)reference->attr_dataoffset;
    if (offset > (size_t)(entryEnd - referenceAddress)) {
        return false;
    }
    const unsigned char *name = referenceAddress + offset;
    if (name < entryStart || name >= entryEnd ||
        reference->attr_length > (size_t)(entryEnd - name)) {
        return false;
    }

    const void *terminator = memchr(name, '\0', reference->attr_length);
    if (terminator == NULL) {
        return false;
    }
    size_t length = (size_t)((const unsigned char *)terminator - name);
    if (length >= sizeof(entry->name)) {
        length = sizeof(entry->name) - 1;
    }
    memcpy(entry->name, name, length);
    entry->name[length] = '\0';
    return true;
}

int sweep_read_dir_cancellable(
    int dirfd,
    void *context,
    void (*visit)(void *context, const SweepEntry *entry),
    bool (*shouldCancel)(void *context)
) {
    if (visit == NULL) {
        return EINVAL;
    }

    struct attrlist attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr =
        ATTR_CMN_RETURNED_ATTRS |
        ATTR_CMN_NAME |
        ATTR_CMN_DEVID |
        ATTR_CMN_OBJTYPE |
        ATTR_CMN_MODTIME |
        ATTR_CMN_FLAGS |
        ATTR_CMN_FILEID;
    attributes.fileattr =
        ATTR_FILE_LINKCOUNT |
        ATTR_FILE_ALLOCSIZE |
        ATTR_FILE_DATALENGTH;
    attributes.forkattr =
        ATTR_CMNEXT_PRIVATESIZE |
        ATTR_CMNEXT_CLONEID |
        ATTR_CMNEXT_EXT_FLAGS;

    unsigned char *buffer = malloc(SWEEP_BULK_BUFFER_SIZE);
    if (buffer == NULL) {
        return ENOMEM;
    }

    int result = 0;
    for (;;) {
        if (shouldCancel != NULL && shouldCancel(context)) {
            result = ECANCELED;
            break;
        }
        int count = getattrlistbulk(
            dirfd,
            &attributes,
            buffer,
            SWEEP_BULK_BUFFER_SIZE,
            FSOPT_ATTR_CMN_EXTENDED
        );
        if (count < 0) {
            result = errno;
            break;
        }
        if (count == 0) {
            break;
        }

        const unsigned char *entryStart = buffer;
        const unsigned char *bufferEnd = buffer + SWEEP_BULK_BUFFER_SIZE;
        for (int index = 0; index < count; index++) {
            if (shouldCancel != NULL && shouldCancel(context)) {
                result = ECANCELED;
                break;
            }
            uint32_t length = 0;
            if ((size_t)(bufferEnd - entryStart) < sizeof(length)) {
                result = EIO;
                break;
            }
            memcpy(&length, entryStart, sizeof(length));
            if (length < sizeof(length) || length > (size_t)(bufferEnd - entryStart)) {
                result = EIO;
                break;
            }

            const unsigned char *entryEnd = entryStart + length;
            SweepFields fields = {
                .cursor = entryStart + sizeof(length),
                .end = entryEnd,
            };
            attribute_set_t returned;
            if (!sweep_take(&fields, &returned, sizeof(returned))) {
                result = EIO;
                break;
            }

            SweepEntry entry;
            memset(&entry, 0, sizeof(entry));
            entry.privateSize = -1;
            bool valid = true;
            fsobj_type_t objectType = 0;
            bool hasDevice = false;
            bool hasObjectType = false;
            bool hasModified = false;
            bool hasFlags = false;
            bool hasFileID = false;
            bool hasLinkCount = false;
            bool hasAllocatedSize = false;
            bool hasLogicalSize = false;

            if (returned.commonattr & ATTR_CMN_NAME) {
                const unsigned char *referenceAddress = fields.cursor;
                attrreference_t reference;
                valid = sweep_take(&fields, &reference, sizeof(reference)) &&
                    sweep_copy_name(
                        &entry,
                        referenceAddress,
                        &reference,
                        entryStart,
                        entryEnd
                    );
            } else {
                valid = false;
            }
            if (valid && (returned.commonattr & ATTR_CMN_DEVID)) {
                dev_t device;
                valid = sweep_take(&fields, &device, sizeof(device));
                entry.device = (int32_t)device;
                hasDevice = valid;
            }
            if (valid && (returned.commonattr & ATTR_CMN_OBJTYPE)) {
                valid = sweep_take(&fields, &objectType, sizeof(objectType));
                entry.isDirectory = objectType == VDIR;
                entry.isSymlink = objectType == VLNK;
                hasObjectType = valid;
            }
            if (valid && (returned.commonattr & ATTR_CMN_MODTIME)) {
                struct timespec modified;
                valid = sweep_take(&fields, &modified, sizeof(modified));
                entry.modifiedSeconds = modified.tv_sec;
                hasModified = valid;
            }
            if (valid && (returned.commonattr & ATTR_CMN_FLAGS)) {
                valid = sweep_take(&fields, &entry.bsdFlags, sizeof(entry.bsdFlags));
                hasFlags = valid;
            }
            if (valid && (returned.commonattr & ATTR_CMN_FILEID)) {
                valid = sweep_take(&fields, &entry.fileID, sizeof(entry.fileID));
                hasFileID = valid;
            }

            if (valid && (returned.fileattr & ATTR_FILE_LINKCOUNT)) {
                valid = sweep_take(&fields, &entry.linkCount, sizeof(entry.linkCount));
                hasLinkCount = valid;
            }
            if (valid && (returned.fileattr & ATTR_FILE_ALLOCSIZE)) {
                valid = sweep_take(&fields, &entry.allocatedSize, sizeof(entry.allocatedSize));
                hasAllocatedSize = valid;
            }
            if (valid && (returned.fileattr & ATTR_FILE_DATALENGTH)) {
                valid = sweep_take(&fields, &entry.logicalSize, sizeof(entry.logicalSize));
                hasLogicalSize = valid;
            }

            if (valid && (returned.forkattr & ATTR_CMNEXT_PRIVATESIZE)) {
                valid = sweep_take(&fields, &entry.privateSize, sizeof(entry.privateSize));
            }
            if (valid && (returned.forkattr & ATTR_CMNEXT_CLONEID)) {
                valid = sweep_take(&fields, &entry.cloneID, sizeof(entry.cloneID));
            }
            if (valid && (returned.forkattr & ATTR_CMNEXT_EXT_FLAGS)) {
                valid = sweep_take(&fields, &entry.extFlags, sizeof(entry.extFlags));
            }

            if (!valid) {
                result = EIO;
                break;
            }

            bool needsStat =
                !hasDevice ||
                !hasObjectType ||
                !hasModified ||
                !hasFlags ||
                !hasFileID ||
                (objectType == VREG &&
                    (!hasLinkCount || !hasAllocatedSize || !hasLogicalSize));
            if (needsStat) {
                struct stat status;
                if (fstatat(dirfd, entry.name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
                    result = errno;
                    break;
                }
                if (!hasDevice) {
                    entry.device = (int32_t)status.st_dev;
                }
                if (!hasObjectType) {
                    entry.isDirectory = S_ISDIR(status.st_mode);
                    entry.isSymlink = S_ISLNK(status.st_mode);
                    objectType = entry.isDirectory ? VDIR :
                        (entry.isSymlink ? VLNK : (S_ISREG(status.st_mode) ? VREG : 0));
                }
                if (!hasModified) {
                    entry.modifiedSeconds = status.st_mtimespec.tv_sec;
                }
                if (!hasFlags) {
                    entry.bsdFlags = status.st_flags;
                }
                if (!hasFileID) {
                    entry.fileID = status.st_ino;
                }
                if (objectType == VREG) {
                    if (!hasLinkCount) {
                        entry.linkCount = status.st_nlink;
                    }
                    if (!hasAllocatedSize) {
                        entry.allocatedSize = status.st_blocks * 512;
                    }
                    if (!hasLogicalSize) {
                        entry.logicalSize = status.st_size;
                    }
                }
            }
            visit(context, &entry);
            entryStart = entryEnd;
        }
        if (result != 0) {
            break;
        }
    }

    free(buffer);
    return result;
}

int sweep_read_dir(int dirfd, void *context, void (*visit)(void *context, const SweepEntry *entry)) {
    return sweep_read_dir_cancellable(dirfd, context, visit, NULL);
}
