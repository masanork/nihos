/* SPDX-License-Identifier: Apache-2.0
 * Emit the independently generated ESP-Hosted 2.13.1 Activate request. */
#include <stdio.h>
#include "esp_hosted_rpc.pb-c.h"
int main(void) {
    RpcReqOTAActivate activate = RPC__REQ__OTAACTIVATE__INIT;
    Rpc rpc = RPC__INIT;
    unsigned char bytes[128];
    rpc.msg_type = RPC_TYPE__Req;
    rpc.msg_id = RPC_ID__Req_OTAActivate;
    rpc.uid = 12;
    rpc.payload_case = RPC__PAYLOAD_REQ_OTA_ACTIVATE;
    rpc.req_ota_activate = &activate;
    size_t length = rpc__pack(&rpc, bytes);
    for (size_t i = 0; i < length; ++i) printf("%02x", bytes[i]);
    putchar('\n');
    return 0;
}
