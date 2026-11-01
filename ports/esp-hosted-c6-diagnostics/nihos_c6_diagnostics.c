// SPDX-License-Identifier: Apache-2.0
#include <stdlib.h>
#include "nihos_c6_diagnostics.h"

int nihos_c6_add_diagnostics(ProtobufCMessage *message, uint32_t uptime_s, uint32_t heap_bytes)
{
    const uint32_t values[3] = { 1, uptime_s, heap_bytes };
    ProtobufCMessageUnknownField *fields;
    if (!message || message->n_unknown_fields || message->unknown_fields) return 0;
    fields = calloc(3, sizeof(*fields));
    if (!fields) return 0;
    for (unsigned i = 0; i < 3; i++) {
        uint32_t n = values[i];
        fields[i].data = malloc(5);
        if (!fields[i].data) {
            for (unsigned j = 0; j < i; j++) free(fields[j].data);
            free(fields);
            return 0;
        }
        fields[i].tag = 100 + i;
        fields[i].wire_type = PROTOBUF_C_WIRE_TYPE_VARINT;
        do {
            uint8_t byte = n & 0x7f;
            n >>= 7;
            fields[i].data[fields[i].len++] = byte | (n ? 0x80 : 0);
        } while (n);
    }
    // protobuf-c's regular free_unpacked releases the array and its data.
    message->unknown_fields = fields;
    message->n_unknown_fields = 3;
    return 1;
}
