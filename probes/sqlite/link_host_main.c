#include <stdio.h>
int nih_sqlite_link_probe(void);
int main(void) {
    for (unsigned int i = 0; i < 16; ++i) {
        int rc = nih_sqlite_link_probe();
        if (rc) { fprintf(stderr, "SQLite link oracle rc=%d iteration=%u\n", rc, i); return 1; }
    }
    puts("SQLite link oracle host PASS: 16 init/scalar/REAL/UTC-policy/shutdown/heap-recovery cycles");
    return 0;
}
