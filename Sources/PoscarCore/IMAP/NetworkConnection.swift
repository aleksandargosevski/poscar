import Foundation
import Network

/// A thin async wrapper around a TLS `NWConnection`.
final class NetworkConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let host: String

    init(host: String, port: Int, useTLS: Bool) {
        self.host = host
        let parameters: NWParameters = useTLS ? .tls : .tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 60
            tcp.connectionTimeout = 20
        }
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .imaps
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        queue = DispatchQueue(label: "poscar.connection.\(host)")
    }

    func open() async throws {
        let host = host
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            let finish = once.resume
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error), .waiting(let error):
                    finish(.failure(PoscarError.connection("\(host): \(error.localizedDescription)")))
                    connection?.cancel()
                case .cancelled:
                    finish(.failure(PoscarError.connection("\(host): connection closed")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PoscarError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: PoscarError.connection(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: PoscarError.connection("Server closed the connection"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }
}

/// Network.framework may report several states; the continuation must resume only once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
