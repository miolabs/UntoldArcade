import dnssd
import Foundation

/// Publishes `_coolscan._tcp` on the HTTP port through mDNSResponder. No
/// socket and no run loop: the registration lives as long as the service
/// ref does.
final class BonjourAdvertiser {
    static let serviceType = "_coolscan._tcp"

    private var reference: DNSServiceRef?

    init(name: String, port: UInt16) throws {
        var reference: DNSServiceRef?
        let error = DNSServiceRegister(
            &reference, 0, 0,
            name, Self.serviceType, nil, nil,
            port.bigEndian, 0, nil, nil, nil
        )
        guard error == kDNSServiceErr_NoError, let reference else {
            throw BonjourError.registrationFailed(Int(error))
        }
        self.reference = reference
    }

    deinit {
        if let reference {
            DNSServiceRefDeallocate(reference)
        }
    }

    enum BonjourError: Error, CustomStringConvertible {
        case registrationFailed(Int)
        var description: String {
            switch self {
            case let .registrationFailed(code): "Bonjour registration failed (\(code))"
            }
        }
    }
}
