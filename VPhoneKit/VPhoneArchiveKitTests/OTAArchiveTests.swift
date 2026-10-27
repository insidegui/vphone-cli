import AppleArchive
import ArchiveKit
import CryptoKit
import Foundation
import System
import Testing
@testable import VPhoneArchiveKit
import VPhoneCoreKit

/// Staging an Apple TV 4K's device tree and userland from its OTA with the
/// system AppleArchive framework. The OTAs here are synthetic but shaped like
/// Apple's: AEA around a segmented archive whose extract segments carry the
/// files, plus the manifest and fix-up segments staging ignores.
@Suite("OTA userland staging", .serialized)
struct OTAArchiveTests {
    // MARK: - Fixtures

    private let key = SymmetricKey(size: .bits256)
    private var keyText: String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private enum Entry {
        case file(String, Data)
        case directory(String)
        case symlink(String, String)
        /// A top-level metadata entry: `yop` and an archive of `entries` in its blob.
        case segment(Character, [Entry])
    }

    private func field(_ key: String, _ value: UInt64) -> ArchiveHeader.Field {
        .uint(key: ArchiveHeader.FieldKey(key), value: value)
    }

    private func ascii(_ character: Character) -> UInt64 {
        UInt64(character.asciiValue!)
    }

    /// The Apple Archive encoding of `entries`.
    private func encode(_ entries: [Entry], in root: URL) throws -> Data {
        let file = root.appendingPathComponent("\(UUID().uuidString).aar")
        let stream = try #require(ArchiveByteStream.fileStream(
            path: FilePath(file.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644),
        ))
        let encoder = try #require(ArchiveStream.encodeStream(writingTo: stream))
        for entry in entries {
            let header = ArchiveHeader()
            let blob: Data?
            switch entry {
            case let .file(path, data):
                header.append(field("TYP", ascii("F")))
                header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: path))
                blob = data
            case let .directory(path):
                header.append(field("TYP", ascii("D")))
                header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: path))
                blob = nil
            case let .symlink(path, target):
                header.append(field("TYP", ascii("L")))
                header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: path))
                header.append(.string(key: ArchiveHeader.FieldKey("LNK"), value: target))
                blob = nil
            case let .segment(yop, inner):
                header.append(field("TYP", ascii("M")))
                header.append(field("YOP", ascii(yop)))
                header.append(.string(key: ArchiveHeader.FieldKey("LBL"), value: "main"))
                blob = try encode(inner, in: root)
            }
            if let blob {
                header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(blob.count)))
            }
            try encoder.writeHeader(header)
            if let blob, !blob.isEmpty {
                try blob.withUnsafeBytes { try encoder.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) }
            }
        }
        try encoder.close()
        try stream.close()
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    /// `archive` encrypted as Apple encrypts an OTA.
    private func encrypt(_ archive: Data, to file: URL, with key: SymmetricKey) throws {
        let stream = try #require(ArchiveByteStream.fileStream(
            path: FilePath(file.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644),
        ))
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__symmetric__none, compressionAlgorithm: .lzfse)
        try context.setSymmetricKey(key)
        let encrypted = try #require(ArchiveByteStream.encryptionStream(writingTo: stream, encryptionContext: context))
        _ = try archive.withUnsafeBytes { try encrypted.write(from: $0) }
        try encrypted.close()
        try stream.close()
    }

    private func manifest(productTypes: [String] = ["AppleTV14,1"], build: String = "23L773", version: String = "26.6") throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "ProductVersion": version,
            "ProductBuildVersion": build,
            "SupportedProductTypes": productTypes,
        ], format: .xml, options: 0)
    }

    private func chunk(_ index: Int) -> Data {
        Data("chunk \(index) ".utf8) + Data(repeating: UInt8(index), count: 1000 + index)
    }

    /// The members Apple's AppleTV14,1 26.6 OTA has, in its order: the
    /// manifest and device trees in one extract segment, the payload chunks
    /// split across two more, `.ecc` files staging skips, and fix-ups.
    private func otaEntries(
        manifest: Data,
        chunks: Int = 3,
        list: String? = nil,
        deviceTree: Bool = true,
    ) -> [Entry] {
        let listed = list ?? (0 ..< chunks).map { "\($0): \(1000 + $0)" }.joined(separator: "\n") + "\n"
        let payload = (0 ..< chunks).flatMap { index -> [Entry] in
            let name = String(format: "AssetData/payloadv2/payload.%03d", index)
            return [.file(name, chunk(index)), .file(name + ".ecc", Data("ecc".utf8))]
        }
        let split = payload.count / 2
        var firmware: [Entry] = [
            .file("AssetData/Info.plist", Data("info".utf8)),
            .file("AssetData/boot/BuildManifest.plist", manifest),
            .file("AssetData/boot/Firmware/all_flash/LLB.j255.RELEASE.im4p", Data("llb".utf8)),
        ]
        if deviceTree {
            firmware.append(.file("AssetData/boot/Firmware/all_flash/DeviceTree.j255ap.im4p", Data("tree j255ap".utf8)))
        }
        return [
            .segment("M", [.directory("")]),
            .segment("E", [.directory("AssetData"), .directory("AssetData/payloadv2")]),
            .segment("E", firmware),
            .segment("E", Array(payload[..<split]) + [.file("AssetData/payloadv2/fixup.manifest", Data("fixup".utf8))]),
            .segment("E", Array(payload[split...]) + [
                .file("AssetData/payloadv2/payload_chunks.txt", Data(listed.utf8)),
                .file("AssetData/payloadv2/prepare_payload", Data("pbzx".utf8)),
            ]),
            .segment("O", [.file("AssetData/payloadv2/payload.000", Data())]),
        ]
    }

    private func makeOTA(in root: URL, _ entries: [Entry], key: SymmetricKey? = nil) throws -> URL {
        let file = root.appendingPathComponent("AppleTV14,1_26.6_23L773_OTA.aea")
        try encrypt(encode(entries, in: root), to: file, with: key ?? self.key)
        return file
    }

    private func makeZIP(in root: URL, _ members: [(String, Data)]) throws -> URL {
        let file = root.appendingPathComponent("HomePod.zip")
        let writer = try #require(archive_write_new())
        defer { archive_write_free(writer) }
        try #require(archive_write_set_format_zip(writer) == ARCHIVE_OK)
        try #require(archive_write_open_filename(writer, file.path) == ARCHIVE_OK)
        for (path, data) in members {
            let entry = try #require(archive_entry_new())
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, path)
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o644)
            archive_entry_set_size(entry, Int64(data.count))
            try #require(archive_write_header(writer, entry) == ARCHIVE_OK)
            try data.withUnsafeBytes { bytes in
                try #require(archive_write_data(writer, bytes.baseAddress, bytes.count) == bytes.count)
            }
        }
        try #require(archive_write_close(writer) == ARCHIVE_OK)
        return file
    }

    private func stage(_ ota: URL, in root: URL, key: String?, build: String = "23L773") throws -> VPhoneOTAArchive.StagedUserland {
        let flash = root.appendingPathComponent("restore/Firmware/all_flash", isDirectory: true)
        try FileManager.default.createDirectory(at: flash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("vm"), withIntermediateDirectories: true)
        return try VPhoneOTAArchive.stageUserland(
            from: ota,
            key: key,
            device: .appleTV14_1,
            build: build,
            deviceTreeDirectory: flash,
            userlandDirectory: root.appendingPathComponent("vm/OTAUserland", isDirectory: true),
        )
    }

    private func vmFolder(_ root: URL) throws -> [String] {
        let vm = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(atPath: vm.path)
    }

    // MARK: - Staging

    @Test func `HomePod ZIP staging reads late metadata before payload and ignores unrelated paths`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let flash = root.appendingPathComponent("flash")
        try FileManager.default.createDirectory(at: flash, withIntermediateDirectories: true)
        let manifest = try PropertyListSerialization.data(fromPropertyList: [
            "ProductVersion": "27.2", "ProductBuildVersion": "24K120",
            "SupportedProductTypes": ["AudioAccessory5,1"],
        ], format: .xml, options: 0)
        let info = try PropertyListSerialization.data(fromPropertyList: ["OSVersion": "27.2"], format: .xml, options: 0)
        let payload = try encode([.directory("System"), .file("System/source", Data("native".utf8))], in: root)
        let ota = try makeZIP(in: root, [
            ("../outside", Data("unselected".utf8)),
            ("AssetData/payloadv2/payload.000", payload),
            ("AssetData/payloadv2/payload.000.ecc", Data("ecc".utf8)),
            ("AssetData/payloadv2/payload_chunks.txt", Data("0: 1000\n".utf8)),
            ("AssetData/payloadv2/links.txt", Data("=System/source\n+System/copy\n".utf8)),
            ("AssetData/boot/Firmware/all_flash/DeviceTree.b520ap.im4p", Data("b520".utf8)),
            ("AssetData/boot/BuildManifest.plist", manifest),
            ("AssetData/Info.plist", info),
        ])
        let identity = try VPhoneOTAArchive.checkIdentity(of: ota, key: nil, device: .audioAccessory5_1, build: "24K120")
        #expect(identity.version == "27.2")
        let userland = root.appendingPathComponent("OTAUserland")
        let result = try VPhoneOTAArchive.stageUserland(from: ota, key: nil, device: .audioAccessory5_1,
            build: "24K120", deviceTreeDirectory: flash, userlandDirectory: userland, requireFullUpdate: true)
        #expect(result.chunks == ["payload.000"])
        #expect(try Data(contentsOf: userland.appendingPathComponent("payload.000")) == payload)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }

    @Test func `an LZRAVEN payload is refused before macOS 27, by name`() throws {
        let chunk = URL(fileURLWithPath: "/tmp/payload.000")
        let lzraven = Data("pbzm".utf8) + Data(repeating: 0, count: 4)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            let error = try #require(throws: VPhoneOTAArchive.Error.self) {
                try VPhoneOTAArchive.checkCompression(lzraven, of: chunk)
            }
            guard case .needsNewerMacOS(chunk, minimum: 27) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(error.localizedDescription.contains("LZRAVEN"))
            #expect(!error.localizedDescription.contains("Download the OTA again"))
        } else {
            try VPhoneOTAArchive.checkCompression(lzraven, of: chunk)
        }
        // Every other pbz compression is AppleArchive's on any supported host.
        try VPhoneOTAArchive.checkCompression(Data("pbzx".utf8), of: chunk)
    }

    @Test func `ZIP duplicate metadata is refused`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ota = try makeZIP(in: root, [("AssetData/Info.plist", Data()), ("AssetData/Info.plist", Data())])
        #expect(throws: VPhoneOTAArchive.Error.self) {
            try VPhoneOTAArchive.readMembers(ota, key: nil, select: { _ in .skip }, received: { _, _ in })
        }
    }

    @Test func `ZIP metadata has the same bounded memory admission as Apple Archive`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = Data(repeating: 0, count: Int(VPhoneOTAArchive.memoryLimit) + 1)
        let ota = try makeZIP(in: root, [("AssetData/Info.plist", oversized)])
        #expect(throws: VPhoneOTAArchive.Error.self) {
            try VPhoneOTAArchive.readMembers(ota, key: nil, select: { _ in .memory }, received: { _, _ in Issue.record("oversized metadata delivered") })
        }
    }

    @Test func `hard-link lists preserve spaces and reject unsafe or ambiguous records`() throws {
        let links = try VPhoneOTAArchive.parseHardLinks(Data("=System/source file\n+System/copy file\n+System/another\n".utf8))
        #expect(links.count == 2)
        #expect(links[0].source == "System/source file")
        #expect(links[0].destination == "System/copy file")
        for bad in ["+orphan\n", "=/outside\n+target\n", "=source\n+../outside\n",
                    "=source\n+source\n", "=source\n+target\n+target\n", "?unsupported\n",
                    "=source\n+dir//file\n", "=source\n+dir/./file\n", "=source\n+dir/\u{0}file\n"] {
            #expect(throws: VPhoneOTAArchive.Error.self) {
                try VPhoneOTAArchive.parseHardLinks(Data(bad.utf8))
            }
        }
    }

    @Test func `payload validation checks external hard links against the whole filesystem`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = root.appendingPathComponent("payload.000")
        try encode([.directory("System"), .file("System/source", Data("resource".utf8)),
                    .symlink("escape", "/private/tmp")], in: root).write(to: chunk)
        try VPhoneOTAArchive.validatePayloadPaths([chunk], hardLinks: Data("=System/source\n+System/copy\n".utf8))
        for list in ["=missing\n+System/copy\n", "=escape\n+System/copy\n",
                     "=System/source\n+escape/outside\n", "=System/source\n+System/source/child\n",
                     "=System/source\n+System/copy\n+System/copy/child\n"] {
            #expect(throws: VPhoneOTAArchive.Error.self) {
                try VPhoneOTAArchive.validatePayloadPaths([chunk], hardLinks: Data(list.utf8))
            }
        }
    }

    @Test func `hard-link installation shares the source inode and refuses symlink parents`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try VPhoneConfinedDirectory(root: root.path)
        _ = try directory.directory("System", create: true)
        try directory.writeFile("System/source", contents: Data("resource".utf8), mode: 0o640)
        let list = Data("=System/source\n+System/copy\n".utf8)
        #expect(try VPhoneOTAArchive.installHardLinks(list, in: directory) == 1)
        let source = try directory.openRegularFile("System/source")
        #expect(try directory.refersTo("System/copy", file: source))
        #expect(try directory.readData("System/copy") == Data("resource".utf8))
        #expect(throws: VPhoneConfinedDirectoryError.self) {
            try VPhoneOTAArchive.installHardLinks(list, in: directory)
        }
        try directory.createSymlink(target: "System", at: "alias")
        for bad in ["=alias/source\n+System/other\n", "=System/source\n+alias/other\n"] {
            #expect(throws: VPhoneConfinedDirectoryError.self) {
                try VPhoneOTAArchive.installHardLinks(Data(bad.utf8), in: directory)
            }
        }
        #expect(try directory.exists("System/other") == false)
    }

    @Test func `staging retains the separate hard-link manifest`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let links = Data("=System/source\n+System/copy\n".utf8)
        let entries = try otaEntries(manifest: manifest()) + [
            .segment("E", [.file("AssetData/payloadv2/links.txt", links)]),
        ]
        let ota = try makeOTA(in: root, entries)
        _ = try stage(ota, in: root, key: keyText)
        #expect(try Data(contentsOf: root.appendingPathComponent("vm/OTAUserland/links.txt")) == links)
    }

    @Test func `full iPad staging requires and validates the separate hard-link phase`() throws {
        for includeLinks in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let flash = root.appendingPathComponent("restore/Firmware/all_flash")
            try FileManager.default.createDirectory(at: flash, withIntermediateDirectories: true)
            _ = try vmFolder(root)
            let manifest = try PropertyListSerialization.data(fromPropertyList: [
                "ProductVersion": "27.0.1", "ProductBuildVersion": "24A446",
                "SupportedProductTypes": ["iPad16,1"],
            ], format: .xml, options: 0)
            let info = try PropertyListSerialization.data(fromPropertyList: ["OSVersion": "27.0.1"], format: .xml, options: 0)
            let payload = try encode([.directory("System"), .file("System/source", Data("resource".utf8))], in: root)
            var members: [Entry] = [
                .file("AssetData/Info.plist", info),
                .file("AssetData/boot/BuildManifest.plist", manifest),
                .file("AssetData/boot/Firmware/all_flash/DeviceTree.j410ap.im4p", Data("tree".utf8)),
                .file("AssetData/payloadv2/payload.000", payload),
                .file("AssetData/payloadv2/payload_chunks.txt", Data("0: 1000\n".utf8)),
            ]
            if includeLinks { members.append(.file("AssetData/payloadv2/links.txt", Data("=System/source\n+System/copy\n".utf8))) }
            let ota = try makeOTA(in: root, [.segment("E", members)])
            let device = try #require(VPhoneGuestDevice.named("iPad16,1"))
            let userland = root.appendingPathComponent("vm/OTAUserland")
            if includeLinks {
                let staged = try VPhoneOTAArchive.stageUserland(from: ota, key: keyText, device: device,
                    build: "24A446", deviceTreeDirectory: flash, userlandDirectory: userland, requireFullUpdate: true)
                #expect(staged.build == "24A446")
                #expect(FileManager.default.fileExists(atPath: userland.appendingPathComponent("links.txt").path))
            } else {
                #expect(throws: VPhoneOTAArchive.Error.self) {
                    try VPhoneOTAArchive.stageUserland(from: ota, key: keyText, device: device,
                        build: "24A446", deviceTreeDirectory: flash, userlandDirectory: userland, requireFullUpdate: true)
                }
                #expect(!FileManager.default.fileExists(atPath: userland.path))
            }
        }
    }

    @Test func `full updates reject prerequisite metadata before staging chunks`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for value: Any in ["23G90", ["23G90"], 123] {
            let info = try PropertyListSerialization.data(fromPropertyList: ["PrerequisiteBuild": value], format: .xml, options: 0)
            #expect(throws: VPhoneOTAArchive.Error.self) {
                try VPhoneOTAArchive.checkFullUpdateInfo(info, of: root.appendingPathComponent("delta.aea"))
            }
        }
        let full = try PropertyListSerialization.data(fromPropertyList: ["OSVersion": "27.0.1"], format: .xml, options: 0)
        try VPhoneOTAArchive.checkFullUpdateInfo(full, of: root.appendingPathComponent("full.aea"))
        let nested = try PropertyListSerialization.data(fromPropertyList: ["MobileAssetProperties": ["PrerequisiteBuild": "23G90"]], format: .xml, options: 0)
        #expect(throws: VPhoneOTAArchive.Error.self) {
            try VPhoneOTAArchive.checkFullUpdateInfo(nested, of: root.appendingPathComponent("delta.aea"))
        }
    }

    @Test func `payload validation rejects traversal and cross-chunk symlink descendants`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("payload.000")
        let b = root.appendingPathComponent("payload.001")
        for path in ["../outside", "/outside", "System/../outside", "System//outside"] {
            try encode([.file(path, Data())], in: root).write(to: a)
            #expect(throws: VPhoneOTAArchive.Error.self) {
                try VPhoneOTAArchive.validatePayloadPaths([a])
            }
        }
        try encode([.symlink("escape", "/private/tmp")], in: root).write(to: a)
        try encode([.file("escape/outside", Data())], in: root).write(to: b)
        #expect(throws: VPhoneOTAArchive.Error.self) {
            try VPhoneOTAArchive.validatePayloadPaths([a, b])
        }
        // A guest's absolute links are valid when extraction never follows them.
        try encode([.directory(""), .directory("System"), .file("System/test", Data()), .symlink("var", "/private/var")], in: root).write(to: a)
        try VPhoneOTAArchive.validatePayloadPaths([a])
    }

    @Test func `the fourth generation stages J265 from its encrypted 27 point 2 OTA`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("flash"), withIntermediateDirectories: true)
        let data = try manifest(productTypes: ["AppleTV18,1"], build: "24K120", version: "27.2")
        let entries: [Entry] = [
            .segment("E", [
                .file("AssetData/boot/BuildManifest.plist", data),
                .file("AssetData/boot/Firmware/all_flash/DeviceTree.j265ap.im4p", Data("J265".utf8)),
                .file("AssetData/payloadv2/payload.000", chunk(0)),
                .file("AssetData/payloadv2/payload_chunks.txt", Data("0: 1000\n".utf8)),
            ]),
        ]
        let ota = try makeOTA(in: root, entries)
        let identity = try VPhoneOTAArchive.checkIdentity(of: ota, key: keyText, device: .appleTV18_1, build: "24K120")
        #expect(identity.version == "27.2" && identity.build == "24K120")
        let staged = try VPhoneOTAArchive.stageUserland(
            from: ota, key: keyText, device: .appleTV18_1, build: "24K120",
            deviceTreeDirectory: root.appendingPathComponent("flash"),
            userlandDirectory: root.appendingPathComponent("userland")
        )
        #expect(staged.chunks == ["payload.000"])
        #expect(staged.deviceTree.lastPathComponent == "DeviceTree.j265ap.im4p")
        #expect(try Data(contentsOf: staged.deviceTree) == Data("J265".utf8))
        #expect(throws: VPhoneOTAArchive.Error.self) {
            try VPhoneOTAArchive.checkIdentity(of: ota, key: keyText, device: .appleTV14_1)
        }
    }

    @Test(arguments: ["26.6", "27.0", "27.1", "27.2.1", "27.3", "28.2"])
    func `the fourth generation refuses other userland versions before staging`(version: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try manifest(productTypes: ["AppleTV18,1"], build: "24K120", version: version)
        let ota = try makeOTA(in: root, otaEntries(manifest: data))
        #expect {
            try VPhoneOTAArchive.checkIdentity(of: ota, key: keyText, device: .appleTV18_1)
        } throws: { error in
            guard case let .unsupportedVersion(_, productType, actual)? = error as? VPhoneOTAArchive.Error else { return false }
            return productType == "AppleTV18,1" && actual == version
        }
        let userland = root.appendingPathComponent("userland")
        #expect {
            try VPhoneOTAArchive.stageUserland(
                from: ota, key: keyText, device: .appleTV18_1, build: "24K120",
                deviceTreeDirectory: root.appendingPathComponent("flash"), userlandDirectory: userland
            )
        } throws: { error in
            guard case let .unsupportedVersion(_, productType, actual)? = error as? VPhoneOTAArchive.Error else { return false }
            return productType == "AppleTV18,1" && actual == version
        }
        #expect(!FileManager.default.fileExists(atPath: userland.path))
    }

    @Test func `an encrypted OTA stages its device tree, payload chunks and chunk list`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try vmFolder(root)
        let ota = try makeOTA(in: root, otaEntries(manifest: manifest()))

        let staged = try stage(ota, in: root, key: keyText)

        #expect(staged.version == "26.6" && staged.build == "23L773")
        #expect(staged.chunks == ["payload.000", "payload.001", "payload.002"])
        #expect(try Data(contentsOf: staged.deviceTree) == Data("tree j255ap".utf8))
        #expect(staged.deviceTree.path.hasSuffix("restore/Firmware/all_flash/DeviceTree.j255ap.im4p"))
        let userland = root.appendingPathComponent("vm/OTAUserland")
        let names = try FileManager.default.contentsOfDirectory(atPath: userland.path).sorted()
        #expect(names == ["payload.000", "payload.001", "payload.002", "payload_chunks.txt"])
        for index in 0 ..< 3 {
            #expect(try Data(contentsOf: userland.appendingPathComponent(String(format: "payload.%03d", index))) == chunk(index))
        }
        #expect(try String(contentsOf: userland.appendingPathComponent("payload_chunks.txt"), encoding: .utf8) == "0: 1000\n1: 1001\n2: 1002\n")
        // Nothing else from the OTA lands beside the device tree.
        let flash = try FileManager.default.contentsOfDirectory(atPath: staged.deviceTree.deletingLastPathComponent().path)
        #expect(flash == ["DeviceTree.j255ap.im4p"])
        #expect(try vmFolder(root) == ["OTAUserland"])
    }

    @Test func `a decrypted archive stages without a key`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try vmFolder(root)
        let ota = root.appendingPathComponent("decrypted.aar")
        try encode(otaEntries(manifest: manifest()), in: root).write(to: ota)

        let staged = try stage(ota, in: root, key: nil)
        #expect(staged.chunks.count == 3)
    }

    @Test func `an encrypted OTA needs its own key`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ota = try makeOTA(in: root, otaEntries(manifest: manifest()))

        #expect {
            try stage(ota, in: root, key: nil)
        } throws: { error in
            if case .keyRequired(ota)? = error as? VPhoneOTAArchive.Error { true } else { false }
        }
        let other = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
        #expect {
            try stage(ota, in: root, key: other)
        } throws: { error in
            if case .wrongKey? = error as? VPhoneOTAArchive.Error { true } else { false }
        }
        #expect(try vmFolder(root).isEmpty)
    }

    @Test func `another device's OTA stops before any chunk is written`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ota = try makeOTA(in: root, otaEntries(manifest: manifest(productTypes: ["AppleTV11,1"])))

        #expect {
            try stage(ota, in: root, key: keyText)
        } throws: { error in
            guard case let .wrongDevice(_, types, expected)? = error as? VPhoneOTAArchive.Error else { return false }
            return types == ["AppleTV11,1"] && expected == "AppleTV14,1"
        }
        #expect(try vmFolder(root).isEmpty)
        let flash = root.appendingPathComponent("restore/Firmware/all_flash")
        #expect(try FileManager.default.contentsOfDirectory(atPath: flash.path).isEmpty)
    }

    @Test func `the OTA must be the IPSW's build`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ota = try makeOTA(in: root, otaEntries(manifest: manifest(build: "23L760")))

        #expect {
            try stage(ota, in: root, key: keyText)
        } throws: { error in
            guard case let .wrongBuild(_, build, expected)? = error as? VPhoneOTAArchive.Error else { return false }
            return build == "23L760" && expected == "23L773"
        }
        #expect(try vmFolder(root).isEmpty)
    }

    @Test func `a chunk list that does not match the chunks leaves no userland`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ota = try makeOTA(in: root, otaEntries(manifest: manifest(), list: "0: 1000\n1: 1001\n2: 1002\n3: 1003\n"))

        #expect {
            try stage(ota, in: root, key: keyText)
        } throws: { error in
            if case .inconsistentChunks? = error as? VPhoneOTAArchive.Error { true } else { false }
        }
        #expect(try vmFolder(root).isEmpty)
    }

    @Test func `an OTA without the device's tree is refused`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ota = try makeOTA(in: root, otaEntries(manifest: manifest(), deviceTree: false))

        #expect {
            try stage(ota, in: root, key: keyText)
        } throws: { error in
            guard case let .missingMember(member, _)? = error as? VPhoneOTAArchive.Error else { return false }
            return member.hasSuffix("DeviceTree.j255ap.im4p")
        }
        #expect(try vmFolder(root).isEmpty)
    }

    @Test func `an existing userland folder is not replaced`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let userland = root.appendingPathComponent("vm/OTAUserland")
        try FileManager.default.createDirectory(at: userland, withIntermediateDirectories: true)
        let ota = try makeOTA(in: root, otaEntries(manifest: manifest()))

        #expect {
            try stage(ota, in: root, key: keyText)
        } throws: { error in
            if case .existingUserland? = error as? VPhoneOTAArchive.Error { true } else { false }
        }
    }

    @Test func `a truncated ZIP is refused before any OTA chunk is written`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("AppleTV5,3_26.6_23L773_Restore.ipsw")
        try Data("PK\u{3}\u{4}not an ota".utf8).write(to: zip)

        #expect {
            try stage(zip, in: root, key: keyText)
        } throws: { error in
            if case .unreadable? = error as? VPhoneOTAArchive.Error { true } else { false }
        }
    }

    // MARK: - Names and keys

    @Test func `only numbered payload chunks are staged`() {
        #expect(VPhoneOTAArchive.isChunkName("payload.000"))
        #expect(VPhoneOTAArchive.isChunkName("payload.036"))
        #expect(!VPhoneOTAArchive.isChunkName("payload.000.ecc"))
        #expect(!VPhoneOTAArchive.isChunkName("payload."))
        #expect(!VPhoneOTAArchive.isChunkName("payload_chunks.txt"))
        #expect(!VPhoneOTAArchive.isChunkName("payload.0/../x"))
        #expect(!VPhoneOTAArchive.isChunkName("../payload.000"))
    }

    @Test func `keys are 32 bytes of base64, with or without aea's prefix`() throws {
        let raw = keyText
        let plain = try VPhoneOTAArchive.symmetricKey(raw)
        let prefixed = try VPhoneOTAArchive.symmetricKey("base64:\(raw)\n")
        #expect(plain == key && prefixed == key)
        #expect(throws: VPhoneOTAArchive.Error.self) { try VPhoneOTAArchive.symmetricKey("not base64") }
        #expect(throws: VPhoneOTAArchive.Error.self) {
            try VPhoneOTAArchive.symmetricKey(Data(repeating: 1, count: 16).base64EncodedString())
        }
    }

    // MARK: - Source

    @Test func `a local OTA is read in place and a cached catalog OTA is reused`() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local.aea")
        try Data("AEA1local".utf8).write(to: local)
        #expect(try await VPhoneOTAArchive.resolve(local.path, release: nil, in: root) == local)

        let cached = Data("AEA1".utf8) + Data(repeating: 0, count: 60)
        let release = VPhoneOTARelease(
            productType: "AppleTV14,1",
            version: "26.6",
            build: "23L773",
            url: "https://example.invalid/ota.aea",
            size: Int64(cached.count),
            key: keyText,
        )
        let ota = root.appendingPathComponent("ota", isDirectory: true)
        try FileManager.default.createDirectory(at: ota, withIntermediateDirectories: true)
        let file = ota.appendingPathComponent(release.fileName)
        try cached.write(to: file)
        #expect(try await VPhoneOTAArchive.resolve(nil, release: release, in: root) == file)
        #expect(try await VPhoneOTAArchive.resolve(release.url, release: release, in: root) == file)
    }

    @Test func `a cached OTA of the wrong length is removed`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("AppleTV14,1_26.6_23L773_OTA.aea")
        try Data("AEA1short".utf8).write(to: file)

        #expect(try !VPhoneOTAArchive.reusable(file, size: 4_764_729_344))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data("AEA1".utf8).write(to: file)
        #expect(try VPhoneOTAArchive.reusable(file, size: 4))
        try Data("PK..".utf8).write(to: file)
        #expect(try !VPhoneOTAArchive.reusable(file, size: 4))
    }

    @Test func `a remote OTA outside the catalog gets a cache name of its own`() throws {
        let url = try #require(URL(string: "https://updates.cdn-apple.com/x/com_apple_MobileAsset_SoftwareUpdate/9daea812.aea"))
        let name = VPhoneOTAArchive.cacheName(for: url)
        #expect(name.hasPrefix("9daea812-") && name.hasSuffix(".aea"))
        #expect(name != VPhoneOTAArchive.cacheName(for: try #require(URL(string: "https://other.example/9daea812.aea"))))
    }

    // MARK: - darwinOS restore assets

    private func darwinRestoreEntries() throws -> [Entry] {
        let manifest = try PropertyListSerialization.data(fromPropertyList: [
            "ProductVersion": "26.4",
            "ProductBuildVersion": "23E246",
            "SupportedProductTypes": ["AppleDisplay18,1"],
            "BuildIdentities": [[
                "Ap,OSEnvironment": "0x05",
                "Info": ["DeviceClass": "j427ap", "Variant": "Darwin Customer Install"],
                "Manifest": [
                    "OS": ["Info": ["Path": "system.dmg.aea"]],
                    "DeviceTree": ["Info": ["Path": "Firmware/all_flash/DeviceTree.j427ap.im4p"]],
                ],
            ]],
        ], format: .xml, options: 0)
        return [
            .file("Info.plist", Data("outer asset metadata".utf8)),
            .file("AssetData/BuildManifest.plist", manifest),
            .file("AssetData/Restore.plist", Data("restore".utf8)),
            .file("AssetData/SystemVersion.plist", Data("system version".utf8)),
            .file("AssetData/system.dmg.aea", Data("encrypted system image retained verbatim".utf8)),
            .file("AssetData/Firmware/all_flash/DeviceTree.j427ap.im4p", Data("J427 tree".utf8)),
        ]
    }

    @Test func `darwinOS restore asset metadata and images survive native AEA extraction`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("renamed-firmware.bin")
        try encrypt(encode([.segment("E", try darwinRestoreEntries())], in: root), to: file, with: key)
        let archive = try VPhoneIPSWCache.inspect(file, decryptionKey: keyText)
        #expect(archive.version == "26.4")
        #expect(archive.build == "23E246")
        #expect(archive.productTypes == ["AppleDisplay18,1"])
        #expect(archive.deviceClasses == ["j427ap"])
        #expect(try VPhoneIPSWCache.localArchive(file.path, in: root, decryptionKey: keyText)?.build == "23E246")
        let destination = root.appendingPathComponent("restore")
        #expect(try VPhoneDarwinRestoreArchive.extract(file, key: keyText, into: destination) == 5)
        #expect(try Data(contentsOf: destination.appendingPathComponent("system.dmg.aea")) == Data("encrypted system image retained verbatim".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("Firmware/all_flash/DeviceTree.j427ap.im4p")) == Data("J427 tree".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("AssetData").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Info.plist").path))
        #expect(throws: (any Swift.Error).self) {
            try VPhoneDarwinRestoreArchive.buildManifest(of: file, key: Data(repeating: 0, count: 32).base64EncodedString())
        }
        #expect(throws: (any Swift.Error).self) { try VPhoneIPSWCache.inspect(file) }
    }

    @Test func `renamed darwinOS restore assets use authenticated catalog keys`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = try #require(VPhoneFirmwareCatalog.darwinRestoreReleases.first)
        let catalogKey = try VPhoneOTAArchive.symmetricKey(try #require(release.key))
        let file = root.appendingPathComponent("unrecognized-local-name")
        try encrypt(encode(try darwinRestoreEntries(), in: root), to: file, with: catalogKey)
        #expect(try VPhoneIPSWCache.inspect(file).productTypes == ["AppleDisplay18,1"])
        #expect(VPhoneIPSWCache.cacheName(for: try #require(URL(string: release.url))) == release.fileName)
    }

    @Test func `cached darwinOS metadata uses the OTA folder and refuses a wrong length`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = try #require(VPhoneFirmwareCatalog.darwinRestoreReleases.first)
        let catalogKey = try VPhoneOTAArchive.symmetricKey(try #require(release.key))
        let directory = root.appendingPathComponent("ota", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(release.fileName)
        try encrypt(encode(try darwinRestoreEntries(), in: root), to: file, with: catalogKey)
        #expect(try VPhoneIPSWCache.inspect(file).build == "23E246")
        // Readable metadata is not enough: this tiny fixture has not completed
        // the catalog asset's download. A read-only cache lookup leaves it alone.
        #expect(try VPhoneIPSWCache.localArchive(release.url, in: root) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try VPhoneIPSWCache.localArchive(file.path, in: root)?.build == "23E246")
    }

    @Test func `darwinOS extraction rejects traversal duplicates and parent-file collisions atomically`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = try darwinRestoreEntries()
        let badMembers: [[Entry]] = [
            [.file("AssetData/../../escaped", Data())],
            [.file("AssetData/system.dmg.aea", Data())],
            [.file("AssetData/extra/child", Data()), .file("AssetData/extra", Data())],
            [.file("AssetData/other", Data()), .file("AssetData/other/child", Data())],
        ]
        for bad in badMembers {
            let file = root.appendingPathComponent("\(UUID().uuidString).aar")
            try encode(originals + bad, in: root).write(to: file)
            let destination = root.appendingPathComponent("restore")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            #expect(throws: (any Swift.Error).self) { try VPhoneDarwinRestoreArchive.extract(file, into: destination) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            try FileManager.default.removeItem(at: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".darwin-restore-") })
    }

    @Test func `darwinOS archive symlinks cannot redirect extraction or supply required images`() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("links.aar")
        try encode([.symlink("AssetData/Firmware", outside.path)] + darwinRestoreEntries(), in: root).write(to: file)
        let destination = root.appendingPathComponent("restore")
        try VPhoneDarwinRestoreArchive.extract(file, into: destination)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try destination.appendingPathComponent("Firmware").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true)

        let missing = root.appendingPathComponent("missing.aar")
        let withoutSystem = try darwinRestoreEntries().filter { entry in
            if case .file("AssetData/system.dmg.aea", _) = entry { return false }
            return true
        }
        try encode(withoutSystem + [.symlink("AssetData/system.dmg.aea", outside.path)], in: root).write(to: missing)
        #expect(throws: VPhoneDarwinRestoreArchive.Error.self) {
            try VPhoneDarwinRestoreArchive.extract(missing, into: root.appendingPathComponent("missing-restore"))
        }
    }
}
