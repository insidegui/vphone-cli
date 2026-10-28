# Studio Display XDR services and research transport

Examined on 2026-10-27: AppleDisplay18,1 / J427AP, darwinOS 26.4,
23E246, from the supplied DarwinAccessoryUpdate.A3348 Pallas response.
The decrypted asset's complete restore tree is retained locally under
`.build/studio-display-research/restore`; the system image was mounted read-only
under `.build/studio-display-research/system`. No original executable was patched.

## Executable platform and daemon

The shipped `/sbin/launchd` has `LC_BUILD_VERSION platform=2` (iOS), minimum
and SDK version 26.4. This is consistent with the manifest's
`Ap,SDKPlatform=iphoneos`; it does not imply that iOS UI frameworks are present.
Its SHA-256 is
`0182ce62c230d37cc310d8961753d9ae043a7299a7bc99cbe1f9879cf2b20796`.

The system cache's image-path table includes Foundation, CoreFoundation,
CoreGraphics, Security, CryptoKit and the Swift runtime. UIKit, AVFoundation,
CoreLocation and JavaScriptCore do not appear in that table or in their framework
directories. The regular iOS vphoned strongly links the first three and therefore
cannot be used as this guest's daemon. This is a static dependency conclusion;
no execution of the regular daemon inside darwinOS was attempted.

`VPhoneDaemon/vphoned-darwinos` is a separate handwritten Xcode target. It links
Foundation/CoreFoundation/CryptoKit and the existing NIO/IcliSystem packages,
without IcliKit's UI dependencies. Its inspected linked images are all present
in the supplied system cache. It builds for iPhoneOS arm64 with minimum 26.4;
its undefined-symbol list does not contain `_swift_initBorrow`.

The target shares the existing HTTP wire format, bounded WebSocket frames,
loopback-only TCP forwarding, file upload/download and PTY session transport.
It listens on VSOCK 1339 and advertises only `files`, `port_forward`,
`device_info`, `processes`, `services` and `shell`. The common native proxy and
cached-update bootstrap preserve the daemon update protocol.

The default terminal accepts one JSON RPC request per line, for example:

```json
{"method":"device.info"}
{"method":"services.list"}
{"method":"proc.run","params":{"path":"/bin/ps","args":["aux"]}}
```

`.exit` closes it. `/v1/shell?program=/absolute/path` still starts a native
executable on a PTY. This firmware ships `/bin/ps` and `/bin/df`, but neither
`/bin/sh` nor JavaScriptCore; the terminal makes no shell or JavaScript claim.
An uploaded, appropriately signed research tool can also be executed directly.
The daemon offers no UI, application installation, touch, clipboard, camera,
location or package bootstrap API.

## Native host communication

The shipped launchd records describe these native services:

- `com.apple.darwin.ConfigureUSB` runs `/usr/libexec/ConfigureUSB` once at boot.
  REA analysis of that executable observes IOUSBDeviceController imports,
  the device-tree property `darwin-configuration-string`, the configuration
  string `muxNcmAux`, `/var/db/darwinos-enable-usb`, and boot argument
  `no_darwinos_disable_display`.
- `com.apple.remoted` publishes the `com.apple.remoted`, `.compute-platform`,
  `.control`, `.coredevice` and `.watchdog` Mach services. Its launch events
  match IOEthernetInterface children of AppleUSBNCMData and AppleUSBDeviceNCMData.
- `com.apple.appledisplayplatformd` publishes `com.apple.xpc.adp`, matches
  `AppleDisplayPlatformControl`, and declares the RemoteXPC services
  `com.apple.xpc.display.eacs`, `com.apple.xpc.remote.adp` and
  `com.apple.xpc.thermals`. The first two declare exposure to untrusted devices
  together with their entitlement requirements; those requirements are retained.
- `com.apple.corespeechd_darwin` declares the RemoteXPC control and record
  services `com.apple.corespeech.xpc.remote.control.darwin` and
  `com.apple.corespeech.xpc.remote.record.darwin`, both requiring
  `com.apple.private.corespeech.xpc.remote`.
