import CryptoKit
import Darwin
import Foundation
import Synchronization
import VPhoneCoreKit

/// Resolves a local IPSW or downloads one into a reusable, validated cache.
/// Source archives are never rewritten. Remote downloads become visible only
/// after their BuildManifest can be read and their transfer size checks out.
public enum VPhoneIPSWCache {
    public struct Archive: Sendable {
        public let file: URL
        public let version: String
        public let build: String
        /// `SupportedProductTypes`, such as `iPhone17,3`.
        public let productTypes: [String]
        /// Every build identity's `Info.DeviceClass`, such as `vresearch101ap`.
        public let deviceClasses: Set<String>
    }

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedSource(String)
        case missingFile(URL)
        case invalidManifest(URL)
        case unexpectedHTTP(URL, Int)
        case incompleteDownload(URL, expected: Int64, actual: Int64)
        case changedDuringDownload(URL)
        case swappedSources(iPhone: URL, cloudOS: URL)
        case notIPhoneSource(URL, productTypes: [String])
        case notCloudOSSource(URL)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSource(source): "Unsupported IPSW source: \(source). Use a local file path or an HTTP(S) URL."
            case let .missingFile(file): "IPSW not found at \(file.path). Check the path and try again."
            case let .invalidManifest(file): "\(file.path) is not a valid IPSW. Choose a different file."
            case let .unexpectedHTTP(url, _): "Unable to download the IPSW from \(url). Try again later."
            case let .incompleteDownload(url, expected, actual):
                "The IPSW download from \(url) is incomplete (\(actual) of \(expected) bytes). Try again."
            case let .changedDuringDownload(url):
                "The IPSW at \(url) changed on the server while it downloaded. Try again."
            case let .swappedSources(iPhone, cloudOS):
                "The iPhone and cloudOS IPSWs are swapped: \(iPhone.lastPathComponent) is a cloudOS IPSW and \(cloudOS.lastPathComponent) is an iPhone IPSW. Swap the two sources, then try again."
            case let .notIPhoneSource(file, productTypes):
                "\(file.lastPathComponent) is not an IPSW vphone can run; it is for \(productTypes.isEmpty ? "no listed product" : productTypes.joined(separator: ", ")). Choose an IPSW for \(VPhoneIPSWCache.guestProductTypes.joined(separator: " or ")) as the iPhone source."
            case let .notCloudOSSource(file):
                "\(file.lastPathComponent) is not a cloudOS IPSW: it has no \(VPhoneIPSWCache.cloudOSDeviceClass) build identity. Choose a cloudOS IPSW as the cloudOS source."
            }
        }
    }

    /// `progress` is called with `(bytesDone, totalBytes)` while a remote
    /// IPSW downloads, only when the server states the size. A local source
    /// or a cache hit never calls it. Reports come one at a time, even while
    /// several connections download.
    ///
    /// `connections` is how many range requests download the IPSW at once when
    /// its server answers them; 1 downloads it as one GET.
    public static func resolve(
        _ source: String,
        in cacheDirectory: URL,
        session: URLSession = URLSession(configuration: .ephemeral),
        connections: Int = defaultDownloadConnections,
        decryptionKey: String? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil,
    ) async throws -> Archive {
        let release = VPhoneFirmwareCatalog.darwinRestoreRelease(source: source)
        let decryptionKey = decryptionKey ?? release?.key
        let cacheDirectory = release == nil ? cacheDirectory
            : cacheDirectory.appendingPathComponent(VPhoneOTARelease.cacheDirectoryName, isDirectory: true)
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return try inspect(URL(fileURLWithPath: source), decryptionKey: decryptionKey)
        }
        if scheme == "file" {
            return try inspect(url, decryptionKey: decryptionKey)
        }
        guard scheme == "http" || scheme == "https" else {
            throw Error.unsupportedSource(source)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Before anything can fail: the directory is shared, and one made by a
        // sudo run must stay writable for the next run without sudo.
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: cacheDirectory)
        removeAbandonedDownloads(in: cacheDirectory)
        let cache = cacheDirectory.appendingPathComponent(cacheName(for: url))
        if let valid = try reuse(cache, in: cacheDirectory, decryptionKey: decryptionKey, expectedSize: release?.size) {
            return valid
        }

        let pending = cacheDirectory.appendingPathComponent(".\(cache.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: pending) }
        guard fm.createFile(atPath: pending.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await download(url, into: pending, session: session, connections: connections, progress: progress)

        if let expected = release?.size {
            let actual = try fm.attributesOfItem(atPath: pending.path)[.size] as? Int64 ?? 0
            guard actual == expected else { throw Error.incompleteDownload(url, expected: expected, actual: actual) }
        }
        let metadata = try inspect(pending, decryptionKey: decryptionKey)
        do {
            try fm.moveItem(at: pending, to: cache)
        } catch {
            // Another machine's prepare finished the same URL first.
            if let valid = try reuse(cache, in: cacheDirectory, decryptionKey: decryptionKey, expectedSize: release?.size) {
                return valid
            }
            throw error
        }
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return Archive(
            file: cache,
            version: metadata.version,
            build: metadata.build,
            productTypes: metadata.productTypes,
            deviceClasses: metadata.deviceClasses,
        )
    }

    /// `source` as ``resolve(_:in:session:connections:progress:)`` would
    /// return it, without downloading: a local file is read in place, a
    /// remote one only when the cache holds a readable copy. Nil when a
    /// remote source is not in the cache, or a local one no longer exists
    /// (the caller then looks elsewhere, such as a template recorded with the
    /// same source); a local file that exists but is not an IPSW still
    /// throws. Nothing is written or removed.
    public static func localArchive(_ source: String, in cacheDirectory: URL, decryptionKey: String? = nil) throws -> Archive? {
        let release = VPhoneFirmwareCatalog.darwinRestoreRelease(source: source)
        let decryptionKey = decryptionKey ?? release?.key
        let cacheDirectory = release == nil ? cacheDirectory
            : cacheDirectory.appendingPathComponent(VPhoneOTARelease.cacheDirectoryName, isDirectory: true)
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return try inspectIfPresent(URL(fileURLWithPath: source), decryptionKey: decryptionKey)
        }
        if scheme == "file" {
            return try inspectIfPresent(url, decryptionKey: decryptionKey)
        }
        guard scheme == "http" || scheme == "https" else {
            throw Error.unsupportedSource(source)
        }
        let cache = cacheDirectory.appendingPathComponent(cacheName(for: url))
        guard FileManager.default.fileExists(atPath: cache.path) else { return nil }
        if let expected = release?.size,
           (try FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? Int64) != expected { return nil }
        return try? inspect(cache, decryptionKey: decryptionKey)
    }

    /// A local IPSW, or nil when nothing is at its path (a dangling link
    /// included).
    private static func inspectIfPresent(_ file: URL, decryptionKey: String?) throws -> Archive? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try inspect(file, decryptionKey: decryptionKey)
    }

    /// The cached archive when it is readable; an unreadable one is removed.
    private static func reuse(_ cache: URL, in _: URL, decryptionKey: String?, expectedSize: Int64?) throws -> Archive? {
        guard FileManager.default.fileExists(atPath: cache.path) else { return nil }
        if let expectedSize,
           (try FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? Int64) != expectedSize {
            try FileManager.default.removeItem(at: cache)
            return nil
        }
        guard let valid = try? inspect(cache, decryptionKey: decryptionKey) else {
            try FileManager.default.removeItem(at: cache)
            return nil
        }
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return valid
    }

    /// A download still in progress writes to its `.partial` file continuously.
    /// One untouched for an hour belongs to a process that was killed, and in a
    /// shared cache nothing else would ever remove it.
    private static func removeAbandonedDownloads(in cacheDirectory: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        let cutoff = Date().addingTimeInterval(-60 * 60)
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            let file = cacheDirectory.appendingPathComponent(name)
            guard let modified = try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            try? fm.removeItem(at: file)
        }
    }

    /// The IPSW's BuildManifest, read without unpacking anything else.
    public static func buildManifest(of file: URL, decryptionKey: String? = nil) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Error.missingFile(file)
        }
        if try VPhoneDarwinRestoreArchive.isArchive(file) {
            // The catalog key also recognizes a renamed local archive by its
            // authenticated contents. No filename is trusted as device identity.
            if let decryptionKey {
                return try VPhoneDarwinRestoreArchive.buildManifest(of: file, key: decryptionKey)
            }
            let named = VPhoneFirmwareCatalog.darwinRestoreRelease(source: file.path)?.key
            let keys = [named].compactMap { $0 } + VPhoneFirmwareCatalog.darwinRestoreReleases.compactMap(\.key)
            for key in Set(keys) {
                if let manifest = try? VPhoneDarwinRestoreArchive.buildManifest(of: file, key: key) { return manifest }
            }
            return try VPhoneDarwinRestoreArchive.buildManifest(of: file)
        }
        guard let data = try? VPhoneArchiveReader.readMember("BuildManifest.plist", from: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any]
        else {
            throw Error.invalidManifest(file)
        }
        return plist
    }

    public static func inspect(_ file: URL, decryptionKey: String? = nil) throws -> Archive {
        let plist = try buildManifest(of: file, decryptionKey: decryptionKey)
        guard let version = plist["ProductVersion"] as? String, !version.isEmpty,
              let build = plist["ProductBuildVersion"] as? String, !build.isEmpty
        else {
            throw Error.invalidManifest(file)
        }
        let identities = plist["BuildIdentities"] as? [[String: Any]] ?? []
        let deviceClasses = identities.compactMap { identity in
            ((identity["Info"] as? [String: Any])?["DeviceClass"] as? String)?.lowercased()
        }
        return Archive(
            file: file,
            version: version,
            build: build,
            productTypes: plist["SupportedProductTypes"] as? [String] ?? [],
            deviceClasses: Set(deviceClasses),
        )
    }

    // MARK: - Download

    /// Connections one remote IPSW downloads over when its server answers
    /// range requests. Apple's CDN holds each connection well below a fast
    /// link: four measured about 2.7 times the throughput of one.
    public static let defaultDownloadConnections = 4

    /// Bytes each range request asks for. Connections take segments in order,
    /// so the partial file grows from the front, and a dropped connection
    /// fetches again only what it had not yet written of one segment.
    static let segmentSize: Int64 = 32 * 1024 * 1024

    /// Range requests that make no progress this many times in a row fail the
    /// download. Progress resets the count, so a long transfer survives any
    /// number of dropped connections that each moved it forward.
    static let segmentAttempts = 5

    /// Writes the IPSW into `file`, which exists and is empty, in place on the
    /// cache's own volume with no temporary copy. `download(for:)` would stage
    /// it in the system temporary directory, which may be another volume, and
    /// iterating `bytes(for:)` one byte at a time was CPU-bound (issue #524).
    ///
    /// With more than one connection and a server that answers range requests,
    /// the file downloads as segments over that many connections at once.
    /// Otherwise it is one GET, as a server that ignores ranges requires.
    static func download(
        _ url: URL,
        into file: URL,
        session: URLSession,
        connections: Int,
        segmentSize: Int64 = segmentSize,
        progress: (@Sendable (Int64, Int64) -> Void)?,
    ) async throws {
        let fd = open(file.path, O_WRONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        let counter = ProgressCounter(progress)
        if connections > 1, let resource = await probeRanges(url, session: session), resource.size > segmentSize {
            try await downloadSegments(
                resource,
                into: fd,
                configuration: session.configuration,
                connections: connections,
                segmentSize: segmentSize,
                counter: counter,
            )
        } else {
            try await downloadStream(url, into: fd, session: session, counter: counter)
        }
    }

    /// One GET for the whole body. A non-200 response returns before any body.
    private static func downloadStream(
        _ url: URL,
        into fd: Int32,
        session: URLSession,
        counter: ProgressCounter,
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3 * 60 * 60
        let outcome = await transfer(
            request,
            session: session,
            into: fd,
            at: 0,
            accept: { $0.statusCode == 200 },
            received: { count, response in counter.add(count, of: response.expectedContentLength) },
        )
        try Task.checkCancellation()
        if let error = outcome.writeError {
            throw error
        }
        guard let response = outcome.response else {
            throw outcome.transportError ?? URLError(.badServerResponse)
        }
        guard outcome.accepted else {
            throw Error.unexpectedHTTP(url, response.statusCode)
        }
        if let error = outcome.transportError {
            throw error
        }
        if response.expectedContentLength > 0, outcome.written != response.expectedContentLength {
            throw Error.incompleteDownload(url, expected: response.expectedContentLength, actual: outcome.written)
        }
    }

    // MARK: Segments

    struct RangedResource: Sendable {
        let url: URL
        let size: Int64
        /// The ETag, else Last-Modified, sent as If-Range so a file replaced
        /// on the server midway fails instead of mixing two files' bytes.
        let validator: String?
    }

    /// Asks for the first byte and cancels at the headers. A server that
    /// answers ranges says 206 and gives the full size in Content-Range; one
    /// that ignores them says 200. Apple's CDN answers range requests without
    /// advertising Accept-Ranges, so that header is not consulted. Any failure
    /// returns nil, and the single GET that follows reports it.
    static func probeRanges(_ url: URL, session: URLSession) async -> RangedResource? {
        let outcome = await transfer(
            rangeRequest(url, 0 ... 0, validator: nil),
            session: session,
            into: -1,
            at: 0,
            accept: { _ in false },
            received: { _, _ in },
        )
        guard let response = outcome.response, response.statusCode == 206,
              let range = contentRange(of: response), range.start == 0, range.total > 0
        else {
            return nil
        }
        let etag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        return RangedResource(
            url: url,
            size: range.total,
            validator: etag ?? response.value(forHTTPHeaderField: "Last-Modified"),
        )
    }

    private static func downloadSegments(
        _ resource: RangedResource,
        into fd: Int32,
        configuration: URLSessionConfiguration,
        connections: Int,
        segmentSize: Int64,
        counter: ProgressCounter,
    ) async throws {
        let segments = SegmentQueue(size: resource.size, segmentSize: segmentSize)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< min(connections, segments.count) {
                group.addTask {
                    // A session of its own: one session sends every request to
                    // a host over a single HTTP/2 connection, which would leave
                    // the workers sharing one connection's throughput.
                    let session = URLSession(configuration: configuration)
                    defer { session.invalidateAndCancel() }
                    while let segment = segments.next() {
                        try await downloadSegment(segment, of: resource, into: fd, session: session, counter: counter)
                    }
                }
            }
            try await group.waitForAll()
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_size == resource.size else {
            throw Error.incompleteDownload(resource.url, expected: resource.size, actual: info.st_size)
        }
    }

    /// Fetches one segment, resuming from the last byte written whenever a
    /// connection drops or a server error comes back.
    private static func downloadSegment(
        _ segment: ClosedRange<Int64>,
        of resource: RangedResource,
        into fd: Int32,
        session: URLSession,
        counter: ProgressCounter,
    ) async throws {
        var offset = segment.lowerBound
        var failures = 0
        while offset <= segment.upperBound {
            let start = offset
            let outcome = await transfer(
                rangeRequest(resource.url, start ... segment.upperBound, validator: resource.validator),
                session: session,
                into: fd,
                at: start,
                limit: segment.upperBound - start + 1,
                accept: { response in
                    let range = contentRange(of: response)
                    return response.statusCode == 206 && range?.start == start && range?.total == resource.size
                },
                received: { count, _ in counter.add(count, of: resource.size) },
            )
            try Task.checkCancellation()
            if let error = outcome.writeError {
                throw error
            }
            offset += outcome.written
            if let response = outcome.response, !outcome.accepted {
                switch response.statusCode {
                case 408, 429, 500...:
                    break
                case 200, 206, 412:
                    // 200 is the whole body: If-Range no longer matches.
                    throw Error.changedDuringDownload(resource.url)
                default:
                    throw Error.unexpectedHTTP(resource.url, response.statusCode)
                }
            }
            guard offset <= segment.upperBound else { return }
            failures = outcome.written > 0 ? 1 : failures + 1
            guard failures < segmentAttempts else {
                throw outcome.transportError ?? Error.incompleteDownload(
                    resource.url,
                    expected: segment.upperBound + 1,
                    actual: offset,
                )
            }
            try await Task.sleep(for: .seconds(failures))
        }
    }

    private static func rangeRequest(_ url: URL, _ range: ClosedRange<Int64>, validator: String?) -> URLRequest {
        var request = URLRequest(url: url)
        // An idle connection gives up after a minute and the segment resumes
        // on a new one, instead of hanging the download.
        request.timeoutInterval = 60
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        // Byte offsets must index the file itself, not a compressed encoding.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        return request
    }

    /// `bytes <start>-<end>/<total>`; nil for any other shape, including an
    /// unknown total.
    static func contentRange(of response: HTTPURLResponse) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let spanAndTotal = parts[1].split(separator: "/")
        guard spanAndTotal.count == 2, let total = Int64(spanAndTotal[1]) else { return nil }
        let span = spanAndTotal[0].split(separator: "-")
        guard span.count == 2, let start = Int64(span[0]), let end = Int64(span[1]),
              start <= end, end < total
        else {
            return nil
        }
        return (start, end, total)
    }

    /// Hands out the file's segments in order to every connection.
    private final class SegmentQueue: Sendable {
        let count: Int
        private let size: Int64
        private let segmentSize: Int64
        private let nextIndex = Mutex(0)

        init(size: Int64, segmentSize: Int64) {
            self.size = size
            self.segmentSize = segmentSize
            count = Int((size + segmentSize - 1) / segmentSize)
        }

        func next() -> ClosedRange<Int64>? {
            nextIndex.withLock { index -> ClosedRange<Int64>? in
                guard index < count else { return nil }
                let start = Int64(index) * segmentSize
                index += 1
                return start ... min(start + segmentSize, size) - 1
            }
        }
    }

    /// Adds up the bytes every connection writes and reports the sum one
    /// report at a time, so a progress bar that is not thread-safe can take it.
    private final class ProgressCounter: Sendable {
        private let progress: (@Sendable (Int64, Int64) -> Void)?
        private let done = Mutex<Int64>(0)

        init(_ progress: (@Sendable (Int64, Int64) -> Void)?) {
            self.progress = progress
        }

        func add(_ count: Int64, of total: Int64) {
            guard let progress else { return }
            done.withLock { done in
                done += count
                if total > 0 {
                    progress(done, total)
                }
            }
        }
    }

    // MARK: Transfer

    struct TransferOutcome {
        var response: HTTPURLResponse?
        /// Whether `accept` took the response; a refused one has no body.
        var accepted = false
        var written: Int64 = 0
        var writeError: Swift.Error?
        var transportError: Swift.Error?
    }

    /// One request whose body is written at `offset` onward as it arrives.
    /// Never throws: the caller decides from the outcome whether to resume.
    private static func transfer(
        _ request: URLRequest,
        session: URLSession,
        into fd: Int32,
        at offset: Int64,
        limit: Int64 = .max,
        accept: @escaping @Sendable (HTTPURLResponse) -> Bool,
        received: @escaping @Sendable (Int64, HTTPURLResponse) -> Void,
    ) async -> TransferOutcome {
        let task = session.dataTask(with: request)
        let writer = TransferWriter(fd: fd, offset: offset, limit: limit, accept: accept, received: received)
        task.delegate = writer
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                writer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// URLSession calls one task's delegate serially, and `continuation` is set
    /// before the task resumes, so the mutable state is never shared.
    private final class TransferWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let fd: Int32
        let offset: Int64
        let limit: Int64
        let accept: @Sendable (HTTPURLResponse) -> Bool
        let received: @Sendable (Int64, HTTPURLResponse) -> Void
        var continuation: CheckedContinuation<TransferOutcome, Never>?
        private var outcome = TransferOutcome()

        init(
            fd: Int32,
            offset: Int64,
            limit: Int64,
            accept: @escaping @Sendable (HTTPURLResponse) -> Bool,
            received: @escaping @Sendable (Int64, HTTPURLResponse) -> Void,
        ) {
            self.fd = fd
            self.offset = offset
            self.limit = limit
            self.accept = accept
            self.received = received
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
        ) {
            outcome.response = response as? HTTPURLResponse
            outcome.accepted = outcome.response.map(accept) ?? false
            completionHandler(outcome.accepted ? .allow : .cancel)
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard outcome.writeError == nil, let response = outcome.response else { return }
            do {
                // A segment's bytes may never reach the next segment's, which
                // another connection is writing.
                guard Int64(data.count) <= limit - outcome.written else {
                    throw Error.unexpectedHTTP(
                        dataTask.originalRequest?.url ?? response.url ?? URL(fileURLWithPath: "/"),
                        response.statusCode,
                    )
                }
                try write(data, at: offset + outcome.written)
                outcome.written += Int64(data.count)
                received(Int64(data.count), response)
            } catch {
                outcome.writeError = error
                dataTask.cancel()
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            // A refused response was cancelled on purpose; the caller reads its status.
            if outcome.accepted || outcome.response == nil {
                outcome.transportError = error
            }
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        private func write(_ data: Data, at position: Int64) throws {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var done = 0
                while done < buffer.count {
                    let count = pwrite(fd, base + done, buffer.count - done, off_t(position) + off_t(done))
                    if count < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    done += count
                }
            }
        }
    }

    // MARK: - Pairing

    /// The iPhone IPSW's product, and the cloudOS device class whose boot
    /// chain matches the VM's DFU hardware. The restore tree needs both.
    public static let iPhoneProductType = VPhoneFirmwareCatalog.device
    public static let cloudOSDeviceClass = "vresearch101ap"

    /// Every product whose IPSW can supply the guest OS: the iPhone17,3 the
    /// catalog targets, and the iPads and Apple TV `VPhoneGuestDevice` knows.
    /// A device restored over another's IPSW (`restoreBase`) is not one.
    public static var guestProductTypes: [String] {
        VPhoneGuestDevice.known.filter { $0.restoreBase == nil }.map(\.productType)
    }

    /// The guest device an IPSW supplies, or nil for any other product. An IPSW
    /// that covers several models gives `preferring` when it is one of them, and
    /// its first known model otherwise.
    public static func guestDevice(for archive: Archive, preferring productType: String? = nil) -> VPhoneGuestDevice? {
        let types = archive.productTypes.filter { VPhoneGuestDevice.named($0)?.restoreBase == nil }
        return VPhoneGuestDevice.detect(buildManifest: ["SupportedProductTypes": types], preferring: productType)
    }

    /// Checks each BuildManifest before anything is extracted, so a swapped
    /// or wrong IPSW fails at once with the fix instead of deep in the merge.
    public static func checkPair(iPhone: Archive, cloudOS: Archive) throws {
        let iPhoneIsPhone = guestDevice(for: iPhone) != nil
        let cloudOSIsCloudOS = cloudOS.deviceClasses.contains(cloudOSDeviceClass)
        if !iPhoneIsPhone, !cloudOSIsCloudOS,
           iPhone.deviceClasses.contains(cloudOSDeviceClass),
           guestDevice(for: cloudOS) != nil
        {
            throw Error.swappedSources(iPhone: iPhone.file, cloudOS: cloudOS.file)
        }
        guard iPhoneIsPhone else {
            throw Error.notIPhoneSource(iPhone.file, productTypes: iPhone.productTypes)
        }
        guard cloudOSIsCloudOS else {
            throw Error.notCloudOSSource(cloudOS.file)
        }
    }

    static func cacheName(for url: URL) -> String {
        if let release = VPhoneFirmwareCatalog.darwinRestoreRelease(source: url.absoluteString) { return release.fileName }
        let base = url.lastPathComponent
        let stem = base.lowercased().hasSuffix(".ipsw") ? String(base.dropLast(5)) : base
        let safe = String(stem.prefix(48).unicodeScalars.map { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122) || value == 45 || value == 46 || value == 95
                ? Character(scalar) : "_"
        })
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe.isEmpty ? "firmware" : safe)-\(suffix).ipsw"
    }
}
