import Foundation

/// Suggests manual wired-LAN network settings for the camera, derived from the Mac's own
/// self-assigned link-local address on the same cable. A direct Mac-to-camera Ethernet link has no
/// DHCP server, so a camera whose network profile requires DHCP sits waiting (indefinitely, on some
/// bodies) for an address it will never get. Manual IP settings skip that negotiation entirely — the
/// only real requirement is landing the camera in the same 169.254.0.0/16 block as the Mac.
public struct CameraNetworkSuggestion: Equatable {
    public let macIP: String
    public let cameraIP: String
    public let subnetMask = "255.255.0.0"

    /// `nil` if `macIP` isn't a link-local (169.254.x.x) address — the only case this applies to.
    public init?(macIP: String) {
        let octets = macIP.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets[0] == 169, octets[1] == 254,
              octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        self.macIP = macIP

        // Same third octet, a different last octet — same /16 subnet either way, but keeping the
        // third octet matched makes the two addresses read as obviously related to someone typing
        // this into the camera's menu by hand.
        let thirdOctet = octets[2]
        let lastOctet = octets[3]
        var suggestedLast = (lastOctet % 254) + 1 // 1...254, never 0 or 255
        if suggestedLast == lastOctet {
            suggestedLast = (suggestedLast % 254) + 1
        }
        self.cameraIP = "169.254.\(thirdOctet).\(suggestedLast)"
    }
}
