# Running the original AppleTCONControl boot animation

Investigation: 2026-10-27, AppleDisplay18,1 / J427AP, darwinOS 26.4 / 23E246.
This records requirements for executing Apple's original machine code. No
replacement renderer, kernel patch, driver transplant, device-tree change or
display write was implemented. The unchanged research VM was booted for
read-only registry inspection; firmware images were inspected read-only.

The original animation is kernel code. Enabling its launch daemon or copying
its frames does not execute it. The current guest runs the PCC VRESEARCH1
kernel, which lacks AppleTCONControl and its GPIO dependency. Running the
unchanged driver requires bringing those native drivers and their provider
contracts into that kernel, establishing a compatible boot framebuffer, and
supporting the native stop path. The drawing methods themselves use CPU
stores and kernel timers; the evidence does not establish that a complete
physical display controller is necessary just to execute those methods.

## Native path and current VM

| Requirement | Native implementation | Current VM observation |
| --- | --- | --- |
| Driver code | `com.apple.driver.AppleTCONControl`, version 70, arm64e, boot-required | Not present in PCC fileset; no registered class or service in the live registry |
| Matching provider | `IOService` named/compatible `gpio,tcon`, probe score 20000 | No corresponding provider |
| GPIO support | `AppleGPIOICController`, typed platform-function objects, interrupt source | Controller absent from PCC collection and live registry |
| Boot framebuffer | IOPlatformExpert console info, 32-bit physical memory, kernel mapping | Live `PE_Video` is 640×1136, 32-bit; continuing scanout remains unverified |
| VM graphics | Native source uses direct boot-console pixel stores | `AppleParavirtDisplay` active, 1280×720; this is a different presentation contract |
| Normal completion | `prodisplayd` opens native hardware clients, then sends selector 5 | Daemon not loaded; its launch gate and required endpoints are absent |

Runtime evidence is the complete output of the guest's shipped
`/usr/sbin/ioreg`, not an uploaded inspection helper:
`.build/studio-display-research/tcon-runtime-ioservice.txt` and
`tcon-runtime-devicetree.txt`. The IOService snapshot has 262 nodes, one
AppleParavirtDisplay and no AppleTCONControl, AppleGPIOICController or AppleSMC
service. The loaded class dictionary reports zero AppleSMC and
IOAVDisplayMemory instances. No `dp865-spi`, `cpld-tcon-usr`, `tcon-api` or
`tcon-registers` node appears. `services.status` reports `com.apple.prodisplayd`
not loaded. Native RemoteXPC discovery works independently of these services.

The DT's `vram@70080000` node describes physical address `0x170080000`, length
`0x854000`. Read-only kernel inspection independently recovered the native
console record:

| PE_Video field | Live value |
| --- | --- |
| `v_baseAddr` | `0x170080000` |
| `v_rowBytes` | 2560 |
| `v_width`, `v_height` | 640, 1136 |
| `v_depth` | 32 |
| `v_offset`, `v_length` | 0, 0 (native code derives the length) |
| `v_rotate`, `v_scale` | 0, 3 |

This satisfies the native code's depth and tightly packed row-size checks,
but does not prove that writes update the current virtual display. The active
paravirtual display reports 1280×720, matching the VM configuration, so its
geometry differs from the boot console. Boot logging shows
`serial=3 -v debug=0x2014e`, without `-progress` or `-restore`.

## Gates before any animation runs

The semantic `AppleTCONControl::start` entry is `0xfffffe0009485858` in the
original J427 collection. The driver first starts its superclass and resolves
board functions. Failure to instantiate `function-lpdp_sel` makes start return
false. `function-tcon_sysctrl` and `function-soc-dp-enable` can log failures and
continue; the original J427 DT itself omits `function-tcon_sysctrl`.

The driver then requires allocation of an interrupt source and a GPIO handle
array. It looks up `AppleGPIOICController` using an indefinite matching-service
wait before reaching animation setup. With no such published controller,
adding only a TCON DT node can leave it waiting. The resolved GPIO function is
a dynamically cast native object; a property with the right name alone is
insufficient.

