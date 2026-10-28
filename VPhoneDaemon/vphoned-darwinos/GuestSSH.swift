import CryptoKit
import Darwin
import Foundation

/// Provisioned over the existing host-only VSOCK control channel. Dropbear
/// handles the SSH protocol and PTY; dash is a separately signed native shell.
enum GuestSSH {
    static let directory = "/private/var/db/vphone-ssh"
    static let programs = "/usr/local/libexec/vphone-ssh"
    static let lock = NSLock()
    static var available: Bool {
        ["sshd", "sh", "keygen"].allSatisfy { access("\(programs)/\($0)", X_OK) == 0 }
    }

    static func configure(_ params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard available else { throw GuestAPIError.operationFailed("SSH payload missing; run cfw update-environment") }
        let offered = try GuestAPI.string(params, "public_key")
        let words = offered.split(whereSeparator: { $0.isWhitespace })
        guard words.count == 2, words[0] == "ssh-ed25519", words[1].count < 256,
              let key = Data(base64Encoded: String(words[1])), key.count == 51,
              key.prefix(19) == Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]) else {
            throw GuestAPIError.invalidRequest("Expected one Ed25519 SSH public key")
        }
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw GuestAPIError.operationFailed("Cannot create SSH state directory")
        }
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GuestAPIError.operationFailed("Invalid SSH state directory") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, fchmod(fd, 0o700) == 0 else {
            throw GuestAPIError.operationFailed("SSH state must be owned by root")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let authorized = root.appendingPathComponent("authorized_keys")
        let host = root.appendingPathComponent("host_ed25519")
        let identity = root.appendingPathComponent("identity")
        let fingerprint = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let previous = try? String(contentsOf: identity, encoding: .utf8)
        let changed = previous != fingerprint
        if changed || !FileManager.default.fileExists(atPath: host.path) {
            let temporary = root.appendingPathComponent(".host-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let result = try GuestAPI.runProgram(["path": "\(programs)/keygen", "args": ["-t", "ed25519", "-f", temporary.path]])
            guard (result["status"] as? NSNumber)?.intValue == 0 else {
                throw GuestAPIError.operationFailed("SSH host-key generation failed: \(result["stderr"] ?? "")")
            }
            guard chmod(temporary.path, 0o600) == 0, rename(temporary.path, host.path) == 0 else {
                throw GuestAPIError.operationFailed("Cannot install SSH host key")
            }
        }
        // Atomic replacements under a root-only directory; no account database
        // or system shell configuration is changed.
        try Data((offered + "\n").utf8).write(to: authorized, options: .atomic)
        try Data(fingerprint.utf8).write(to: identity, options: .atomic)
        guard chmod(authorized.path, 0o600) == 0, chmod(identity.path, 0o600) == 0 else {
            throw GuestAPIError.operationFailed("Cannot protect SSH credentials")
        }
        let result = try GuestAPI.runProgram(["path": "\(programs)/keygen", "args": ["-y", "-f", host.path]])
        guard (result["status"] as? NSNumber)?.intValue == 0,
              let output = result["stdout"] as? String,
              let publicKey = output.split(separator: "\n").first(where: { $0.hasPrefix("ssh-ed25519 ") }) else {
            throw GuestAPIError.operationFailed("Cannot read SSH host public key")
        }
        let status = try GuestAPI.execute(method: "services.status", params: ["label": "com.vphone.sshd"])
        if changed || status["running"] as? Bool != true {
            _ = try GuestAPI.execute(method: "services.kickstart", params: ["label": "com.vphone.sshd", "kill": true, "force": true])
        }
        // kickstart acknowledges the request before exec/listen completes.
        // Do not advertise a forward that races the first SSH connection.
        var listening = false
        for _ in 0..<50 {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if socket >= 0 {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(2222).bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                listening = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                close(socket)
            }
            if listening { break }
            usleep(100_000)
        }
        guard listening else { throw GuestAPIError.operationFailed("SSH did not start; inspect /private/var/log/vphone-ssh.log") }
        return ["host_key": String(publicKey), "port": 2222, "user": "root"]
    }
}
