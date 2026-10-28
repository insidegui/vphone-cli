import ArgumentParser
import Darwin
import Foundation
import VPhoneCoreKit

struct VPhoneVirtualMachineSSHCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Open a key-authenticated SSH shell in a running Studio Display VM",
        discussion: "Uses this VM's private client key and pinned host key through its localhost/VSOCK forward. No guest UI or Irisin is required. An existing VM needs cfw update-environment from a bundle providing Studio Display SSH.",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Argument(parsing: .unconditionalRemaining, help: "Optional remote command and arguments") var command: [String] = []

    func run() throws {
        let name = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        guard bundle.manifest.guestDevice.family == .studioDisplay else {
            throw ValidationError("Automatic SSH is currently provided for Studio Display guests only.")
        }
        let socket = bundle.url.appendingPathComponent("vphone.sock").path
        guard FileManager.default.fileExists(atPath: socket) else {
            throw ValidationError("Start \(name) with vm launch first.")
        }
        var port: Int?
        var message = "SSH is not ready"
        for _ in 0..<30 {
            let reply = VPhoneHostAutomationProbe.send(["t": "ssh", "screen": false], socketPath: socket)
            if reply?["ok"] as? Bool == true,
               let result = reply?["result"] as? [String: Any], let value = result["port"] as? Int {
                port = value
                break
            }
            message = reply?["error"] as? String ?? "The VM is not answering"
            Thread.sleep(forTimeInterval: 1)
        }
        guard let port else { throw ValidationError(message) }
        let identity = try VPhoneSSHIdentity(machineIdentifier: bundle.manifest.machineIdentifier)
        _ = try identity.prepare()
        let arguments = try identity.arguments(port: port, command: command)
        let words = (["/usr/bin/ssh"] + arguments).map { strdup($0) }
        defer { words.forEach { free($0) } }
        var argv = words + [nil]
        execv("/usr/bin/ssh", &argv)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
