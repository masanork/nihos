# Native automatic card reader

Current qualification is recorded in
[the 2026-10-27 build evidence](measurements/2026-10-27-native-card-auto.md).
The automatic profile has not yet been installed or tested with a physical
card; conventional licence authentication and real insertion/removal remain
open checks. The previous My Number optical result does not qualify this image.

DISPLAY=11 adds physical insertion/removal gating and PIN-free SELECT-AID
classification for My Number cards and conventional Japanese IC driving
licences. Unsupported cards and cards answering both application probes do
not receive a credential. Classification is a capability observation, not
issuer authentication. A held card never starts another authentication job:
stable removal must precede the next insertion. USB disconnect cancels entry
and clears pending data. Local entry also checks the active slot state.

```sh
NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=11 sh tools/build-native.sh device integer
```

The detection-only build accepts no PIN and never runs an authenticated job:

```sh
NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=11 NIHOS_NATIVE_CARD_AUTO_PROBE=1 \
  sh tools/build-native.sh device integer
```

With an exclusively available port, the metadata-only capture can install a
retained candidate. The `--prior` directory is an optional full-image check
under that same lease before replacement. Source/ELF/options/manifests should
be frozen separately before installation.

```sh
python tools/capture-native-auto.py PORT FRESH_OUTPUT build/native-device/image-audit.json \
  --install build/native-device --jobs 2 --kinds 1,2 --require-removal
```

Kind 1 is My Number, kind 2 is a conventional IC licence. A probe run qualifies
only classification/removal. A read-enabled run additionally requires decoded
portrait, all expected displayed fields, no missing/truncated glyphs and final
erasure. The checker never supplies optical confirmation. Interrupted/failed
captures are retained and do not automatically reset the device. Serial release
after a successful observation also does not reset the interactive app.

## Conventional licence read

The protocol follows the public [NPA specification 010](https://www.npa.go.jp/laws/notification/koutuu/menkyo/menkyo20240719_145.pdf),
especially its MF/IEF PIN context and fixed EF lengths. `civ` revision
`54a843e656513930df60bbc20d752ff3289e7078` and the local Kotlin PoC were
consulted for wire sequencing; no upstream implementation is copied here.
The protocol is independently implemented in Zig.

Before offering entry, the reader checks the public PIN-setting EF and both
retry counters. Only a configured four-digit PIN is supported; a card declaring
unset PINs stops without guessing or submitting the specification's default
credential. Last-attempt/blocked/unknown counters stop that PIN. PIN1 and PIN2
use separate local sessions and separate one-use final-wire budgets. Each
counter is checked again immediately before its credential. Unknown outcomes
are terminal. No automatic credential retry or serial PIN input exists.

The read subset is DF1/EF01 (880 bytes, original name/address/birth date/licence
number/expiration) and DF2/EF01 (2005 bytes, portrait). No domicile, signature or
write commands are enabled. PIN1 reads the common fields; PIN2 enables the
portrait. A later portrait failure can expose validated common fields only
after terminal cleanup. Cancellation, disconnect and failed cleanup erase or
withhold them.

Text uses a generated 94x94 JIS X 0208 mapping (17,672 bytes) from Python's
standard `iso2022_jp` codec. Unknown/external glyphs become a visible square
and increment a missing-character count. Dates are strictly validated and
converted from recorded era dates. The existing bounded OpenJPEG decoder
handles the extracted 5F40 JP2/J2K value; its quotas and isolated CPU0 stack
are unchanged. Names/data/portraits/PINs never leave the device or enter logs.

The screen explicitly identifies the values as **original issue data** and
states that signature verification has not been performed. Change-record EFs
are not applied; it must not be used to claim current address, driving
entitlement or issuer authenticity. My Number card licence-AP reading
(マイナ免許証) is a different protocol and is not included in this profile.

## Native boundaries and evidence

The default service/wire-policy variants retain their My Number scope. The
extended variants are opt-in and place foreground protocol functions in the
audited optional Flash span. The image audit binds automatic-card profile,
JIS bytes/hash, source hashes, narrow module functions and existing codec
object hashes. It preserves the two mapped segments, 640 KiB optional Flash
window, separate stacks and 48 KiB primary SRAM heap minimum.

Host models cover classification ambiguity, insertion debounce/removal gating,
fixed-length file reads, strict TLV/date/JIS parsing, separate PIN sessions,
one-shot wire budgets and cleanup/erasure. Host/build success is separate from
real-card classification, both PIN responses, portrait rendering and the
user's optical observation. Record each physical candidate with its exact
artifacts and retain unsuccessful attempts.
