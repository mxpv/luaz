// Force-included into every Luau translation unit.
//
// Luau sources use malloc/abs/atoi/strtod/errno/etc. without including <stdlib.h> or <errno.h>, relying on them being
// pulled in transitively by other standard headers. That holds on macOS but not with libc++ on Linux.
#pragma once

#include <errno.h>
#include <stdlib.h>
