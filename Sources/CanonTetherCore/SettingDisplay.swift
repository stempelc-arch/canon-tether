import Foundation

/// Display mapping for camera config values. The underlying value (what gets sent back via
/// `set-config`) is never changed — this only affects what the inspector shows, and in what order.
///
/// gphoto2 hands us Canon's raw vocabulary, which is a poor menu on two counts: image formats come
/// through as terse internal codes ("cM1 + cS3"), and white balance arrives in Canon's numeric
/// property order with placeholder slots mixed in. Both are cleaned up here rather than in the view.
public enum SettingDisplay {
    public static let whiteBalancePath = "/main/imgsettings/whitebalance"
    public static let imageFormatPath = "/main/imgsettings/imageformat"

    // MARK: - White balance

    /// Canon's presets, renamed for the menu. Presets with a fixed color temperature carry it next
    /// to the name: the number alone is ambiguous, since Cloudy and Flash are both 6000K. The
    /// custom sets are Canon's "Custom WB" registers — libgphoto2 calls them Manual/Manual 2…5.
    private static let whiteBalanceLabels: [String: String] = [
        "Auto": "Auto (AWB)",
        "AWB White": "Auto — White Priority",
        "Tungsten": "Tungsten · 3200K",
        "Fluorescent": "Fluorescent · 4000K",
        "Daylight": "Daylight · 5200K",
        "Flash": "Flash · 6000K",
        "Cloudy": "Cloudy · 6000K",
        "Shade": "Shade · 7000K",
        "Shadow": "Shade · 7000K",
        "Color Temperature": "Color Temperature (K)",
        "Manual": "Custom WB 1",
        "Manual 2": "Custom WB 2",
        "Manual 3": "Custom WB 3",
        "Manual 4": "Custom WB 4",
        "Manual 5": "Custom WB 5",
        "Custom Whitebalance: PC-1": "PC Custom 1",
        "Custom Whitebalance: PC-2": "PC Custom 2",
        "Custom Whitebalance: PC-3": "PC Custom 3",
        "Custom Whitebalance: PC-4": "PC Custom 4",
        "Custom Whitebalance: PC-5": "PC Custom 5"
    ]

    /// Menu order: the two auto modes, then the fixed presets coolest → warmest, then the
    /// user-defined sets. Canon's own property order is by internal opcode, which interleaves these.
    private static let whiteBalanceOrder = [
        "Auto", "AWB White",
        "Tungsten", "Fluorescent", "Daylight", "Flash", "Cloudy", "Shade", "Shadow",
        "Color Temperature",
        "Manual", "Manual 2", "Manual 3", "Manual 4", "Manual 5",
        "Custom Whitebalance: PC-1", "Custom Whitebalance: PC-2", "Custom Whitebalance: PC-3",
        "Custom Whitebalance: PC-4", "Custom Whitebalance: PC-5"
    ]

    /// Canon uses one opcode space for white balance in two places: the PTP property gphoto2
    /// reports by name, and the `WhiteBalanceIndex` in a captured file's Canon MakerNote. Mapping
    /// the index back onto the same names means the preview's EXIF readout and the inspector menu
    /// can never disagree about what a preset is called.
    private static let whiteBalanceByIndex: [Int: String] = [
        0: "Auto",
        1: "Daylight",
        2: "Cloudy",
        3: "Tungsten",
        4: "Fluorescent",
        5: "Flash",
        6: "Manual",
        8: "Shadow",
        9: "Color Temperature",
        10: "Custom Whitebalance: PC-1",
        11: "Custom Whitebalance: PC-2",
        12: "Custom Whitebalance: PC-3",
        15: "Manual 2",
        16: "Manual 3",
        18: "Manual 4",
        19: "Manual 5",
        20: "Custom Whitebalance: PC-4",
        21: "Custom Whitebalance: PC-5",
        23: "AWB White"
    ]

    /// Modes that can appear in a file's MakerNote but aren't in the settable PTP list, so they
    /// have no gphoto2 name to route through.
    private static let whiteBalanceIndexOnlyLabels: [Int: String] = [
        7: "Black & White",
        14: "Daylight Fluorescent",
        17: "Underwater"
    ]

