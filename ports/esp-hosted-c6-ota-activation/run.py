#!/usr/bin/env python3
"""Compile the real 2.13.1 handler against host stubs before/after patch."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE_SHA = '337430b61a58f5179d12e867f4a1a17d4db28a70d2749d0e2fd45f0a6f8a4fd4'

PROLOGUE = r'''
#include <stdint.h>
#include <stdlib.h>
typedef int esp_err_t;
typedef void *TimerHandle_t;
typedef struct { int resp; } RpcRespOTAActivate;
typedef struct { int payload_case; RpcRespOTAActivate *resp_ota_activate; } Rpc;
enum { OTA_NOT_STARTED, OTA_IN_PROGRESS, OTA_COMPLETED, OTA_FAILED, OTA_ACTIVATED };
enum { ESP_OK = 0, ESP_FAIL = -1, ESP_ERR_NO_MEM = 257, ESP_ERR_INVALID_STATE = 259,
       RPC__PAYLOAD_RESP_OTA_ACTIVATE = 522, SUCCESS = 0, pdFALSE = 0, pdPASS = 1,
       RESTART_TIMEOUT = 2000 };
#define TAG "host-test"
#define ESP_LOGW(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
static unsigned boot_calls, timer_calls;
static int ota_status;
static void *update_partition;
static void rpc__resp__otaactivate__init(RpcRespOTAActivate *r) { r->resp = 0; }
static int esp_ota_set_boot_partition(void *p) { (void)p; ++boot_calls; return ESP_OK; }
static const char *esp_err_to_name(int e) { (void)e; return "error"; }
static void vTimerCallback(TimerHandle_t t) { (void)t; }
static TimerHandle_t xTimerCreate(const char *n, int d, int r, int i, void (*cb)(TimerHandle_t)) {
    (void)n;(void)d;(void)r;(void)i;(void)cb; ++timer_calls; return (void*)1;
}
static int xTimerStart(TimerHandle_t t, int wait) { (void)t;(void)wait; return pdPASS; }
'''
EPILOGUE = r'''
int main(void) {
    const int invalid[] = { OTA_NOT_STARTED, OTA_IN_PROGRESS, OTA_FAILED, OTA_ACTIVATED, 99 };
    for (unsigned i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) {
        Rpc req = {0}, resp = {0};
        boot_calls = timer_calls = 0; ota_status = invalid[i];
        int ret = req_ota_activate_handler(&req, &resp, NULL);
        if (ret != ESP_OK || !resp.resp_ota_activate ||
            resp.resp_ota_activate->resp != ESP_ERR_INVALID_STATE || boot_calls || timer_calls) return 1;
        free(resp.resp_ota_activate);
    }
    Rpc req = {0}, resp = {0};
    boot_calls = timer_calls = 0; ota_status = OTA_COMPLETED;
    int ret = req_ota_activate_handler(&req, &resp, NULL);
    if (ret != ESP_OK || !resp.resp_ota_activate || resp.resp_ota_activate->resp != 0 ||
        boot_calls != 1 || timer_calls != 1 || ota_status != OTA_ACTIVATED) return 2;
    free(resp.resp_ota_activate);
    (void)esp_err_to_name;
    return 0;
}
'''

def handler(source):
    start = source.index('static esp_err_t req_ota_activate_handler')
    brace = source.index('{', start)
    level = 0
    for i in range(brace, len(source)):
        if source[i] == '{': level += 1
        if source[i] == '}':
            level -= 1
            if level == 0: return source[start:i + 1]
    raise ValueError('unterminated handler')

def compile_and_run(source, directory, label):
    file = directory / (label + '.c')
    binary = directory / label
    file.write_text(PROLOGUE + '\n' + handler(source) + '\n' + EPILOGUE)
    subprocess.run(['cc', '-std=c17', '-Wall', '-Wextra', '-Wno-unused-parameter',
                    str(file), '-o', str(binary)], check=True)
    return subprocess.run([str(binary)], check=False).returncode

def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: run.py /path/to/esp-hosted-2.13.1')
    upstream = Path(sys.argv[1]) / 'slave/main/slave_control.c'
    data = upstream.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA:
        raise SystemExit('unexpected upstream source; refusing patch')
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        file = directory / 'slave/main/slave_control.c'
        file.parent.mkdir(parents=True)
        file.write_bytes(data)
        baseline = compile_and_run(data.decode(), directory, 'baseline')
        if baseline != 1:
            raise SystemExit(f'expected negative control to fail on invalid state, got {baseline}')
        with (HERE / 'activation-status.patch').open('rb') as patch:
            subprocess.run(['patch', '-s', '-p1', '-d', str(directory)], stdin=patch, check=True)
        patched = compile_and_run(file.read_text(), directory, 'patched')
        if patched:
            raise SystemExit(f'patched handler failed: {patched}')
    print('Baseline invalid-state negative control reproduced; patched handler passes five invalid states and completed activation')

if __name__ == '__main__':
    main()
