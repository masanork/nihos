// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>
#include "protobuf-c/protobuf-c.h"

// Add backward-compatible diagnostic fields to a newly initialized response.
// On failure the message is untouched; the caller still returns its version.
int nihos_c6_add_diagnostics(ProtobufCMessage *message, uint32_t uptime_s, uint32_t heap_bytes);
