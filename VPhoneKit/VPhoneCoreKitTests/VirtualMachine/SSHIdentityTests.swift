import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VPhoneCoreKit

@Suite("Studio Display SSH identity")
struct SSHIdentityTests {
    @Test("Keys survive reconnects, isolate machines and retain private permissions")
    func lifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try VPhoneSSHIdentity(machineIdentifier: Data("one".utf8), root: root.appendingPathComponent("ssh"))
        let key = try one.prepare()
        let privateBytes = try Data(contentsOf: one.privateKey)
        #expect(try one.prepare() == key)
        #expect(try Data(contentsOf: one.privateKey) == privateBytes)
        let same = try VPhoneSSHIdentity(machineIdentifier: Data("one".utf8), root: root.appendingPathComponent("ssh"))
        #expect(try same.prepare() == key)
        let other = try VPhoneSSHIdentity(machineIdentifier: Data("two".utf8), root: root.appendingPathComponent("ssh"))
        #expect(try other.prepare() != key)
        var info = stat()
        #expect(lstat(one.privateKey.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(lstat(one.directory.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        try one.trust(hostKey: key + " a comment\n")
        #expect(try String(contentsOf: one.knownHosts, encoding: .utf8) == "\(one.hostAlias) \(key)\n")
        let args = try one.arguments(port: 51234, command: ["printf", "hello"])
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("IdentityAgent=none"))
        #expect(args.suffix(3) == ["root@127.0.0.1", "printf", "hello"])
    }

    @Test("Malformed key blobs cannot become trusted host entries")
    func malformedKeys() {
        for key in ["", "ssh-rsa AAAA", "ssh-ed25519 AAAA", "ssh-ed25519 \(Data(repeating: 0, count: 51).base64EncodedString())"] {
            #expect(throws: (any Error).self) { try VPhoneSSHIdentity.publicKey(key) }
        }
    }

    @Test("Credential roots cannot redirect writes through symlinks")
    func symlinkRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("ssh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try VPhoneSSHIdentity(machineIdentifier: Data("one".utf8), root: link)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}
