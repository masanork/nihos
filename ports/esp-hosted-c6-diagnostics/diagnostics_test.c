// SPDX-License-Identifier: Apache-2.0
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "esp_hosted_rpc.pb-c.h"
#include "nihos_c6_diagnostics.h"

int main(void)
{
    static const unsigned char expected[] = {
        0x10, 0x01, 0x18, 0x04, 0x20, 0x01, // unchanged Hosted 1.4.1
        0xa0, 0x06, 0x01, // diagnostics schema 1
        0xa8, 0x06, 0x7d, // uptime 125 seconds
        0xb0, 0x06, 0xc9, 0x98, 0x08 // free heap 134217 bytes
    };
    RpcRespGetCoprocessorFwVersion *msg = calloc(1, sizeof(*msg));
    unsigned char packed[128];
    assert(msg);
    rpc__resp__get_coprocessor_fw_version__init(msg);
    msg->major1 = 1; msg->minor1 = 4; msg->patch1 = 1;
    assert(nihos_c6_add_diagnostics(&msg->base, 125, 134217));
    assert(!nihos_c6_add_diagnostics(&msg->base, 1, 1));
    size_t size = rpc__resp__get_coprocessor_fw_version__pack(msg, packed);
    assert(size == sizeof(expected));
    assert(!memcmp(expected, packed, size));
    rpc__resp__get_coprocessor_fw_version__free_unpacked(msg, NULL);
    return 0;
}
