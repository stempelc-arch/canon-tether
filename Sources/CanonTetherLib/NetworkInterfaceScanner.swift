import Foundation
import Darwin

/// Reads the Mac's own network interfaces directly via `getifaddrs` — no subprocess, unlike
/// GPhotoSession's `arp -an` (which reads the ARP table, i.e. *other* devices seen on the wire; this
/// reads the Mac's *own* assigned addresses).
enum NetworkInterfaceScanner {
    struct Interface: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let ipAddress: String
    }

    /// Active, non-loopback interfaces currently self-assigned a link-local (169.254.x.x) address —
    /// exactly the state a Mac lands in when directly Ethernet-connected to a camera with no DHCP
    /// server on the link.
    static func linkLocalInterfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            guard ip.hasPrefix("169.254.") else { continue }

            result.append(Interface(name: String(cString: current.pointee.ifa_name), ipAddress: ip))
        }
        return result
    }
}
