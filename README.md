# nihos

> 素のハードウェアを、色づける。

**nihos** is an experimental, small, educational operating system for the
M5Stack Tab5 and its ESP32-P4. It is intended to explore a readable Zig-first
system that uses the hardware well without hiding the important mechanisms
behind a large framework.

The project is at the design and bootstrap stage. It does not boot yet.

## Name

The name is pronounced **ニホス**. It comes from the classical Japanese verb
「にほす（匂す）」—to dye or give colour—and ends naturally in `os` when its
final `u` is removed for the project name.

The older sense is visual rather than merely olfactory: to make something
take on colour or radiance. That is the intent here—to make bare hardware
expressive while keeping the machinery visible to the reader.

## Direction

- Use Zig for the core where it produces clear, inspectable machine code.
- Keep C and assembly boundaries small and explicit where the vendor SDK,
  boot path, or hardware support requires them.
- Use both ESP32-P4 cores deliberately, with measured SMP costs and benefits.
- Prefer low overhead and simple invariants over server-grade security
  machinery, while using static analysis and hardware isolation where useful.
- Treat graphics and input latency as first-class concerns; Quake near 60 FPS
  is a performance target, not a current claim.
- Keep the source readable enough to serve as an operating-systems text.
- Choose the flash filesystem from measurements and failure tests rather than
  assuming m5fs, littlefs, or another design in advance.

## Project boundary

nihos is a new, independent project. It is not MeOS and is not presented as a
work by MeOS author shi3z.

No MeOS source code is included in this initial repository. Any future reuse
of a HAL, driver, or other implementation must first have a verified license
or explicit permission, preserve attribution, and document the imported
boundary and modifications.

## Repository policy

- The repository is public from its first commit.
- No hosted CI workflow is enabled yet. Checks will be added only when they
  provide useful signal for the implementation that exists.
- Hardware claims require measurements on a physical Tab5; host builds and
  simulators will be reported separately.

## License

Original nihos code and documentation are available under the
[MIT License](LICENSE) unless otherwise noted. Third-party components, if
introduced, will retain their own licenses and notices.
