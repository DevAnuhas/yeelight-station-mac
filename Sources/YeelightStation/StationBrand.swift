import AppKit
import SwiftUI

@MainActor
enum StationBrand {
    private static var images: [ColorScheme: NSImage] = [:]

    enum ResourceError: LocalizedError {
        case missingBundle
        case missingImage(String)
        case unreadableImage(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle:
                return "The Yeelight logo resource bundle is missing from the app."
            case .missingImage(let name):
                return "The Yeelight logo resource \(name).png is missing."
            case .unreadableImage(let name):
                return "The Yeelight logo resource \(name).png could not be decoded."
            }
        }
    }

    static func image(for scheme: ColorScheme) -> NSImage {
        if let image = images[scheme] { return image }
        do {
            let image = try loadImage(for: scheme)
            images[scheme] = image
            return image
        } catch {
            NSLog("Yeelight branding: %@", error.localizedDescription)
            // A damaged installation should still open. Prefer the other real
            // logo before falling back to a native symbol.
            if let alternate = try? loadImage(for: scheme == .dark ? .light : .dark) {
                return alternate
            }
            return NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "Yeelight")
                ?? NSImage(size: NSSize(width: 160, height: 36))
        }
    }

    static func validateResources() throws {
        for scheme: ColorScheme in [.light, .dark] {
            _ = try loadImage(for: scheme)
        }
    }

    private static func loadImage(for scheme: ColorScheme) throws -> NSImage {
        let resources: Bundle
        if let url = Bundle.main.url(forResource: "YeelightStationMac_YeelightStation", withExtension: "bundle"),
           let packaged = Bundle(url: url) {
            resources = packaged
        } else if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            // Do not let SwiftPM's generated accessor find a stale build bundle
            // (or trap) when a relocated app is missing its packaged resources.
            throw ResourceError.missingBundle
        } else {
            resources = Bundle.module
        }
        let name = scheme == .dark ? "yeelight-logo-dark" : "yeelight-logo-light"
        guard let url = resources.url(forResource: name, withExtension: "png") else {
            throw ResourceError.missingImage(name)
        }
        guard let image = NSImage(contentsOf: url), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            throw ResourceError.unreadableImage(name)
        }
        return image
    }
}
