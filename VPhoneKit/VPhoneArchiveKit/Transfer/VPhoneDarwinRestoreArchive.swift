import Darwin
import Foundation
import VPhoneCoreKit

/// DarwinAccessoryUpdate carries a complete restore asset under `AssetData`,
/// rather than the `boot` and `payloadv2` layout of a SoftwareUpdate OTA.
/// Only regular files are materialized: archive links and metadata never
/// become host filesystem objects.
public enum VPhoneDarwinRestoreArchive {
    static let prefix = "AssetData/"
    static let manifestPath = prefix + "BuildManifest.plist"

    public enum Error: Swift.Error, LocalizedError {
        case invalidManifest(URL)
        case invalidMember(String)
        case duplicateMember(String)
        case missingMember(String)
        case destinationNotEmpty(URL)

        public var errorDescription: String? {
            switch self {
            case let .invalidManifest(file):
                "\(file.lastPathComponent) has no valid darwinOS restore manifest. Choose a complete DarwinAccessoryUpdate asset."
            case let .invalidMember(path): "Unsafe darwinOS restore member: \(path)."
            case let .duplicateMember(path): "Duplicate darwinOS restore member: \(path)."
            case let .missingMember(path): "The darwinOS restore asset is missing \(path). Download the complete asset again."
            case let .destinationNotEmpty(path): "The darwinOS extraction directory must be empty: \(path.path)."
            }
        }
    }

    /// Detect by bytes, including a decrypted Apple Archive with any filename.
    public static func isArchive(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        return magic == Data("AEA1".utf8) || magic == Data("AA01".utf8) || magic.prefix(3) == Data("pbz".utf8)
    }

    /// The manifest is bounded by the OTA reader's metadata limit. Stop as
    /// soon as it is found, without decrypting the system images after it.
    public static func buildManifest(of file: URL, key: String? = nil) throws -> [String: Any] {
        struct Found: Swift.Error {}
        var result: [String: Any]?
        do {
            try VPhoneOTAArchive.readMembers(file, key: key, select: { path in
                path == manifestPath ? .memory : .skip
            }, received: { _, data in
                guard let data,
                      let manifest = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let version = manifest["ProductVersion"] as? String, !version.isEmpty,
                      let build = manifest["ProductBuildVersion"] as? String, !build.isEmpty,
                      let products = manifest["SupportedProductTypes"] as? [String],
                      products.contains(where: { $0.hasPrefix("AppleDisplay") }),
                      let identities = manifest["BuildIdentities"] as? [[String: Any]], !identities.isEmpty else {
                    throw Error.invalidManifest(file)
                }
                result = manifest
                throw Found()
            })
        } catch is Found {}
        guard let result else { throw Error.invalidManifest(file) }
        return result
    }

    /// Unpack into a fresh directory on the same volume, then rename it into
    /// place. A malformed member leaves the caller's destination untouched.
    /// Neither archive-provided directory entries nor links are written, so
    /// a member cannot redirect a later write through an archive symlink.
    @discardableResult
    public static func extract(_ file: URL, key: String? = nil, into destination: URL) throws -> Int {
        let manifest = try buildManifest(of: file, key: key)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path),
           !(try fm.contentsOfDirectory(atPath: destination.path)).isEmpty {
            throw Error.destinationNotEmpty(destination)
        }
        let parent = try VPhoneArchivePaths.resolved(destination.deletingLastPathComponent())
        let pending = parent.appendingPathComponent(".darwin-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: pending) }
        var files: Set<String> = []
        try VPhoneOTAArchive.readMembers(file, key: key, select: { path in
            guard path.hasPrefix(prefix) else { return .skip }
            let relative = try relativePath(path)
            guard files.insert(relative).inserted else { throw Error.duplicateMember(path) }
            // A regular file cannot be another regular file's parent.
            let components = relative.split(separator: "/").map(String.init)
            for count in 1..<components.count {
                let ancestor = components.prefix(count).joined(separator: "/")
                guard !files.contains(ancestor) else { throw Error.invalidMember(path) }
            }
            guard !files.contains(where: { $0.hasPrefix(relative + "/") }) else { throw Error.invalidMember(path) }
            let target = pending.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // APFS may fold case or Unicode spellings that the archive names
            // differently. Never let the reader replace a previously written
            // object, even when its spelling differs from this member's.
            guard !fm.fileExists(atPath: target.path) else { throw Error.duplicateMember(path) }
            return .file(target)
        }, received: { _, _ in })

        var required: Set<String> = ["BuildManifest.plist", "Restore.plist", "SystemVersion.plist"]
        for identity in manifest["BuildIdentities"] as? [[String: Any]] ?? [] {
            for component in (identity["Manifest"] as? [String: [String: Any]] ?? [:]).values {
                if let path = (component["Info"] as? [String: Any])?["Path"] as? String {
                    required.insert(try relativePath(prefix + path))
                }
            }
        }
        for path in required.sorted() where !files.contains(path) { throw Error.missingMember(path) }
        if fm.fileExists(atPath: destination.path), rmdir(destination.path) != 0 {
            throw Error.destinationNotEmpty(destination)
        }
        try fm.moveItem(at: pending, to: destination)
        try VPhoneHostFilePermissions.makeAccessible(at: destination)
        return files.count
    }

    static func relativePath(_ path: String) throws -> String {
        guard path.hasPrefix(prefix) else { throw Error.invalidMember(path) }
        let relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.contains("\0"), !relative.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Error.invalidMember(path)
        }
        return relative
    }
}
