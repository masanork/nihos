/* Host-only conformance probe. Upstream sources retain their own notices. */
#ifndef NIHOS_FATFS_PROBE_CONFIG
#define NIHOS_FATFS_PROBE_CONFIG
#define FFCONF_DEF 80386
#ifdef NIHOS_FIXTURE_WRITER
#define FF_FS_READONLY 0
#define FF_USE_MKFS 1
#define FF_USE_EXPAND 1
#define FF_FS_LOCK 16
#else
#define FF_FS_READONLY 1
#define FF_USE_MKFS 0
#define FF_USE_EXPAND 0
#define FF_FS_LOCK 0
#endif
#define FF_FS_MINIMIZE 0
#define FF_USE_FIND 0
#define FF_USE_FASTSEEK 0
#define FF_USE_CHMOD 0
#define FF_USE_LABEL 0
#define FF_USE_FORWARD 0
#define FF_USE_STRFUNC 0
#define FF_PRINT_LLI 0
#define FF_PRINT_FLOAT 0
#define FF_STRF_ENCODE 0
#define FF_CODE_PAGE 437
#define FF_USE_LFN 2
#define FF_MAX_LFN 255
#define FF_LFN_UNICODE 2
#define FF_LFN_BUF 765
#define FF_SFN_BUF 34
#define FF_FS_RPATH 0
#define FF_PATH_DEPTH 8
#define FF_VOLUMES 1
#define FF_STR_VOLUME_ID 0
#define FF_MULTI_PARTITION 0
#define FF_MIN_SS 512
#define FF_MAX_SS 512
#define FF_LBA64 1
#define FF_MIN_GPT 0x10000000
#define FF_USE_TRIM 0
#define FF_FS_TINY 0
#define FF_FS_EXFAT 1
#define FF_FS_NORTC 1
#define FF_NORTC_MON 1
#define FF_NORTC_MDAY 1
#define FF_NORTC_YEAR 2026
#define FF_FS_CRTIME 0
#define FF_FS_NOFSINFO 0
#define FF_FS_REENTRANT 0
#define FF_FS_TIMEOUT 1000
#endif
