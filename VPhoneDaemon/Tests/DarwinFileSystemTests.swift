import Foundation

@main
struct DarwinFileSystemTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vphone-darwin-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("research".utf8).write(to: root.appendingPathComponent("sample"))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: root.appendingPathComponent("sample").path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "directory")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "absent")
        let result = try VPhoneDarwinFileSystem.listDirectory(root.path)
        let entries = result["entries"] as! [[String: Any]]
        precondition(entries.map { $0["name"] as! String } == ["alias", "dangling", "directory", "sample"])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0["name"] as! String, $0) })
        precondition(result["count"] as? Int == 4)
        precondition(byName["sample"]?["type"] as? String == "file")
        precondition(byName["sample"]?["size"] as? Int64 == 8)
        precondition(byName["sample"]?["perm"] as? String == "640")
        precondition((byName["sample"]?["mtime"] as? Double ?? 0) > 0)
        precondition(byName["directory"]?["type"] as? String == "dir")
        precondition(byName["alias"]?["type"] as? String == "link")
        precondition(byName["alias"]?["link_target_dir"] as? Bool == true)
        let resolved = byName["alias"]?["resolved_path"] as! String
        precondition(resolved.hasSuffix("/directory"))
        let actual = try FileManager.default.attributesOfItem(atPath: resolved)
        let expected = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("directory").path)
        precondition(actual[.systemFileNumber] as? NSNumber == expected[.systemFileNumber] as? NSNumber)
        precondition(byName["dangling"]?["type"] as? String == "link")
        precondition(byName["dangling"]?["link_target_dir"] as? Bool == false)
        precondition(byName["dangling"]?["resolved_path"] == nil)
        // Metadata must remain JSON-safe for the HTTP and terminal transports.
        precondition(JSONSerialization.isValidJSONObject(result))
        do {
            _ = try VPhoneDarwinFileSystem.listDirectory(root.appendingPathComponent("absent").path)
            preconditionFailure("Missing directory must fail")
        } catch {}
        print("darwinOS file metadata tests passed")
    }
}
