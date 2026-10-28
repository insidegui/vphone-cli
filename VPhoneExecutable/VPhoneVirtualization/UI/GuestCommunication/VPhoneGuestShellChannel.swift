import CryptoKit
import Foundation
import Virtualization

/// A VSOCK connection on its way off the main actor. `VZVirtioSocketConnection`
/// is not Sendable and the guest control is main-actor isolated, so a stream
/// crosses to its reader the way every other connection in this file does:
/// wrapped, and handed over exactly once.
struct VPhoneGuestStream: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
}

/// A client for vphoned's `/v1/shell`: one WebSocket over a VSOCK connection
/// of its own, carrying a pseudo-terminal's byte stream both ways.
///
/// The VM process speaks vphoned's own request/response protocol everywhere
/// else, so this is the only WebSocket it opens, and it is deliberately the
/// smallest one that route needs. The guest sends binary frames of terminal
/// output and one text frame saying how the session ended; this side sends
/// binary frames of input and the occasional control message. Frames from a
/// client must be masked, which is the one piece of the protocol a server
/// implementation does not already cover.
///
/// `onOutput` and `onEnd` arrive on the channel's reader thread, and `onEnd`
/// exactly once. The reader owns the connection: it is the only thing that
/// closes it, so a late write can never reach a descriptor the guest has
/// handed to something else.
final class VPhoneGuestShellChannel: @unchecked Sendable {
    /// What a session runs, and how large its terminal starts out.
    struct Options: Sendable {
        /// Nil for vphoned's own JavaScript session; a bare name resolved
        /// from the bootstrap, or an absolute path, for a program.
        var program: String?
        var columns: Int
        var rows: Int
        var port: Int?

        init(program: String? = nil, columns: Int = 80, rows: Int = 24) {
            self.program = program
            self.columns = columns
            self.rows = rows
        }
    }

    /// How a session finished, as the guest's last text frame reported it.
    enum Ending: Sendable {
        case exited(Int)
        case signalled(Int)
        /// The session could not be opened, or the connection broke first.
        case failed(String)
    }

    enum ChannelError: Error, CustomStringConvertible {
        case handshakeFailed(String)
        case refused(String)

        var description: String {
            switch self {
            case let .handshakeFailed(detail): "The guest would not open a shell session: \(detail)"
            case let .refused(message): message
            }
        }
    }

    private let connection: VZVirtioSocketConnection
    private let descriptor: Int32
    private let onOutput: @Sendable (Data) -> Void
    private let onEnd: @Sendable (Ending) -> Void

    /// Guards writing and the one-shot teardown. Writes are short, so holding
    /// it across one is cheaper than reasoning about a half-written frame.
    private let lock = NSLock()
    private var closing = false
    private var finished = false

    private init(
        connection: VZVirtioSocketConnection,
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (Ending) -> Void,
    ) {
        self.connection = connection
        descriptor = connection.fileDescriptor
        self.onOutput = onOutput
        self.onEnd = onEnd
    }

    // MARK: - Opening

