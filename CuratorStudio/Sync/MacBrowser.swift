import Foundation
import Network
import Combine

/// Finds Macs running the Curator Studio daemon by browsing for the
/// `_curator._tcp` Bonjour service, then resolves each one to an IP and port.
@MainActor
final class MacBrowser: ObservableObject {

    @Published private(set) var found: [MacHost] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_curator._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handle(results: results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.forEach { $0.cancel() }
        resolvers.removeAll()
        isBrowsing = false
    }

    private func handle(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            resolve(endpoint: result.endpoint, name: name)
        }
    }

    /// Bonjour gives us a service endpoint; a short-lived connection turns it
    /// into an address we can put in a URL.
    private func resolve(endpoint: NWEndpoint, name: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    let address = Self.string(from: host)
                    Task { @MainActor in
                        self?.add(MacHost(name: name, host: address, port: Int(port.rawValue)))
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.resolvers.removeAll { $0 === connection }
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    nonisolated private static func string(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            let raw = "\(address)".components(separatedBy: "%").first ?? "\(address)"
            return "[\(raw)]"
        @unknown default:
            return "\(host)"
        }
    }

    private func add(_ host: MacHost) {
        guard !found.contains(where: { $0.host == host.host && $0.port == host.port }) else { return }
        found.append(host)
    }
}