- `com.apple.prodisplayd` is limited to the `dp865-spi` device-tree node;
  `com.apple.tconcontrold` is limited to `dp835-i2c`. Both publish
  `com.apple.tconcontrol` for different hardware. The virtual machine does
  not provide either physical display controller.
- UARP's `com.apple.uarpd` exposes asset-personalization and endpoint
  control/transport Mach services. These jobs remain part of Apple's system.

Runtime inspection with `remotectl` reports the booted guest on both NCM and
virtual-machine transports, connected and connectable, with its native
RemoteServices, `AppleDisplay18,1` / `J427AP` identity and `IsUIBuild=false`.
The virtual-machine transport works without a special host communication
emulator. These observations establish discovery and service publication;
they do not establish the behavior of every individual service or reproduce
physical Thunderbolt/DisplayPort timing and downstream hardware. The existing
guest TCP forwarding and process/service/file APIs provide additional inspection
tools. No entitlement bypass is added to the native RemoteXPC services.

REA ConfigureUSB evidence:
`ev_3b88e25c1537b73a09ef3289d7648dbeb645c3aeb1162700c6376b4451848a63`
(strings) and
`ev_9895ba5676dafcd9fc64e9220b4301f717250795f591750d66ba21cf0f25b5a6`
(import procedure names). ConfigureUSB SHA-256:
`e54228afe45a53f491afa5ab59a6564027639286b165923a52a165b92138f4e9`.
The RemoteXPC launch-record inventory is retained at
`.build/studio-display-research/remote-services.txt`.

## Existing system patches

Both checks below ran against private executable copies, with originals mounted
read-only. They establish static patch-site compatibility, not a successful boot.

The completed profile was subsequently restored and booted three times; see
[runtime validation](studio_display_xdr_support.md#validation). The runtime
service snapshot observes remoted, ConfigureUSB, darwinaudiod,
darwincameracaptured, corespeechd_darwin, uarpd and uarpassetmanagerd running.
The guest's IP/agent transport, file round trips, native program execution,
JSON RPC terminal and TCP tunnel were verified. Physical USB/NCM and
Thunderbolt attachment were not reproduced by these checks.

- `/usr/libexec/launchd_cache_loader`, SHA-256
  `7691a1a6c81081968beafdc3bd26fa48a6c5b644fbbb28724f3b2c5723928027`:
  `cfw patch-launchd-cache-loader` finds `launchd_unsecure_cache=`, follows its
  string reference to the local call, and replaces the following `cbz x0` gate
  at file offset `0xB58` with the encoder's NOP. The cache to be amended is
  `/System/Library/xpc/launchd.plist`, with a neighboring `.sig`.
- `/usr/libexec/seputil`, SHA-256
  `ca53faa5d5ca0843589d205f22dba8d97ddfd3ef8eb760939d467babd54c48b8`:
  `cfw patch-seputil` finds the referenced `%s/%s.gl` string and changes its
  second format placeholder to `AA`, producing `%s/AA.gl`. On this build the
  literal starts at file offset `0x1B458` and the changed bytes at `0x1B45B`.

The offsets above record this investigation only; production matching uses the
existing dynamic string/control-flow anchors and contains no new fixed offsets.

## Validation boundary

Xcode MCP successfully builds the dedicated iPhoneOS target. The native PTY and
proxy tests are shared with the existing daemon. The darwinOS file metadata
harness exercises actual temporary files, directories, directory symlinks and
dangling symlinks against the host files panel's wire contract. Integrated boot
and guest research transport were subsequently verified in the linked runtime
validation. Native `remotectl` also reports connected NCM and virtual-machine
entries for AppleDisplay18,1, with the shipped RemoteServices and
`IsUIBuild=false`; that observation is retained in
`.build/studio-display-research/native-remotectl-show.txt`. No additional host
communication emulator is needed for that working route. Physical display
controller behavior remains outside those checks. The VM does not currently
execute the native AppleTCONControl boot-animation path. Its prerequisites,
native completion signal and live boot-console mismatch are documented in
[native boot-animation investigation](studio_display_xdr_native_boot_animation.md).
