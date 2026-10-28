import Foundation
import Network
import VPhoneCoreKit

/// A localhost TCP forward to the guest's loopback-only Dropbear listener,
/// through vphoned's existing VSOCK WebSocket byte transport. No guest NIC,
/// guest IP discovery, host API token, or guest UI is needed.
@MainActor
final class VPhoneGuestSSHService {
    private let configURL: URL
    private var listener: NWListener?
    private var connections: [UUID: VPhoneSSHConnection] = [:]
    private var task: Task<Void, Never>?
    private(set) var port: Int?

    init(configURL: URL) { self.configURL = configURL }

    func connect(control: VPhoneGuestControl) {
        guard task == nil, listener == nil else { return }
        task = Task { [weak self, weak control] in
            guard let self, let control else { return }
            defer { self.task = nil }
            do {
                let manifest = try VPhoneVirtualMachineManifest.load(from: configURL)
                let identity = try VPhoneSSHIdentity(machineIdentifier: manifest.machineIdentifier)
                let publicKey = try identity.prepare()
                let result = try await control.call("ssh.configure", params: ["public_key": publicKey])
                guard !Task.isCancelled, control.isConnected,
                      let hostKey = result["host_key"] as? String else { return }
                // The host key is delivered by the VM's authenticated-by-device
                // VSOCK route, not learned from an untrusted TCP connection.
                try identity.trust(hostKey: hostKey)
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.port = listener?.port.map { Int($0.rawValue) }
                            if let port = self.port { print("[ssh] root@127.0.0.1:\(port); use vphone-cli vm ssh <name>") }
                        case let .failed(error):
                            print("[ssh] localhost listener failed: \(error)")
                            self.stop()
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self, weak control] tcp in
                    Task { @MainActor in
                        guard let self, let control, self.connections.count < 64 else { tcp.cancel(); return }
                        let id = UUID()
                        let relay = VPhoneSSHConnection(tcp: tcp) { [weak self] in
                            Task { @MainActor in self?.connections.removeValue(forKey: id) }
                        }
                        self.connections[id] = relay
                        do {
                            var options = VPhoneGuestShellChannel.Options()
                            options.port = 2222
                            let channel = try await VPhoneGuestShellChannel.open(control: control, options: options,
                                onOutput: { relay.deliver($0) }, onEnd: { _ in relay.stop() })
                            relay.attach(channel)
                        } catch { relay.stop() }
                    }
                }
                listener.start(queue: DispatchQueue(label: "com.vphone.ssh.listener"))
            } catch {
                print("[ssh] provisioning failed: \(error)")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        listener?.cancel()
        listener = nil
        port = nil
        for relay in connections.values { relay.stop() }
        connections.removeAll()
    }
}

/// Each direction applies backpressure: the TCP pump reads one chunk after
/// the VSOCK write; the WebSocket reader waits for its TCP write to drain.
private final class VPhoneSSHConnection: @unchecked Sendable {
    private let tcp: NWConnection
    private let onEnd: @Sendable () -> Void
    private let lock = NSLock()
    private var channel: VPhoneGuestShellChannel?
    private var stopped = false

    init(tcp: NWConnection, onEnd: @escaping @Sendable () -> Void) {
        self.tcp = tcp
        self.onEnd = onEnd
        tcp.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        tcp.start(queue: DispatchQueue(label: "com.vphone.ssh.connection"))
    }

    func attach(_ channel: VPhoneGuestShellChannel) {
        lock.lock()
        let gone = stopped
        if !gone { self.channel = channel }
        lock.unlock()
        if gone { channel.close() } else { receive(channel) }
    }

    private func receive(_ channel: VPhoneGuestShellChannel) {
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, ended, error in
            guard let self else { return }
            if let data, !data.isEmpty { channel.send(data) }
            if ended || error != nil { self.stop() }
            else { self.receive(channel) }
        }
    }

    func deliver(_ data: Data) {
        let drained = DispatchSemaphore(value: 0)
        tcp.send(content: data, completion: .contentProcessed { [weak self] error in
            drained.signal()
            if error != nil { self?.stop() }
        })
        drained.wait()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let channel = channel
        self.channel = nil
        lock.unlock()
        tcp.cancel()
        channel?.close()
        onEnd()
    }
}
