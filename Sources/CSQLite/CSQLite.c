#include "CSQLite.h"

int hs_sqlite_bind_text(sqlite3_stmt *statement, int index, const char *value) {
    return sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT);
}
