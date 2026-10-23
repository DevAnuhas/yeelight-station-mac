import StationCore

/// A channel's LAN property is already namespaced (bright / bg_bright).
struct AdjustmentKey: Hashable {
    let deviceID: String
    let property: String
}

struct Adjustment {
    let entry: DeviceEntry
    let command: (String, [JSONValue])
    let properties: [String: String]
    let revision: Int
}
