/* Exercise the normal build, with all failure-injection hooks compiled out. */
#include "nihos_sqlite_session.h"
#include <stdio.h>
#include <string.h>
int nih_host_recovered(void);
int main(void) {
    struct nih_sqlite_result result = { 0, 0 };
    const char *sql = "SELECT 6*7";
    if (nih_sqlite_session_open() ||
        nih_sqlite_session_eval(sql, strlen(sql), &result) ||
        !result.has_value || result.value != 42 ||
        nih_sqlite_session_close() || !nih_host_recovered()) return 1;
    puts("SQLite non-test configuration host PASS: scalar result, shutdown and heap recovery");
    return 0;
}
