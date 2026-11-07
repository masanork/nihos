# MeOS GPUI clipboard on macOS

An interactive macOS check used the experimental MeOS GPUI window built from
source `bf4a8500b44adb070ac0a960221987dc70b82f41`, before a metrics-only
rebase. The app binary SHA-256 was
`1274c51fd7717731deac65fe6bda87e748e41ef263742bd061e656d6844c56f0`.
The pinned MeOS app image SHA-256 was
`2802acccea64410dee3e0caea5fd683d499a84b5818d76682580730ee7a1f09a`;
the ROM ELF SHA-256 was
`948f2c7d108d04a9c3a982f9c1c498fb17f2c4a68abc51f87782592034d7ce44`.

In the live window, a system clipboard paste opened `edit /paste-test.txt`.
A second paste entered `alpha 日本語` and `second line` on separate lines.
Control-S saved, Control-Q returned to the shell, and `cat /paste-test.txt`
displayed both lines. The guest filesystem was a volatile RAM disk.

This verifies the macOS window and clipboard path with this fixture, not the
Linux shortcut, a physical Tab5, persistence across resets, or arbitrary MeOS
images. The feature-enabled host suite also passed 108 tests on this source.