The original `/arm-io/tcon` provider carries `compatible="gpio,tcon"`,
`function-lpdp_sel`, `function-soc-dp-enable`, `function-psu-burst-disable`, and
an interrupt sourced from GPIO. Its GPIO controller is compatible
`gpio,t8101`, with 224 pins, seven interrupt groups and a register range.
The function payloads reference this controller. Loading the real controller
therefore also requires its platform functions, memory/interrupt semantics
and kernel dependencies. The existing PV=3 configuration supplies paravirtual
graphics and other virtual devices; it supplies none of this TCON/GPIO setup.

`/arm-io/spi3/dp865-spi` is a separate provider. It binds
AppleParadeDP865TCONSPI from `com.apple.driver.AppleDPDisplayTCON` and exposes
`tcon-registers` and `tcon-api` children. It is the `prodisplayd` launch gate,
not AppleTCONControl's direct provider. These two DT requirements must not be
conflated.

After those startup gates, `-progress` skips animation initialization. Normal
initialization creates two IOTimerEventSources, obtains and maps the console,
clears it, and schedules the first frame immediately. Mapping or timer failure
can leave driver start successful with no animation. `-restore` selects a
different native rendering path and omits the normal timeout; it is not a
general way to enable normal boot animation.

## What the original rendering code expects

