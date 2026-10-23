import Foundation

/// Documented LAN commands: https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf
/// Timer creation and saving defaults require the selected light to already be on; callers enforce that precondition.
public enum LightDeviceFeatures {
    public static func canUseDeviceTimer(_ device: LightDevice, channel: LightChannel) -> Bool {
        channel == .main && Set(["cron_add", "cron_get", "cron_del"]).isSubset(of: device.support)
    }

    public static func canSaveDefault(_ device: LightDevice, channel: LightChannel) -> Bool {
        device.support.contains(channel.method("set_default"))
    }

    public static func sleepTimer(minutes: Int) throws -> (String, [JSONValue]) {
        guard (1...60).contains(minutes) else {
            throw StationError.invalidResponse("Choose a sleep timer from 1 to 60 minutes.")
        }
        return ("cron_add", [.int(0), .int(minutes)])
    }

    public static var cancelSleepTimer: (String, [JSONValue]) { ("cron_del", [.int(0)]) }

    public static func saveDefault(channel: LightChannel) -> (String, [JSONValue]) {
        (channel.method("set_default"), [])
    }
}
