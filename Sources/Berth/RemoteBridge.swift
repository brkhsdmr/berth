import BerthCore
import Foundation
import Network
import OSLog

/// Windows'taki Berth'ün bağlandığı küçük TCP sunucusu.
///
/// Windows App (RDP) öndeyken trackpad hareketi Windows'a iletilemiyor: uygulama yapay tuşları
/// geçirmiyor (ölçüldü). Bunun yerine Windows'taki uygulama bu Mac'e kendisi bağlanır ve hareket
/// gelince buradan "TOGGLE" gönderilir. Bağlantıyı Windows açtığı için orada güvenlik duvarı
/// kuralı gerekmez.
///
/// Protokol satır tabanlı: istemci "HELLO <kod> <bilgisayar adı>" der, kod tutarsa "OK" alır.
/// Yalnızca Tailscale (100.64.0.0/10) ve yerel ağ adreslerinden gelen bağlantılar kabul edilir.
final class RemoteBridge: @unchecked Sendable {
    static let port: UInt16 = 47654
    private let log = Logger(subsystem: "io.github.brkhsdmr.berth", category: "RemoteBridge")
    private let queue = DispatchQueue(label: "berth.remote-bridge")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: (connection: NWConnection, name: String)] = [:]
    private var pending: [ObjectIdentifier: NWConnection] = [:]
    private var token = ""
    /// Bağlı bilgisayarların adları değişti (ana iş parçacığında çağrılır).
    var onClientsChange: (@MainActor ([String]) -> Void)?

    func start(token: String) {
        queue.async {
            self.token = token
            guard self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state { self?.log.error("Dinleyici durdu: \(String(describing: error), privacy: .public)") }
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                self.log.error("Dinleyici açılamadı: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.pending.values.forEach { $0.cancel() }
            self.clients.values.forEach { $0.connection.cancel() }
            self.pending = [:]
            self.clients = [:]
            self.publish()
        }
    }

    func updateToken(_ token: String) {
        queue.async {
            self.token = token
            // Eski kodla bağlananlar düşürülür; yeni kodla yeniden bağlanırlar.
            self.clients.values.forEach { $0.connection.cancel() }
            self.clients = [:]
            self.publish()
        }
    }

    /// Sahneyi aç/kapat komutunu gönderir. `title` verilirse yalnızca oturum başlığına uyan
    /// bilgisayara; uyan yoksa hiçbirine. Gönderildiyse true.
    func sendToggle(matchingTitle title: String? = nil) -> Bool {
        queue.sync {
            var targets = Array(clients.values)
            if let title {
                guard let name = RemoteSessionMatcher.match(title: title, computers: targets.map(\.name)) else { return false }
                targets = targets.filter { $0.name == name }
            }
            guard !targets.isEmpty else { return false }
            let data = Data("TOGGLE\n".utf8)
            for client in targets { client.connection.send(content: data, completion: .contentProcessed { _ in }) }
            return true
        }
    }

    // MARK: Bağlantılar

    private func accept(_ connection: NWConnection) {
        guard Self.isTrusted(connection.endpoint) else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        pending[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // Selamlaşmayan bağlantı 10 sn sonra kapanır.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.pending[id] != nil { connection.cancel() }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer + (data ?? Data())
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(...newline)
                self.handle(line, from: connection)
            }
            if complete || error != nil || buffer.count > 4096 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func handle(_ line: String, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        if parts.first == "HELLO", pending[id] != nil {
            guard parts.count >= 2, !token.isEmpty, parts[1] == token else {
                connection.send(content: Data("DENIED\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            pending[id] = nil
            clients[id] = (connection, parts.count > 2 ? parts[2] : "Windows")
            connection.send(content: Data("OK\n".utf8), completion: .contentProcessed { _ in })
            publish()
        } else if parts.first == "PING", clients[id] != nil {
            connection.send(content: Data("PONG\n".utf8), completion: .contentProcessed { _ in })
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        pending[id] = nil
        if clients.removeValue(forKey: id) != nil { publish() }
    }

    private func publish() {
        let names = clients.values.map(\.name).sorted()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onClientsChange?(names) } }
    }

    /// Tailscale (100.64.0.0/10), yerel ağ ve döngü adresleri.
    private static func isTrusted(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let b = [UInt8](address.rawValue)
            guard b.count == 4 else { return false }
            return (b[0] == 100 && (64...127).contains(b[1])) || b[0] == 10 || b[0] == 127
                || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && (16...31).contains(b[1]))
        case .ipv6(let address):
            let b = [UInt8](address.rawValue)
            // Tailscale fd7a:115c:a1e0::/48, yerel fe80::/10, döngü ::1.
            return (b.count == 16 && b[0] == 0xfd && b[1] == 0x7a) || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || address == .loopback
        default:
            return false
        }
    }
}
