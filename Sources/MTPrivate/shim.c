#include "MTPrivate.h"

// The struct's size as this build sees it. Compared at startup against a pinned
// expected value so an accidental edit to MTTouch is caught loudly rather than
// silently misinterpreting frame memory (docs/04 §Sanity checks).
size_t MTPrivate_touchStructSize(void) {
    return sizeof(MTTouch);
}
