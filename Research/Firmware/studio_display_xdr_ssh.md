# Studio Display SSH access

The `darwinos` preset installs a native Dropbear SSH server and dash POSIX
shell, without Irisin or any guest UI. Start a Studio Display VM normally, then
run `vphone-cli vm ssh <name>`. A trailing command runs noninteractively, for
example `vphone-cli vm ssh <name> 'printf hello'`. The command waits up to 30
seconds for SSH provisioning during boot and invokes the Mac's `/usr/bin/ssh`.

An existing machine needs `cfw update-environment` with the new bundle before
the next boot. Merely updating vphoned does not install the server or shell.
The new declaration `system-ssh-exp-studio_display` is enabled only by the
darwinOS preset on 26.4. Blocking it and updating the environment removes the
three native binaries and launchd job; its private Data-volume credentials are
retained for reuse. Other shipped presets leave it off.

## Transport and authentication

Dropbear listens on guest `127.0.0.1:2222`. On agent connection the VM process
offers a generated Ed25519 client public key over the existing VSOCK control
channel. The guest generates its own Ed25519 host key, prepares authorized_keys,
and starts `com.vphone.sshd`. The launchd job subsequently restarts it as needed.
No password/PAM authentication, forwarding or agent forwarding is compiled in;
only the root account is admitted. The dedicated shell is
`/usr/local/libexec/vphone-ssh/sh`; native account databases are left intact.

The host binds an ephemeral TCP port on `127.0.0.1` and forwards opaque SSH
bytes through vphoned's existing `/v1/ports/2222` WebSocket over VSOCK. The
guest NIC is not used. The listener closes with the VM/control connection;
the existing manifest port forwards remain separate. The SSH command queries
the live port through `vphone.sock`, so concurrent VMs need no fixed host port.

Client keys and pinned known_hosts live in private directories under
`~/.vphone/ssh/<SHA256(machineIdentifier)>` (or `$VPHONE_ROOT/ssh`). They are
credentials, kept outside shareable VM directories and exports, with directories
0700 and private files 0600. These permissions are intentional exceptions to
the workstation artifact policy: SSH credentials are not shared image/cache
artifacts. Reconnects and renames preserve them. `--new-identity` clones get a
different key; a guest seeing a different authorized client key regenerates
its host key. A backup clone retaining the same machine identity retains the
same host credentials, like its other device identity.

The guest host key is delivered over the VM's own VSOCK connection and pinned
before the localhost listener opens. The system SSH client runs with strict
host checking, this VM's key only, no agent, and a dedicated known_hosts file.
It does not disable host verification or modify the user's SSH configuration.
Guest credentials are root-only under `/private/var/db/vphone-ssh`. Server logs
go to `/private/var/log/vphone-ssh.log`.

## Components and compatibility

The build compiles pinned upstream Dropbear and dash sources with Xcode's
iPhoneOS SDK for arm64e / iOS 26.4. They link only libSystem, which darwinOS
ships. Dropbear uses its bundled static crypto implementations. Licensing and
source provenance are retained beside the source archives and shipped with the
guest resources. No interpreter, Homebrew library, network download or package
manager is needed at runtime.

The darwinOS port resolves libSystem's native fork export, since the iPhoneOS
SDK marks it unavailable to applications. It uses a full fork for dash's vfork
optimization too. Dropbear's only authentication adaptation selects its own
installed shell rather than changing `/etc/passwd` or `/etc/shells`. SSH protocol,
key verification, PTY modes, terminal sizing, signals and command execution
remain upstream implementations. This supplies a shell, not a complete Unix
utilities distribution; SFTP and package installation are outside this payload.

## Validation (2026-10-28)

Xcode built and admitted the complete `VPhone.bundle`. Its guest executables
are signed arm64e iPhoneOS Mach-O files, with libSystem as their only dynamic
dependency. The 663 CoreKit tests pass, including credential persistence,
machine isolation, private permissions, malformed-key rejection and symlink
confinement. The firmware catalogue, selection, declaration, plan, gate,
version and daemon-rewrite suites pass. The broader firmware run has 131
failures requiring absent local reference binaries (plus 68 skips); these are
not SSH validation results.

The existing Studio Display research VM was updated through Launchpad's
verified-bundle helper and booted with `--headless` and `network=none`, with
no Irisin or UI steps. The installed `com.vphone.sshd` job runs the server;
the host's only SSH listener is `127.0.0.1` on its assigned port. Verified:

- `vm ssh` authenticates automatically and executes dash arithmetic, loops,
  pipelines, native `/bin/ps` and `/bin/df`. Remote `exit 37` returns 37.
- An interactive login gets a real PTY, Ctrl-C interrupts a shell loop, and
  interactive `exit 19` returns 19.
- Unrelated client keys fail. The server offers only `publickey` authentication.
  A substituted pinned host key fails strict host verification.
- A 699,053-byte stdin/stdout round trip compares byte-identically through
  the SSH/VSOCK bridge.
- Four concurrent sessions complete independently.
- Blocking the declaration and updating the environment removes the binaries,
  launchd job and advertised endpoint. The native research agent still answers.
  Re-enabling it and updating again restores automatic SSH at the next boot.
  The client key and pinned host key remain byte-identical across this cycle;
  the new ephemeral port is discovered automatically. The original NAT setting
  was restored and the research VM was left stopped.

The source configuration uses upstream's session-time account switch because
Darwin has no `setresgid` for Dropbear's early privilege-drop mode. Root-only
admission is enforced independently. The guest ships few external utilities;
for example `sleep` is absent. Shell builtins and the programs actually present
in the guest remain available; this payload does not claim a full Unix tools
installation.
