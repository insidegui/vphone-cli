# Studio Display XDR darwinOS

## Firmware evidence

The supplied Pallas response, dated 2026-10-27, identifies
`com.apple.MobileAsset.DarwinAccessoryUpdate.A3348`, `AppleDisplay18,1`,
`J427AP`, darwinOS 26.4 / `23E246`, release type `Darwin`.
The catalog retains its Apple CDN URL, 1,375,731,712-byte encrypted length
and Pallas archive key. The downloaded AEA SHA-256 is
`a628e50a9898bf24c77151877b6362cef54b189e87ce55c424b38a826d8c70f2`.
These are firmware metadata, not instructions embedded in the response.

This is a complete restore asset, not a SoftwareUpdate `payloadv2` OTA.
`AssetData/BuildManifest.plist` names the `j427ap` erase identity, variant
`Darwin Customer Install`, `Ap,SDKPlatform=iphoneos`, and
`Ap,OSEnvironment=0x05`. Its SHA-256 is
`91e186fe144f8566b7109820151be61178dc39534038c750e41eb9643bc28a9d`.
Extraction yields 71 regular restore files, satisfying all 52 distinct
manifest paths. No prerequisite/donor iPhone or Apple TV IPSW is needed.

The OS image is `043-01536-378.dmg.aea`, already plain raw APFS despite its
suffix. Its original SHA-384 and those of its trust cache, root hash and
canonical metadata match the manifest. Detect encryption by bytes; do not
request a second AEA key based on the filename. For manual inspection,
`hdiutil attach -readonly -nobrowse -imagekey diskimage-class=CRawDiskImage`
recognizes this image. Always detach the inspection image afterwards.

## Implementation

`VPhoneDarwinRestoreArchive` streams the encrypted asset with the existing
native AppleArchive reader. It strips `AssetData/`, ignores archive link and
directory entries, rejects traversal, duplicate files and file/ancestor
collisions, checks every manifest-referenced file, and publishes extraction
with a same-volume rename. `VPhoneIPSWCache` recognizes both the catalog
source and renamed local assets by authenticated manifest contents, storing
remote assets under `ipsws/ota/`. Neither the source archive nor Pallas history
is rewritten.

Preparation merges this restore tree with cloudOS 26.4 (`23E5207q`), retaining
the native System image and J427 donor device tree while using the PCC
boot chain, kernel, SEP and virtual hardware. The display identity persists as
`AppleDisplay18,1`. The 1280×720 virtual framebuffer is a diagnostic canvas,
not an emulation of the physical XDR panel's timing or pixels.

The `darwinos` preset selects existing PCC boot/kernel patches, the donor's
board presentation, seputil/Gigalocker repair, the launchd cache-loader gate
and the dedicated `vphoned-darwinos` research agent. It leaves iOS UI,
activation, GPU injection, camera, audio, shared-cache and environment hooks
off. No new binary instruction patch is introduced. The installer rejects
guest patches outside this admitted set before disk work.

The full iOS agent cannot load: darwinOS lacks its strong UIKit,
AVFoundation and CoreLocation dependencies. The dedicated iOS-platform agent
uses Foundation, CryptoKit, IcliSystem, NIO and the existing native
VSOCK/process/session transport, without those UI frameworks. It supports
health, device information, files, processes, services, port forwarding,
native program execution and a JSON RPC terminal. The firmware has neither
`/bin/sh` nor JavaScriptCore; this terminal is not a Unix shell or JavaScript
REPL. Explicit native program sessions use a PTY. Launch-time agent updates
select the darwinOS binary from the machine's persisted device family.

Both CLI and Launchpad use standalone restoration, without iOS templates,
setup automation or slimming. The new catalog family, source format and
agent resource require the 2.14 Launchpad/bundle series.

## Creation and research boundary

Select Studio Display XDR in Launchpad, or use:

```zsh
vphone-cli vm create studio-display-xdr --device AppleDisplay18,1
```

The catalog supplies darwinOS and matching cloudOS sources. A local copy of
the supplied AEA can be passed as `--iphone-source`; this existing argument
names the userland source for every guest family. `--ota-source` remains the
separate SoftwareUpdate payload mechanism and is not used here.

The guest agent and forwarded IP ports provide a research path to services
that can operate on virtual network interfaces. The VM does not emulate the
display's physical USB gadget, NCM attachment, Thunderbolt/DisplayPort links,
DCP, camera or downstream controllers. Retaining a native launchd job does
not establish that its hardware-dependent transport is functional. Native
host communication over those controllers requires additional device models
or a separately verified transport adapter. See
[service evidence](studio_display_xdr_services.md).

## Validation

The actual AEA was downloaded, decrypted, inspected and extracted with the
production archive helper. Its image digests match the manifest. Archive
fixtures cover encryption, renamed local files, incomplete cache reuse,
traversal, duplicates, collisions and symlinks. Core/patch fixtures cover
device persistence, catalog source selection, monolithic layout admission and
preset isolation. Bundle admission also rejects unavailable UI dependencies
in `vphoned-darwinos`.

Validated on 2026-10-27 with four CPUs, 4 GiB memory and a 32 GB virtual disk:

- Native preparation completed against the supplied AEA and cloudOS 26.4,
  skipping GPU recovery. All nine boot components patched successfully,
  producing 194 records without an undeclared-patch warning.
- OpenAVB/OpenSEP DFU restore completed, including System volume sealing.
  CFW installation completed through Launchpad's existing verified-bundle
  helper. The first install exposed the monolithic cache path; the corrected
  family-based selection passed on retry without another restore.
- Three normal boots reached the dedicated agent; the first answered after
  three seconds. `device.info` reports `AppleDisplay18,1`, `os=darwinOS`,
  version 26.4, build `23E246`, kernel 25.4.0, four processors and the expected
  memory. Distinct boot-session UUIDs confirm separate boots. NAT DHCP works.
  The first boot answered again at 78 seconds; this is a smoke check, not
  long-duration stability validation.
- Native `remoted`, ConfigureUSB, corespeechd_darwin, darwinaudiod,
  darwincameracaptured, uarpd and uarpassetmanagerd were observed running.
  Hardware-conditioned display/controller services remain idle. This does
  not establish functional USB/NCM attachment or physical device protocols.
- A signed scratch echo program was uploaded, downloaded byte-identically,
  and launched with `proc.run`. A host WebSocket connected through
  `/v1/ports/39079` and received the exact guest TCP echo. `/v1/shell` opened
  the JSON RPC console and returned the display's native identity. The probe
  was removed afterwards.
- The complete VPhone bundle and Launchpad build through Xcode MCP. Bundle
  admission verifies signatures/platforms and rejects absent UI-framework
  dependencies. All 696 core and 118 archive tests passed; 143 selected
  firmware tests passed, with four unavailable reference fixtures skipped.
  File metadata, 34 native session checks, and Launchpad bundle-name,
  machine-identity and firmware-source harnesses passed.

The stopped research VM is
`~/.vphone/machines/studio-display-xdr-research`, bound to
`2.14.0-local.d653c513`. The previously selected default bundle and existing
machines were left unchanged. Evidence is under
`.build/studio-display-research/`: prepare/patch/restore/CFW logs, three boot
identities, process/service snapshots, file transfer and transport results.
The first normal boot's console is
`~/Library/Logs/vphone-launchpad/studio-display-xdr-research.log`; later boot
consoles are retained in the evidence directory.