The driver embeds a `PE_Video` in its object. It calls the platform expert's
`getConsoleInfo`, rejects depths other than 32, and maps the reported physical
framebuffer through IOMemoryDescriptor into the kernel. It then calls
`setConsoleInfo` with graphics/acquire-screen operations. Public XNU source
correlation is in `Research/Reference/xnu/iokit/Kernel/IOPlatformExpert.cpp`
and `pexpert/arm/pe_init.c`; this checkout is xnu-12377.1.9, commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`, not the exact PCC or J427 source.

The normal callback calls the original draw routine and blitter, updates the
frame index and rearms its kernel timer. Those methods do not issue SPI/TCON
commands, create IOSurfaces, submit IOMobileFramebuffer swaps or power on a
display. A usable buffer must already be scanned out. Successful userspace
IOMFB presentation in the earlier, removed renderer does not establish that
this physical-console path works.

Important buffer constraints from the actual instructions:

- Mapping length uses `v_length`, or page-rounded `v_rowBytes × v_height`.
- Drawing advances by `v_width × 4`, rather than respecting arbitrary row
  padding. A compatible tightly packed 32-bit layout must be established.
- The mapped base plus `v_offset`, dimensions and rotation must be valid.
- The normal path centers and rotates the source pixels. It does not read
  `v_scale`, magnify or interpolate. The fourteen 120×120 source frames have
  an 88×16 nonblack indicator footprint. Native downstream panel/display
  scaling was not recovered; those bytes alone do not establish the final
  physical presentation or appropriate virtual screen resolution.

The normal intro uses 100 ms delays, then loops frames 6–13 at 200 ms, with a
native 180,000 ms fallback timer. The exact scheduling chooses the delay from
the next frame index, so the final intro frame is already held for 200 ms.
The stop operation cancels/releases timers and clears the console; a later
cleanup releases its mapping and console ownership. It does not contain the
removed helper's IOMFB display-power-off operation.

## What actually stops it on J427

In the shipped `prodisplayd`, `_main` synchronously calls the stop-containing
routine at `0x100002448`. That routine sends
`IOConnectCallMethod(connection, 5, ...)` at `0x100047b60`. It runs after
J427Platform construction, TCON configuration and a bounded port-coaching
phase, before the daemon finishes registering its listeners and enters its
main dispatch queue. It is not a vphoned-ready event or a generic OS boot
completion notification.

Coaching reads AppleSMC key `D1St` and tests bit 4. If clear, it requests port
guide graphics with TCON selector 7 and polls the key once per second until
the bit sets or `coaching-time` expires. A timeout proceeds to the stop call;
a failed SMC read throws. The precise hardware meaning of bit 4 and the
default coaching interval remain unresolved. A separate boot-complete IRQ
handler exists; it is not the identified direct caller of the stop routine.

J427Platform construction must first open an AppleTCONControl user client,
AppleSMC, IOAVDisplayMemory endpoints named `tcon-api` and `tcon-registers`, and
the `cpld-tcon-usr` client. Missing endpoints can abort startup before selector
5. Merely removing launchd's `dp865-spi` gate cannot reproduce completion.
If only animation code is brought up, the native three-minute fallback can
still end it, but that would not establish native early completion.

## Kernel loading and feasible research boundaries

The native J427 payload is `RELEASE_ARM64_T8150`,
`xnu-12377.102.10~3`. The actual PCC payload used by this VM is
`RELEASE_ARM64_VRESEARCH1`, `xnu-12377.100.591.502.1~2`. The latter's filename
contains `research.vphone600`; that name must not be used to substitute a
different vphone600 release symbol map. Matching the marketing version 26.4
does not establish identical private C++ ABIs, virtual tables or linked targets.

AppleTCONControl is a prelinked MH_FILESET image, not an independently loadable
driver bundle. Its declared dependency is AppleGPIOICController >=1.0, but its
linked instructions also call kernel services. Import targets, PC-relative
references, metaclass registration, resource references, authenticated
callbacks/vtables and collection fixups must be rebound correctly. Copying
the nested image or its executable section cannot satisfy these requirements.
The existing KDK recovery machinery resolved 551 foreign reference sites in
TCON to 234 distinct native-collection targets: 230 in the kernel, three in
GPIO and one in AppleARMPlatform. These include vtable/data references as
well as calls; they are not 234 named public imports. The recovered TCON and
user-client vtables contain 168 and 186 authenticated, address-diversified
slots respectively. Source reference recovery succeeded, but positional
recovered names do not establish equivalent PCC bindings or ABI compatibility.

The repository's KDK exporter, fixup recovery and kmutil collection builder
are relevant tools. A new recipe would need the actual PCC research base and
J427 donor, a verified cross-kernel target map, preserved PAC metadata and
successful extraction/relink round trips before boot testing. Existing recipe
selection does not describe this Studio Display graft. There is no completed
J427-to-PCC transplant established here.

Two distinct projects could execute original Apple rendering instructions:

1. **Load the full driver with its lifecycle intact.** Rebuild a compatible
   PCC collection containing the native driver and required dependencies,
   satisfy its typed GPIO/provider/interrupt contracts, and provide the console
   mapping and scanout it expects. Supporting the stock early-stop path also
   requires the additional native `prodisplayd` endpoints and their behavior.
2. **Adapt startup around the original animation machine code.** Preserve the
   original draw/blitter/timer code and resources, supply its exact kernel
   object layout, workloop, callbacks and framebuffer contract, and handle
   relocation/PAC. This is a modified native kernel-code path, not an unchanged
   driver or a proven design. It avoids assuming that all unrelated physical
   TCON controls must be virtualized just to perform CPU pixel stores.

Neither project was implemented. Booting the full T8150 kernel instead is
broader still: its SoC platform, interrupt, storage and display drivers do not
become compatible with the PV=3 hardware merely by changing product identity.
No attempt to boot that kernel was made.

The next useful experiment is to verify the existing native boot-console
memory/scanout lifecycle using the now-resolved `PE_Video`. Its nonzero
physical address, valid layout and simultaneous AppleParavirtDisplay service
are insufficient evidence of continuing scanout after handoff. Then
establish the donor-to-PCC link/ABI map before attempting any transplant.
Normal completion must be tested through the recovered native selector-5
path, separately from the fallback timeout. These are proposed follow-up
experiments, not completed validation.

## Evidence and remaining limits

All addresses above identify the examined J427 payload or `prodisplayd`, not
production patch constants. Static tracing establishes what these binaries
do; it does not establish execution of AppleTCONControl in the VM.

| Artifact | SHA-256 |
| --- | --- |
| Original J427 IM4P | `e5ca80b314dd82850c14e7d0127d15580016c5247fc18f8f1b5494cacdf8ce57` |
| J427 unwrapped kernel | `a833028d02f88de5b9ed0153f91514ca34495ad473a5a1c079d9727479d784ab` |
| PCC original unwrapped kernel | `86895a2eebeb7fcfb68bcd60f2d7e685687faea07ee31166fb58c872b38e0d92` |
| J427 unwrapped DT | `261f18d116425c5d19f11c6731941ac9ad9ca3f7bc125d53c8824a9f891f8a71` |
| Native prodisplayd | `c0eb366586dc91064229f780169929389294ec58117bc717172089b9402bfbdc` |

Detailed static ledgers are under `.build/studio-display-research/`:
`tcon-native-driver-requirements.md`, `tcon-native-stop-requirements.md`,
`tcon-native-stop-evidence.json`, parsed native DT/prelink metadata and the
cached AppleTCONControl disassembly. The stop ledger retains REA Evidence
IDs including `ev_812e21e5aa5bada0acd32b4d2df441377558ce347cc7aff66c30430b89af69e0`
for `_main`, `ev_60f59ad963d06aef2344fc7932519aa78d4db21ea9792852bb93efbd5e1cd176`
for the selector-5 path, and
`ev_c10d965b288a5e0835de8a5e5fb449f80e8e53cdb1e5ab4bc31010e469fa66c0`
for coaching. Hopper's incomplete indirect-reference and function-boundary
coverage remains a limitation; startup error handling was cross-checked
against the native instructions.

Native J427 code landmarks, semantically identified because its nlist symbols
are stripped:

| Role | Unslid J427 address |
| --- | --- |
| Driver start | `0xfffffe0009485858` |
| Frame timer callback | `0xfffffe000948607c` |
| Fallback timeout callback | `0xfffffe000948618c` |
| Obtain console info | `0xfffffe00094861bc` |
| Map/acquire console | `0xfffffe0009486220` |
| Physical memory mapping helper | `0xfffffe0009487ce4` |
| Normal frame draw | `0xfffffe0009487a14` |
| Rotated gray-to-RGB blitter | `0xfffffe0009487b9c` |
| Animation resource header | `0xfffffe00076000a8` |
| Stop callback | `0xfffffe00094868a8` |
| Release console/mapping | `0xfffffe0009486b08` |

The actual PCC kernel has no nlist symbols. IOPlatformExpert's parsed vtable
slot 187 (`+0x5d8`) points to unslid `0xfffffe000943110c`, a 56-byte routine
copying 0x90 bytes from `0xfffffe00077b6228` to its second argument and returning
zero. Its vtable placement, signature and copy match XNU's
`getConsoleInfo` / `PE_current_console`. Reading that global in the live kernel
confirmed the console record above, independently corroborated by the
`boot_args.Video` fields. This is source-correlated recovery, not an exported
symbol lookup.

The live AP debugger reported kernel UUID
`784F88D3-2AF5-3D4A-AB00-365607646E44`, matching the examined PCC image. Its
kernel-header load address was `0xfffffe0035690000`, preferred kernel address
`0xfffffe0007008000`, slide `0x2e688000`; the enclosing fileset header has a
different preferred address and must not be used for that subtraction. The
verified live console global was `0xfffffe0035e3e228`. The native method's
live instruction words matched the static copy routine. Read logs are
`tcon-live-console-verified-read.txt` and `tcon-live-boot-video-read.txt`.
Only debugger reads were issued and the process was detached afterward;
no functions were invoked, breakpoints installed, or memory/register writes
performed. This establishes the console record, not that its pixel stores
would be visible to the host after graphics handoff.
