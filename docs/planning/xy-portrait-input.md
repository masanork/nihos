# xy portrait document: integration boundary

The portrait Home and document geometry and host rendering/input tests are prepared,
but the native workspace still displays and consumes touch in landscape. No
automatic orientation switch is enabled by this change.

The Tab5 panel's physical RGB565 surface is 720 × 1280. The existing touch
service publishes landscape coordinates `(1279 - raw_y, raw_x)`. A portrait
consumer must invert this mapping to `(landscape_y, 1279 - landscape_x)` and
must use the same selected orientation for drawing, layout, hit testing and
gesture recognition. The prepared keyboard geometry is 720 × 1280, with four
80 px rows at the bottom. The document renderer reserves that dock above its
status line; hiding the keyboard restores that space. The landscape geometry
and routing stay as before.

Before enabling selection based on a physical keyboard probe, the foreground
owner must propagate a single orientation through display and input, cancel an
active touch when it changes, invalidate the retained frame, and ensure the
screen's renderer and hit testing use the same geometry. The portrait Home prototype shares card geometry with hit testing and can open
the portrait document in the host model; its renderer request is not selected
by the native session. Reader, settings, learning, system views, diagnostic
controls and transitions still rely on landscape coordinates. They must be
adapted and tested before a session-wide
portrait default is enabled. A keyboard I2C failure is not proof of a clean
physical detach; define unknown/fault and any retry policy separately rather
than silently rotating on an error.

Acceptance includes both orientations' corner and key hit testing, drag/cancel
and hide/show gestures, document and minibuffer entry with a visible cursor,
Home-to-document and back, reader/settings navigation, physical keyboard
startup and failure paths, redraw on orientation transitions, native image and
memory audits, and physical Tab5 optical/touch checks on the exact candidate.
Host pixel equality and layout tests do not establish panel scanout, touch
controller behavior or usability on the device.
