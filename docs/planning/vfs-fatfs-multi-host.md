# Writable FatFs multi-client host fixture

This experiment runs the host-only multi-writer VFS service over FatFs R0.16
with the existing `NIHOS_FIXTURE_WRITER` configuration and host image driver.
The fixture creates a private temporary directory and a new 16 MiB image,
formats it, and creates two files. Two independently bound clients open and
write different files. A conflicting open of the first file is rejected before
it reaches FatFs. The clients sync and close their files; FatFs is unmounted,
remounted on the same host image, and both contents are read back.

Run `sh tools/check-vfs-fatfs-multi-host.sh`. It verifies pinned FatFs inputs
through the existing bootstrap and runs Debug and ReleaseSafe. The regular
read-only backend and native disk driver are unchanged; the writable fixture
uses a separate C adapter, fixed path-to-identity mapping and host-only disk.

This proves a bounded serialized host path through VFS, FatFs and host file
sync. It does not establish native task integration, safe general path identity,
concurrent raw sqld/FAT ownership, FAT recovery, physical SD behavior or power
loss safety. Failure injection, media removal and production admission remain
separate work. The image is destroyed after the test; this is not a device tool.
