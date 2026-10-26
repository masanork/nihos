# Native PIN-free JPKI diagnostic

Build the existing native USB probe with an explicit additional option:

```sh
NIHOS_NATIVE_USB=1 NIHOS_NATIVE_JPKI=1 sh tools/build-native.sh device integer
```

This diagnostic activates the reader/card using CCID `IccPowerOn`, selects the
JPKI authentication application, reads the authentication PIN retry counter,
reads 64 bytes from the public authentication certificate EF, extracts its
X.509 serial number, and queries the same retry counter again. It requests
`IccPowerOff` before USB DMA/PHY cleanup and subsequent native SMP execution.
The PIN-free option requires USB and defaults to disabled.

## Exact card-command boundary

Both the APDU method and the lowest CCID command boundary enforce a fixed
allowlist. There is no PIN input, formatting, or guessing API in this probe.

| Operation | Exact APDU (hex) |
| --- | --- |
| Select JPKI | `00 a4 04 0c 0a d3 92 f0 00 26 01 00 00 00 01` |
| Select authentication PIN EF | `00 a4 02 0c 02 00 18` |
| Query retry count | `00 20 00 80` (exactly 4 bytes, no Lc/data/Le) |
| Select authentication certificate EF | `00 a4 02 0c 02 00 0a` |
| Read certificate prefix | `00 b0 00 00 40` |

The permitted CCID messages are empty-payload `IccPowerOn`/`IccPowerOff`,
and `XfrBlock` containing one of these exact APDUs. PIN-bearing VERIFY,
password changes/resets, secure PIN entry, arbitrary APDUs and escape-command
bypasses are rejected before USB transmission. No automatic APDU retry or
PIN-bearing fallback exists. `63Cn` is interpreted as the remaining count,
`6983` as blocked, and `9000` as already verified (not a count). The strict
physical checker accepts only a measured count of 1..3 unchanged before/after.

The sequence and file identifiers were checked against the user's read-only
`~/repo/civ` at commit `54a843e656513930df60bbc20d752ff3289e7078`,
`src/jpki.rs` (`get_auth_pin_retries`, `get_pin_retry_count`, `read_auth_cert`)
and `crates/civ-card/src/apdu.rs` (`DF_JPKI`, `EF_AUTH_PIN`, `EF_AUTH_CERT`).
That repository was not modified or built. It is MIT/Apache-2.0 dual licensed;
this is a small independent Zig implementation of its wire sequence.

## Parsing and qualification

The fixed 512-byte CCID buffers validate message type, declared size, slot,
sequence, card/command status, and at most four time-extension responses.
Certificate parsing consumes a bounded DER prefix, including the optional
version wrapper, and accepts only a positive, minimally encoded serial number
of at most 20 bytes. It does not read the entire certificate or claim to
validate its signature, issuer, validity period or authenticity.

On the tested RC-S300/P, requests immediately after USB configuration returned
absent with an empty PowerOn result. A two-second settle after configuration
then produced a card/ATR and successful APDUs. This is a physical observation
of one reader and card, not a general timing requirement or a root-cause proof.

After installing the selected native image:

```sh
python tools/capture-native-usb.py /dev/cu.usbmodem101 \
  /absolute/path/to/evidence build/native-device/image-audit.json --jpki
```

The strict checker requires the complete existing USB/native execution checks,
successful JPKI result, seven APDUs, no PIN data, equal before/after counts,
a well-formed serial result, and successful card power-off. The requested
certificate serial is in the private raw serial log; JSON summaries and
repository measurement notes retain only its byte length. Resetting the
installed diagnostic reruns the same PIN-free sequence.

References: [CCID 1.1](https://www.usb.org/sites/default/files/DWG_Smart-Card_CCID_Rev110.pdf),
[civ JPKI source](https://github.com/masanork/civ/blob/54a843e656513930df60bbc20d752ff3289e7078/src/jpki.rs).
Sony's distributed CCID source and third-party Port-400 implementations were
consulted during investigation; none is linked or copied into this firmware.
