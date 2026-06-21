/* C imports for the MariaDB client.
 *
 * Zig 0.16 deprecated the inline `@cImport` builtin in favour of translating C
 * through the build system (`b.addTranslateC`). This header is the single
 * translation unit consumed by that step and exposed to Zig as `@import("c")`.
 */
#include <mysql.h>
#include <time.h>
