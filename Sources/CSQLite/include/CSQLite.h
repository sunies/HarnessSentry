#ifndef HARNESS_SENTRY_CSQLITE_H
#define HARNESS_SENTRY_CSQLITE_H

#include <sqlite3.h>

int hs_sqlite_bind_text(sqlite3_stmt *statement, int index, const char *value);

#endif