    /// Opens a session and starts reading it. Throws when the guest refused
    /// the upgrade, in which case nothing was started and `onEnd` never runs.
    static func open(
        control: VPhoneGuestControl,
        options: Options,
        onOutput: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (Ending) -> Void,
    ) async throws -> VPhoneGuestShellChannel {
        let connection = try await control.openGuestStream().connection
        let channel = VPhoneGuestShellChannel(connection: connection, onOutput: onOutput, onEnd: onEnd)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try channel.handshake(options: options)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            connection.close()
            throw error
        }
        let reader = Thread { channel.readFrames() }
        reader.name = "vphone.guest.shell.reader"
        reader.stackSize = 512 * 1024
        reader.start()
        return channel
    }

    private func handshake(options: Options) throws {
        // The guest never sends this side a signal it cannot handle, but a
        // write to a session that just ended would otherwise end the VM.
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ChannelError.handshakeFailed("the connection was refused")
        }
        // No receive timeout on purpose: a terminal waiting for someone to
        // type is the normal state, and every other route's 120 seconds would
        // read as a broken session.
        var key = Data(count: 16)
        key.withUnsafeMutableBytes { buffer in
            if let base = buffer.bindMemory(to: UInt8.self).baseAddress {
                for index in 0 ..< buffer.count { base[index] = UInt8.random(in: 0 ... 255) }
            }
        }
        let nonce = key.base64EncodedString()

        var query = ["cols=\(max(1, min(options.columns, 9999)))", "rows=\(max(1, min(options.rows, 9999)))"]
        if let program = options.program, !program.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
            query.insert("program=\(program.addingPercentEncoding(withAllowedCharacters: allowed) ?? program)", at: 0)
        }
        // `Host` has to be a name vphoned reads as local, and no `Origin`:
        // together they are what tells it this is not a web page. Over VSOCK
        // there is no token, which is the host proxy's concern alone.
        let route = options.port.map { "/v1/ports/\($0)" } ?? "/v1/shell?\(query.joined(separator: "&"))"
        let request = """
        GET \(route) HTTP/1.1\r
        Host: vphoned\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(nonce)\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        try writeAll(Data(request.utf8))

        var head = Data()
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard head.count < 16384, let more = readSome() else {
                throw ChannelError.handshakeFailed("it closed the connection without answering")
            }
            head.append(more)
        }
        guard let separator = head.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: head[head.startIndex ..< separator.lowerBound], encoding: .utf8)
        else {
            throw ChannelError.handshakeFailed("its answer was not a readable HTTP response")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.contains(" 101 ") else {
            throw ChannelError.handshakeFailed(lines.first ?? "it sent no status line")
        }
        let expected = Data(Insecure.SHA1.hash(
            data: Data((nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8),
        )).base64EncodedString()
        let accepted = lines.contains { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "sec-websocket-accept" else { return false }
            return parts[1].trimmingCharacters(in: .whitespaces) == expected
        }
        guard accepted else {
            throw ChannelError.handshakeFailed("its Sec-WebSocket-Accept did not match this request")
        }
        // Whatever arrived with the response head is already session output.
        pending = Data(head[separator.upperBound...])
    }

    // MARK: - Reading

    /// Bytes read past the end of the handshake, and past the end of a frame.
    /// Only the reader touches this after `open` returns.
    private var pending = Data()

    private func readSome() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes[0 ..< count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// Exactly `count` bytes, or nil once the connection ends.
    private func readExactly(_ count: Int) -> Data? {
        while pending.count < count {
            guard let more = readSome() else { return nil }
            pending.append(more)
        }
        let taken = Data(pending.prefix(count))
        pending = Data(pending.dropFirst(count))
        return taken
    }

    private func readFrames() {
        var ending: Ending = .failed("The session ended before it said how")
        var message = Data()
        var messageOpcode: UInt8 = 0

        frames: while true {
            guard let header = readExactly(2) else { break }
            let first = header[header.startIndex]
            let second = header[header.startIndex + 1]
            let isFinal = first & 0x80 != 0
            let opcode = first & 0x0F
            let masked = second & 0x80 != 0
            var length = Int(second & 0x7F)
            if length == 126 {
                guard let extended = readExactly(2) else { break }
                length = Int(extended[extended.startIndex]) << 8 | Int(extended[extended.startIndex + 1])
            } else if length == 127 {
                guard let extended = readExactly(8) else { break }
                length = 0
                for byte in extended {
                    // A frame this side could not hold is a protocol error
                    // rather than something to try to buffer.
                    guard length < Int.max >> 8 else { break frames }
                    length = length << 8 | Int(byte)
                }
            }
            guard length <= 8 << 20 else { break }
            var mask = Data()
            if masked {
                guard let read = readExactly(4) else { break }
                mask = read
            }
            guard var body = length > 0 ? readExactly(length) : Data() else { break }
            if masked, !mask.isEmpty {
                for index in 0 ..< body.count {
                    body[body.startIndex + index] ^= mask[mask.startIndex + index % 4]
                }
            }

            switch opcode {
            case 0x0:
                message.append(body)
            case 0x1, 0x2:
                message = body
                messageOpcode = opcode
            case 0x8:
                break frames
            case 0x9:
                write(opcode: 0xA, payload: body)
                continue
            case 0xA:
                continue
            default:
                break frames
            }
            guard isFinal else { continue }
            if messageOpcode == 0x2 {
                if !message.isEmpty { onOutput(message) }
            } else if let described = Self.ending(from: message) {
                ending = described
            }
            message = Data()
        }

        finish(ending)
    }

    /// The guest's last text frame: `{"exit": n}`, `{"signal": n}`, or
    /// `{"error": message}` when it could not open a session at all.
    private static func ending(from payload: Data) -> Ending? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let message = object["error"] as? String { return .failed(message) }
        if let signal = (object["signal"] as? NSNumber)?.intValue { return .signalled(signal) }
        if let status = (object["exit"] as? NSNumber)?.intValue { return .exited(status) }
        return nil
    }

    // MARK: - Writing

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        write(opcode: 0x2, payload: data)
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        control(["resize": [min(columns, 9999), min(rows, 9999)]])
    }

    func signal(_ name: String) {
        control(["signal": name])
    }

    private func control(_ message: [String: Any]) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: message) else { return }
        write(opcode: 0x1, payload: encoded)
    }

    private func write(opcode: UInt8, payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closing, !finished else { return }
        try? writeAll(Self.frame(opcode: opcode, payload: payload))
    }

    /// One frame, masked as a client's frames must be.
    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            out.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8(count >> 8))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((count >> shift) & 0xFF))
            }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        for index in 0 ..< 4 { mask[index] = UInt8.random(in: 0 ... 255) }
        out.append(contentsOf: mask)
        var masked = payload
        for index in 0 ..< masked.count {
            masked[masked.startIndex + index] ^= mask[index % 4]
        }
        out.append(masked)
        return out
    }

    private func writeAll(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), buffer.count - sent)
                if count > 0 {
                    sent += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw ChannelError.handshakeFailed(String(cString: strerror(errno)))
            }
        }
    }

    // MARK: - Ending

    /// Asks the session to end. The reader sees the connection close and
    /// reports the ending; nothing here closes the connection itself.
    func close() {
        lock.lock()
        let alreadyClosing = closing || finished
        closing = true
        lock.unlock()
        guard !alreadyClosing else { return }
        // A close frame is the polite half; the shutdown is what ends a guest
        // that would otherwise keep the terminal open.
        try? writeAll(Self.frame(opcode: 0x8, payload: Data([0x03, 0xE8])))
        shutdown(descriptor, SHUT_WR)
    }

    /// Runs once, on the reader thread, after the frames have stopped.
    private func finish(_ ending: Ending) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        connection.close()
        onEnd(ending)
    }
}
