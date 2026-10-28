# Pinned SSH and shell sources

Build.sh uses only these checked-in sources, Xcode and system build tools.
It performs no downloads. Runtime executables link only libSystem; crypto
libraries are statically built from Dropbear's bundled LibTomCrypt/LibTomMath.

## Dropbear 2026.94

- Upstream: https://matt.ucc.asn.au/dropbear/releases/dropbear-2026.94.tar.bz2
- Original SHA-256: `e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81`
- Detached signature verified with the upstream release key fingerprint
  `F734 7EF2 EE2E 07A2 6762 8CA9 4493 1494 F29C 6773`, retrieved from
  https://matt.ucc.asn.au/dropbear/releases/dropbear-key-2015.asc.
- The checked-in gzip archive is repacked from that release, omitting Python,
  fuzz, Debian packaging and Git metadata. Configure's test Makefile input is
  retained; no upstream test interpreter is invoked.
- Repacked SHA-256: `02f41ed244b3be507f60ed726475272b168f3b68acb90e9d7b16e9d9876c1282`
- License: Dropbear-LICENSE (includes bundled component notices).
- Changes are reviewable in ../dropbear-darwinos.patch and ../localoptions.h.

## dash 0.5.13.5

- Upstream: https://git.kernel.org/pub/scm/utils/dash/dash.git/snapshot/dash-0.5.13.5.tar.gz
- Original SHA-256: `53622e51df0fd7a2950552cfe0da0bee9bfc1510784e752b62eacc49b3776d33`
- Configure/Makefile inputs were generated once with upstream autogen.sh using
  Autoconf 2.73 and Automake 1.17. The generated files are included so ordinary
  bundle builds do not require Homebrew or autotools. Autom4te caches and backup
  files were omitted.
- Repacked SHA-256: `3c9937b84a1ca94cc172c0bd32ecd493501bfc9a944f430eb74204662907c657`
- License: Dash-COPYING. The upstream per-file notices remain in the archive.
- The native fork bridge is applied through ../dash-darwinos.patch; shell
  parsing, expansion, pipelines, job control and execution remain upstream code.

The native bridge resolves libSystem's fork at runtime because the application
SDK disallows naming it directly. It is built into each executable, not injected
into system processes. No system shell, account file or Apple display path is
replaced.

## Toybox 0.8.15

- Upstream: https://landley.net/toybox/downloads/toybox-0.8.15.tar.gz
- Original SHA-256: `44e2bab43dfe2c171743297631ce558c6d9ed38b87a66fd751cef617574b375e`
- Repacked SHA-256: `52940ae848426a57e43a883405a8a0ccae74c8b2db2bec36c54954575582b681`
- The checked-in archive omits Python and GitHub metadata. No upstream test
  interpreter is invoked. License: Toybox-LICENSE (0BSD).
- `../toybox_miniconfig` selects the Darwin-portable file/text/process utilities,
  plus awk, tr and vi. Setuid support, optional external crypto/zlib libraries
  and recursive in-process command dispatch are disabled. Apple tools keep
  precedence in PATH.
- `../BuildTools.sh` builds upstream's host prerequisite tool using Xcode, then
  cross-compiles the guest binary. Only `sys/disk.h` is borrowed from the selected
  macOS SDK; the remaining headers and the sole library (libSystem) are iPhoneOS.
- `../toybox-darwinos.patch` disables optional library discovery, corrects the
  block-size ioctl buffer types to the Darwin ABI, and routes awk's system/pipe
  execution through upstream's fork/exec/wait helpers using our installed dash.
  It does not add a shell interpreter or replace Apple binaries.
