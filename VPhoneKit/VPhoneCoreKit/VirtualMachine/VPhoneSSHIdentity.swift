import CryptoKit
import Darwin
import Foundation

/// Host credentials are private per-user files, outside the workstation's
/// shareable VM folders/archives. The stable machine identifier survives rename;
/// a clone with --new-identity automatically gets different SSH credentials.
public struct VPhoneSSHIdentity: Sendable {
    public let identifier: String
    public let directory: URL
    public var privateKey: URL { directory.appendingPathComponent("id_ed25519") }
    public var knownHosts: URL { directory.appendingPathComponent("known_hosts") }
    public var hostAlias: String { "vphone-\(identifier)" }

    public init(machineIdentifier: Data, root: URL = VPhoneResources.userDataRoot().appendingPathComponent("ssh")) throws {
        guard !machineIdentifier.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        identifier = SHA256.hash(data: machineIdentifier).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let base = try VPhoneConfinedDirectory(root: root.path)
        var info = stat()
        guard fstat(base.descriptor, &info) == 0, info.st_uid == geteuid(),
              fchmod(base.descriptor, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let pinned = try base.directory(identifier, create: true, mode: 0o700)
        guard fstat(pinned.descriptor, &info) == 0, info.st_uid == geteuid(),
              fchmod(pinned.descriptor, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        directory = URL(fileURLWithPath: try pinned.path, isDirectory: true)
    }

    public func prepare() throws -> String {
        let pinned = try VPhoneConfinedDirectory(root: directory.path)
        guard flock(pinned.descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(pinned.descriptor, LOCK_UN) }
        if try !pinned.exists("id_ed25519") {
            // ssh-keygen creates the OpenSSH private-key format and mode 0600.
            let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                ["-q", "-t", "ed25519", "-N", "", "-C", hostAlias, "-f", privateKey.path])
            guard result.succeeded else { throw IdentityError.failed(result.stderr) }
        }
        let key = try pinned.openRegularFile("id_ed25519", requireOwner: geteuid(), requireSingleLink: true)
        guard fchmod(key.descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        // Derive instead of trusting a stale or substituted .pub file.
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            ["-y", "-f", privateKey.path])
        guard result.succeeded else { throw IdentityError.failed(result.stderr) }
        return try Self.publicKey(result.stdout)
    }

    public static func publicKey(_ line: String) throws -> String {
        let words = line.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2, words[0] == "ssh-ed25519", words[1].count < 256,
              let blob = Data(base64Encoded: String(words[1])), blob.count == 51,
              blob.prefix(19) == Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]) else {
            throw IdentityError.failed("Expected one Ed25519 SSH public key")
        }
        return "ssh-ed25519 \(words[1])"
    }

    public func trust(hostKey: String) throws {
        let key = try Self.publicKey(hostKey)
        let pinned = try VPhoneConfinedDirectory(root: directory.path)
        try pinned.writeFile("known_hosts", contents: Data("\(hostAlias) \(key)\n".utf8), mode: 0o600)
    }

    public func arguments(port: Int, command: [String] = []) throws -> [String] {
        guard (1...65535).contains(port) else { throw IdentityError.failed("Invalid SSH forward port") }
        let hostsPath = knownHosts.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return ["-F", "/dev/null", "-p", String(port), "-i", privateKey.path,
                "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes",
                "-o", "UserKnownHostsFile=\"\(hostsPath)\"", "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=\(hostAlias)",
                "--", "root@127.0.0.1"] + command
    }

    public enum IdentityError: Error, CustomStringConvertible {
        case failed(String)
        public var description: String { switch self { case let .failed(message): message } }
    }
}
