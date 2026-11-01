/* SPDX-License-Identifier: Apache-2.0
 * Reproduce golden request protobuf bytes using Espressif Hosted 1.4.1's
 * generated protobuf-c definitions. This program does not open a device. */
#include <stdio.h>
#include "esp_hosted_rpc.pb-c.h"
static void emit(const Rpc *rpc) {
    unsigned char bytes[128];
    size_t length = rpc__pack(rpc, bytes);
    for (size_t i = 0; i < length; ++i) printf("%02x", bytes[i]);
    putchar('\n');
}
int main(void) {
    RpcReqOTABegin begin = RPC__REQ__OTABEGIN__INIT;
    RpcReqOTAWrite write = RPC__REQ__OTAWRITE__INIT;
    RpcReqOTAEnd end = RPC__REQ__OTAEND__INIT;
    unsigned char data[] = { 0xe9, 0x00, 0x80, 0xff };
    Rpc rpc = RPC__INIT;
    rpc.msg_type = RPC_TYPE__Req;
    rpc.msg_id = RPC_ID__Req_OTABegin; rpc.uid = 9;
    rpc.payload_case = RPC__PAYLOAD_REQ_OTA_BEGIN; rpc.req_ota_begin = &begin;
    emit(&rpc);
    write.ota_data.data = data; write.ota_data.len = sizeof(data);
    rpc.msg_id = RPC_ID__Req_OTAWrite; rpc.uid = 10;
    rpc.payload_case = RPC__PAYLOAD_REQ_OTA_WRITE; rpc.req_ota_write = &write;
    emit(&rpc);
    rpc.msg_id = RPC_ID__Req_OTAEnd; rpc.uid = 11;
    rpc.payload_case = RPC__PAYLOAD_REQ_OTA_END; rpc.req_ota_end = &end;
    emit(&rpc);
    return 0;
}
