# Native automatic card reader

DISPLAY=11 has PIN-free application detection and insertion/removal gating for
My Number cards, conventional IC driving licences, and the licence AP on a My
Number card. A SELECT response establishes an application capability only.
It does not authenticate the issuer or prove a current driving entitlement.

The extended implementation's host/build and physical evidence is recorded
separately in [the qualification notes](measurements/2026-10-27-native-licence-v2.md).
No official issuer keys are provisioned in the default build. It therefore
reports **unknown key**, never signature success for a real licence.

## Card jobs and local consent

| Kind | Profile | Local PIN namespaces |
| --- | --- | --- |
| 1 | My Number four fields and portrait | Input Support PIN; existing portrait flow |
| 2 | Conventional IC driving licence | PIN1, then a separate PIN2 session |
| 4 | My Number licence AP | Its own four-digit PIN, up to ten observed attempts |

The detector SELECTs the three supported AIDs without sending a credential or
reading identity data. A My Number card with the licence AP offers a local
choice between licence information and My Number information. PINs are never
reused across applications. Unknown/conflicting responses do not authenticate.

A held card cannot start another job: stable removal must precede the next
insertion. Local PIN entry checks slot presence, requires release before each
new screen, and times out. USB disconnect cancels the job. Each credential has
an independent final-wire budget of one, consumed before dispatch. Counters
are checked before entry and again before submission. Last-attempt, changed,
blocked, malformed and unknown outcomes stop that PIN; no automatic retry,
PIN injection through serial, reset/unblock or write commands exist.

Only configured numeric PINs are supported. An unset-PIN declaration stops
without sending the default credential. My Number licence history-certificate
records (as opposed to licence records) are rejected rather than presented as
a driving licence.

## Reads, changes and display

The wire facts follow [NPA specification 010](https://www.npa.go.jp/laws/notification/koutuu/menkyo/menkyo20240719_145.pdf).
`civ` revision `54a843e656513930df60bbc20d752ff3289e7078` and the local Kotlin
reader were consulted; no upstream implementation is copied.

The conventional job reads bounded DF1 EFs 01 through 07 and DF2/EF01, retaining
the exact fixed file bytes. PIN1 reads the common fields and change/signature
records. PIN2 enables the original domicile, domicile changes and portrait.
The PIN2 screen explains the domicile read: its original bytes are necessary
for the signed hash and remain inside the private workspace. The main screen
does not display the original domicile.

Validated name/address changes update the basic view. The dated change records,
including condition additions/releases and domicile changes, are available on
local history pages. Group order, duplicate tags, dates, lengths and flags are
checked. Untyped overflow records remain visible but trigger an explicit
warning that the latest value must be checked in history. They are not guessed
into a name/address. Unknown/external characters render as squares and are
counted; MMR external-character bitmap rendering remains unsupported.

The My Number licence job selects the instance AID ending in PIX 06, reads
WEF01/001A, checks IEF01/0006 with VERIFY P2=82, then reads WEF02/001B (5845 bytes)
and WEF03/001C (584 bytes). Its view shows the record number, expiration,
licence types, conditions/remarks and portrait. Names, address and birth date
are not fabricated or copied from the separate My Number AP. The parser accepts
literal extended tags and the FF-extension convention used by the reference
reader, rejects mixed encodings, and still needs comparison with a physical
card's encoding.

All result slices are withheld until terminal transport cleanup. Later
conventional photo/PIN2 failures can retain validated common/change data after
successful cleanup; cancellation, disconnect and cleanup failure withhold and
erase it. Tap-to-close, timeout and removal erase the result workspace and
replace display buffers. No PIN, field, portrait, identifier, touch coordinate
or key identity enters logs or leaves the device.

## Signature verification and keys

The verifier uses RSA-2048, public exponents 3/65537 and SHA-256. It implements
the exact NPA diagram's `00 01 FF...FF 00 digest` block. Generic ASN.1
DigestInfo padding is a different format and is explicitly rejected; there is
no permissive fallback. Conventional signatures bind all 880+82+2005 original
file bytes, including padding. My Number licence signatures bind all 5845 WEF02
bytes. Change EFs are outside the conventional signature and are labelled so.

EF07/WEF03 key identifiers select only explicitly pinned external public keys.
No card-supplied key becomes a trust anchor. Status distinguishes unchecked,
unknown key, mathematical match, mismatch and malformed signature data. A
match means a signature under a registered key; runtime certificate-chain,
expiry/revocation, chip-clone and current-entitlement checks are not implemented.
The existing My Number identity/portrait AP signature is a separate profile
and is still labelled unverified.

Provision public X.509 certificates obtained through a trusted route using a
reviewed JSON list. Supply each file's SHA-256 fingerprint and provenance:

```json
[{"certificate":"issuer.der","sha256":"REPLACE_WITH_REVIEWED_FILE_SHA256","source":"REPLACE_WITH_TRUSTED_PROVENANCE"}]
```

```sh
python3 tools/import-license-trust.py pins.json src/card/license_trust.bin
```

The importer validates RSA size/exponent, SKI uniqueness and file fingerprints;
it never fetches a key or contacts the issuer. It records certificate dates for
review but does not enforce them at runtime. Rebuild and audit after any pin
change. The default bundle is empty; synthetic test keys are never added to it.

## Native boundaries and reproducible checks

The primary SRAM heap minimum remains 48 KiB; mapped segments and the 640 KiB
optional Flash window are unchanged. The automatic reader uses a lossless
357358-byte encoding of the complete 408096-byte, 11336-glyph pinned Noto font.
Both Python and Zig compare every decoded glyph with the original, and the
image audit checks the decoded font hash. The OFL notice remains in
`src/graphics/boot/OFL.txt`.

OpenJPEG retains its pinned decoder-only objects, quotas and isolated 12 KiB
SRAM stack. Licence public-key arithmetic uses pinned Zig standard-library
Montgomery primitives on a separate guarded 64 KiB stack inside the same live,
task-owned 4 MiB external-memory lease. It does not borrow another task's stack
or increase the lease. Both the crypto stack and workspace are erased.
Synthetic crypto self-tests and stack use are logged without credential data.

```sh
NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=11 sh tools/build-native.sh device integer
NIHOS_NATIVE_USB=1 NIHOS_NATIVE_DISPLAY=11 NIHOS_NATIVE_CARD_AUTO_PROBE=1 \
  sh tools/build-native.sh device integer
```

The second image accepts no PIN and performs no authenticated job. Begin
physical checks with it. Freeze exact artifacts before installation:

```sh
python3 tools/capture-native-auto.py PORT FRESH_OUTPUT CANDIDATE/image-audit.json \
  --install CANDIDATE --jobs 1 --kinds 4 --require-removal
```

Kind requirements must match the cards actually available. Full read evidence
also requires all expected fields, decoded portrait, display/erasure metadata
and a separate optical observation. `check-native-auto-log.py --require-signature`
additionally requires a registered-key signature match; ordinary read evidence
keeps unknown-key results explicitly separate. Failed attempts are retained
and do not automatically reset the device. Successful capture does not reset
the interactive app on release.
