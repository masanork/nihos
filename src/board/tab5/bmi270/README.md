# Bosch BMI270 configuration data

`config.bin` is the unmodified 8,192-byte `bmi270_config_file` array extracted
from Bosch Sensortec's BMI270 SensorAPI `bmi270.c` at commit
`41129fcfe39c583ee5462d79195741945d51c1fe` (file version 2.86.1).

- Upstream: https://github.com/boschsensortec/BMI270_SensorAPI/blob/41129fcfe39c583ee5462d79195741945d51c1fe/bmi270.c
- Raw upstream file SHA-256: `f6446867378bbcc90ea97ef6593555de8767ca20b799355c1b37c2cabb7b7b41`
- Configuration SHA-256: `2d75e68e343a13ff99be98261dfbd99d9e8c6f267da9e3c5aeb883276ad178db`
- Copyright (c) 2023 Bosch Sensortec GmbH. All rights reserved.
- License: BSD-3-Clause; full upstream notice in [LICENSE](LICENSE).

Extraction takes hexadecimal bytes inside `const uint8_t bmi270_config_file[]`
in their original order, without the C declaration. The driver test checks
the fixed length and digest of the bytes actually uploaded, including chunk
word addresses. No Bosch host driver code is linked or copied. nihos's Zig
protocol implementation follows the official BMI270 datasheet
BST-BMI270-DS000-08, sections 4.3–4.6 and 5.2.

Binary redistribution must include the BSD notice. Native normal images embed
this configuration in mapped Flash; firmware packages must accompany it with
this notice and LICENSE. Sensor axes have no board/display remapping.
