import Foundation
import CanonTetherCore

/// Where the HDR look lives between launches.
///
/// Separate from the merge because these are judgement calls, not correctness: how bright a dim room
/// should become, how much contrast to put back after range compression, how much colour survives.
/// They interact, which is exactly why they belong in front of the photographer rather than being
/// tuned from screenshots by someone who cannot see the room.
enum HDRSettings {
    static let key = "hdrLook"

    static func load(from defaults: UserDefaults = .standard) -> HDRLook {
        guard let stored = defaults.dictionary(forKey: key),
              let exposure = stored["exposure"] as? Double,
              let contrast = stored["contrast"] as? Double,
              let saturation = stored["saturation"] as? Double else { return .default }
        return HDRLook(exposureLimit: Float(exposure),
                       contrast: Float(contrast),
                       saturation: Float(saturation))
    }

    static func save(_ look: HDRLook, to defaults: UserDefaults = .standard) {
        defaults.set(["exposure": Double(look.exposureLimit),
                      "contrast": Double(look.contrast),
                      "saturation": Double(look.saturation)], forKey: key)
    }
}