    // MARK: - Image format

    /// Canon's single-slot format codes. The camera combines two of them per choice ("RAW + L"),
    /// one per card slot / RAW+JPEG pair. A leading `c` is Canon's Normal (more compressed) JPEG
    /// quality; bare codes are Fine. See `canon_eos_single_ImageFormats` in libgphoto2's config.c.
    private static let imageFormatCodes: [String: String] = [
        "RAW": "RAW",
        "mRAW": "mRAW",
        "sRAW": "sRAW",
        "cRAW": "cRAW",
        "L": "Large Fine JPEG",
        "cL": "Large Normal JPEG",
        "M": "Medium Fine JPEG",
        "cM": "Medium Normal JPEG",
        "M1": "Medium 1 Fine JPEG",
        "cM1": "Medium 1 Normal JPEG",
        "M2": "Medium 2 Fine JPEG",
        "cM2": "Medium 2 Normal JPEG",
        "S": "Small Fine JPEG",
        "cS": "Small Normal JPEG",
        "S1": "Small 1 Fine JPEG",
        "cS1": "Small 1 Normal JPEG",
        "S2": "Small 2 Fine JPEG",
        "cS2": "Small 2 Normal JPEG",
        "S3": "Small 3 Fine JPEG",
        "cS3": "Small 3 Normal JPEG"
    ]

    private static let componentSeparator = " + "

    // MARK: - Public API

    /// The label to show for a config `value` at `path`: the renamed preset for white balance, the
    /// expanded format name for image format, and the value unchanged for everything else. Values
    /// this doesn't recognise are passed through verbatim so nothing is ever shown as blank.
    public static func label(forValue value: String, path: String) -> String {
        switch path {
        case whiteBalancePath:
            return whiteBalanceLabels[value] ?? value
        case imageFormatPath:
            let parts = value.components(separatedBy: componentSeparator)
            guard parts.allSatisfy({ imageFormatCodes[$0] != nil }) else { return value }
            return parts.map { imageFormatCodes[$0]! }.joined(separator: componentSeparator)
        default:
            return value
        }
    }

    /// The white balance a capture was shot at, from the Canon MakerNote's `WhiteBalanceIndex`,
    /// labelled exactly as the inspector's menu labels it. Nil for an index Canon hasn't documented.
    public static func whiteBalanceLabel(makerNoteIndex index: Int) -> String? {
        if let value = whiteBalanceByIndex[index] {
            return label(forValue: value, path: whiteBalancePath)
        }
        return whiteBalanceIndexOnlyLabels[index]
    }

    /// The choices to offer for `path`, cleaned up: placeholder and unrecognised entries dropped,
    /// white balance put in a sensible order. `current` is always kept, even if it would otherwise
    /// be filtered out — the menu must be able to show the state the camera is actually in.
    public static func choices(_ choices: [String], path: String, current: String) -> [String] {
        switch path {
        case whiteBalancePath:
            let kept = choices.filter { $0 == current || whiteBalanceLabels[$0] != nil }
            // Values missing from the order list (a preset newer than this table) keep the
            // camera's own relative position, after everything known.
            return kept.enumerated().sorted { lhs, rhs in
                let l = whiteBalanceOrder.firstIndex(of: lhs.element) ?? whiteBalanceOrder.count + lhs.offset
                let r = whiteBalanceOrder.firstIndex(of: rhs.element) ?? whiteBalanceOrder.count + rhs.offset
                return l < r
            }.map(\.element)
        case imageFormatPath:
            // libgphoto2 renders a slot it has no name for as raw hex ("0x4f"); those choices are
            // unusable in a menu. Camera order is otherwise meaningful, so it's preserved.
            return choices.filter { $0 == current || isKnownImageFormat($0) }
        default:
            return choices
        }
    }

    private static func isKnownImageFormat(_ value: String) -> Bool {
        value.components(separatedBy: componentSeparator).allSatisfy { imageFormatCodes[$0] != nil }
    }
}
