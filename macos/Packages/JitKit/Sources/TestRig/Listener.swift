import Foundation
import Network
import Security

/// Loads the server identity from a PKCS#12 file into memory only (`kSecImportToMemoryOnly`), so nothing is
/// added to the login keychain.
func loadIdentity(p12Path: String, password: String) throws -> sec_identity_t {
    guard let data = FileManager.default.contents(atPath: p12Path) else {
        throw RigError.setup("cannot read PKCS#12 file \(p12Path)")
    }
    let options: [String: Any] = [
        kSecImportExportPassphrase as String: password,
        kSecImportToMemoryOnly as String: true,
    ]
    var items: CFArray?
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
    guard status == errSecSuccess else {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw RigError.setup("SecPKCS12Import failed: \(message)")
    }
    guard let entries = items as? [[String: Any]], let entry = entries.first,
        let raw = entry[kSecImportItemIdentity as String]
    else { throw RigError.setup("PKCS#12 file contains no identity") }
    // swift-format-ignore: NeverForceUnwrap
    let identity = raw as! SecIdentity  // CF type bridged from the import dictionary
    guard let secIdentity = sec_identity_create(identity) else {
        throw RigError.setup("sec_identity_create failed")
    }
    return secIdentity
}

func tcpParameters(identity: sec_identity_t?) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    guard let identity else { return NWParameters(tls: nil, tcp: tcp) }
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    sec_protocol_options_set_local_identity(sec, identity)
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
    sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
    return NWParameters(tls: tls, tcp: tcp)
}

/// Starts a listener bound to 127.0.0.1 only. `port` 0 picks a free port; the real one is printed in the
/// READY line.
func startListener(
    parameters: NWParameters, port: Int, role: String, label: String,
    accept: @escaping @Sendable (RigConnection) -> Void
) throws {
    let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready:
            emitReady(port: listener.port?.rawValue ?? 0, role: role)
        case .failed(let error):
            warn("\(role) listener failed: \(error)")
            exit(1)
        default:
            break
        }
    }
    listener.newConnectionHandler = { nw in
        let conn = RigConnection(nw, queue: DispatchQueue(label: label))
        conn.start(ready: { accept(conn) })
    }
    registry.add(listener)
    listener.start(queue: DispatchQueue(label: "\(label).listener"))
}
