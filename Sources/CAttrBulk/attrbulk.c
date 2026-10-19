#include "CAttrBulk.h"
#include <errno.h>

// P1: implement with getattrlistbulk(2). Placeholder keeps the target building.
int sweep_read_dir(int dirfd, void *context, void (*visit)(void *context, const SweepEntry *entry)) {
    (void)dirfd; (void)context; (void)visit;
    return ENOSYS;
}
