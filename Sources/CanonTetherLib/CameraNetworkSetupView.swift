import SwiftUI
import CanonTetherCore

/// Shown from the "waiting for camera" banner: a camera whose wired-LAN profile requires DHCP has
/// no DHCP server to talk to over a direct Mac-to-camera cable, and some bodies will just sit there
/// ("no address assigned by DHCP server") instead of falling back to a self-assigned address.
/// Manual IP settings skip that wait — this reads the Mac's own self-assigned address on the same
/// cable and suggests camera-side values guaranteed to land on the same subnet.
struct CameraNetworkSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var interfaces = NetworkInterfaceScanner.linkLocalInterfaces()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Camera Manual Network Setup")
                .font(.title2.weight(.semibold))

            Text("On the camera's wired-LAN network settings, switch IP address setting from Auto to Manual, then enter:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let suggestion = interfaces.compactMap({ CameraNetworkSuggestion(macIP: $0.ipAddress) }).first {
                VStack(alignment: .leading, spacing: 10) {
                    settingRow("IP address", suggestion.cameraIP)
                    settingRow("Subnet mask", suggestion.subnetMask)
                    settingRow("Gateway", "Disable")
                    settingRow("DNS address", "Disable")
                    settingRow("IP security", "Disable")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

                Text("This Mac is currently self-assigned \(suggestion.macIP) on the same cable — the suggested camera address is on the same 169.254.0.0/16 subnet, so the two can reach each other with no DHCP server involved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No self-assigned (169.254.x.x) network interface found yet — connect the Ethernet cable and wait a few seconds, then reopen this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check Again") { interfaces = NetworkInterfaceScanner.linkLocalInterfaces() }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        // Width fixed, height intrinsic: a hard-coded height shorter than the content crops the
        // title off the top and the Done button off the bottom (seen live at 340pt).
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospaced().weight(.medium))
                .textSelection(.enabled)
        }
    }
}
