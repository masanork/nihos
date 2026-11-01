# xy portrait workspace: integration boundary

Home, document, reader, chapter list, settings, card, and SICP lesson scenes
have portrait rendering and input paths. The ordinary native workspace still
uses landscape; the explicit `NIHOS_NATIVE_XY_PORTRAIT=1` fixture selects
portrait across the xy session. This fixture requires `NIHOS_NATIVE_XY_WORKSPACE=1`
and `NIHOS_NATIVE_KEYBOARD_I2C=0`, and is not a physical keyboard probe or an
automatic orientation policy.

The Tab5 panel's physical RGB565 surface is 720 × 1280. The touch service
publishes landscape coordinates `(1279 - raw_y, raw_x)`; the portrait fixture
inverts them to `(landscape_y, 1279 - landscape_x)` before dispatch. Drawing,
layout, keyboard hit testing and gestures use the portrait geometry. The
four-row keyboard reserves the bottom 320 px, and lesson controls move above
it. Cancels clear the model's armed touch. The landscape route remains the
default.

Host tests exercise Home-to-document, all Home destinations, portrait reading
with contiguous UTF-8 and intact ruby across page boundaries in both text
axes, settings, contents, SICP example selection, lesson controls and model
input to code and notes. The device fixture requires physical validation;
host pixel equality and a successful image audit do not establish panel pixels,
physical touch operation, or usability.

Before enabling automatic selection based on the physical keyboard probe, use
one session orientation for every screen and input source; define how and when
orientation may change, cancel any active contact, invalidate the retained
frame, and preserve the reader position across reflow. Distinguish a verified
address NACK from I2C failure or an unsupported keyboard. Decide whether and
how to retry attachment without treating an error as a clean removal. The
ordinary boot, diagnostic controls, camera overlays, and transitions must be
checked alongside xy. Physical optical/touch checks on the exact candidate,
including both keyboard-present and confirmed-absent boots, remain required.
