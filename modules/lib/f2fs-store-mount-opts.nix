# THE f2fs store mount options (STORAGE.md §4 recipe + OPTIMIZATIONS.md §3 flags).
# One list, two consumers — factored so they cannot drift:
#   * modules/boot/disk.nix          — the disko stick layout (image build + runtime fstab)
#   * modules/appliance/rescue-maintain.nix — re-mounting the rescue store on the running
#     main (hot mode); a bare mount would write new closures UNCOMPRESSED and blow the
#     stick budget (f2fs compression applies only to files created under these options).
# See disk.nix for the per-flag rationale (incl. the 8-char F2FS_EXTENSION_LEN trap).
[
  "compress_algorithm=zstd:22"
  "compress_log_size=2"
  "compress_extension=*"
  "compress_chksum"
  "nocompress_extension=sqlite"
  "flush_merge"
  "checkpoint_merge"
  "compress_cache"
  "fsync_mode=nobarrier"
  "noatime"
  "lazytime"
  "nodiscard"
]
