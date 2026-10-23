import StationCore
import SwiftUI

/// HSV is only an editing coordinate system. The binding always keeps exact 8-bit RGB.
struct StationColorComponents {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = Self.unit(hue)
        self.saturation = Self.unit(saturation)
        self.brightness = Self.unit(brightness)
    }

    init(_ rgb: StationCore.RGBColor, preserving previous: Self? = nil) {
        let r = Double(rgb.red) / 255, g = Double(rgb.green) / 255, b = Double(rgb.blue) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b), delta = maximum - minimum
        brightness = maximum
        saturation = maximum > 0 ? delta / maximum : previous?.saturation ?? 0
        if delta == 0 {
            hue = previous?.hue ?? 0
        } else {
            let sector: Double
            if maximum == r { sector = (g - b) / delta }
            else if maximum == g { sector = (b - r) / delta + 2 }
            else { sector = (r - g) / delta + 4 }
            hue = (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
        }
    }

    var rgb: StationCore.RGBColor {
        let h = (Self.unit(hue) * 6).truncatingRemainder(dividingBy: 6)
        let s = Self.unit(saturation), v = Self.unit(brightness)
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let components: (Double, Double, Double)
        switch h {
        case 0..<1: components = (c, x, 0)
        case 1..<2: components = (x, c, 0)
        case 2..<3: components = (0, c, x)
        case 3..<4: components = (0, x, c)
        case 4..<5: components = (x, 0, c)
        default: components = (c, 0, x)
        }
        func byte(_ value: Double) -> UInt8 { UInt8((Self.unit(value + m) * 255).rounded()) }
        return StationCore.RGBColor(red: byte(components.0), green: byte(components.1), blue: byte(components.2))
    }

    static func parseHex(_ text: String) -> StationCore.RGBColor? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let packed = Int(value, radix: 16) else { return nil }
        return StationCore.RGBColor(packed: packed)
    }

    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

struct StationColorPicker: View {
    @Binding var selection: StationCore.RGBColor
    let label: String
    @State private var presented = false

    var body: some View {
        HStack {
            Label("Color", systemImage: "paintpalette").font(.caption)
            Spacer()
            Button { presented.toggle() } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5).fill(selection.color)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.3)))
                        .frame(width: 27, height: 20)
                    Text(selection.hex).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.horizontal, 9).padding(.vertical, 6)
                    .background(StationAppearance.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StationAppearance.cardBorder))
            }.buttonStyle(.plain)
                .accessibilityLabel("\(label) color")
                .accessibilityValue(selection.hex)
                .help("Choose \(label.lowercased()) color")
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    StationColorPopover(selection: $selection, label: label)
                }
        }
    }
}

struct StationColorPopover: View {
    @Binding var selection: StationCore.RGBColor
    let label: String
    @State private var components: StationColorComponents
    @State private var hexText: String
    @State private var hexError = false
    @FocusState private var hexFocused: Bool

    private static let quickColors: [(name: String, rgb: Int)] = [
        ("Warm white", 0xFFE4BC), ("Amber", 0xFFB547), ("Coral", 0xFF735C), ("Rose", 0xF768BA),
        ("Lavender", 0xA699FF), ("Blue", 0x497BFF), ("Cyan", 0x43D9EE), ("Mint", 0x63E5B1)
    ]

    init(selection: Binding<StationCore.RGBColor>, label: String) {
        _selection = selection
        self.label = label
        _components = State(initialValue: StationColorComponents(selection.wrappedValue))
        _hexText = State(initialValue: selection.wrappedValue.hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("COLOR").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
            }
            StationSaturationField(hue: components.hue,
                                   saturation: componentBinding(\.saturation), brightness: componentBinding(\.brightness))
                .frame(height: 150)
            StationHueTrack(hue: componentBinding(\.hue)).frame(height: 20)
            VStack(spacing: 9) {
                componentSlider("Saturation", keyPath: \.saturation)
                componentSlider("Color brightness", keyPath: \.brightness)
            }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9).fill(selection.color)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.22)))
                    .frame(width: 40, height: 36).accessibilityLabel("Selected color \(selection.hex)")
                TextField("#A699FF", text: $hexText)
                    .font(.system(.body, design: .monospaced)).textFieldStyle(.plain)
                    .focused($hexFocused).onSubmit(applyHex)
                    .accessibilityLabel("Hex color").accessibilityHint("Six hexadecimal digits. Press Return to apply.")
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(StationAppearance.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hexError ? Color.orange : StationAppearance.cardBorder))
                Button("Apply", action: applyHex).controlSize(.small)
            }
            if hexError {
                Label("Use 6 hex digits, for example #A699FF.", systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Quick colors").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    ForEach(Self.quickColors, id: \.rgb) { preset in
                        let rgb = StationCore.RGBColor(packed: preset.rgb)
                        Button { select(rgb) } label: {
                            Circle().fill(rgb.color).frame(width: 21, height: 21)
                                .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                                .padding(3).overlay(Circle().strokeBorder(selection == rgb ? Color.primary.opacity(0.9) : .clear, lineWidth: 1.5))
                        }.buttonStyle(.plain).help(preset.name)
                            .accessibilityLabel("\(preset.name), \(rgb.hex)")
                            .accessibilityAddTraits(selection == rgb ? .isSelected : [])
                    }
                }
            }
        }.padding(18).frame(width: 304).background(StationAppearance.popoverBackground)
            .tint(StationAppearance.accent)
            .onChange(of: selection) { _, value in
                if components.rgb != value { components = StationColorComponents(value, preserving: components) }
                if !hexFocused { hexText = value.hex; hexError = false }
            }
            .onChange(of: hexText) { _, _ in hexError = false }
    }

    private func componentSlider(_ title: String, keyPath: WritableKeyPath<StationColorComponents, Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 87, alignment: .leading)
            Slider(value: componentBinding(keyPath), in: 0...1).controlSize(.mini).accessibilityLabel(title)
            Text("\(Int((components[keyPath: keyPath] * 100).rounded()))%")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).frame(width: 33, alignment: .trailing)
        }
    }

    private func componentBinding(_ keyPath: WritableKeyPath<StationColorComponents, Double>) -> Binding<Double> {
        Binding(get: { components[keyPath: keyPath] }, set: { value in
            components[keyPath: keyPath] = StationColorComponents.unit(value)
            commit(components.rgb)
        })
    }

    private func select(_ rgb: StationCore.RGBColor) {
        components = StationColorComponents(rgb, preserving: components)
        commit(rgb)
    }

    private func commit(_ rgb: StationCore.RGBColor) {
        selection = rgb
        // The model applies accepted intent immediately. If a conflicting
        // operation rejected this edit, keep the picker on the effective color.
        let effective = selection
        if components.rgb != effective { components = StationColorComponents(effective, preserving: components) }
        hexText = effective.hex; hexError = false
    }

    private func applyHex() {
        guard let rgb = StationColorComponents.parseHex(hexText) else { hexError = true; return }
        select(rgb)
    }
}

private struct StationSaturationField: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                Rectangle().fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(.black.opacity(0.5), lineWidth: 4)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2)).frame(width: 15, height: 15)
                    .position(x: max(8, min(geometry.size.width - 8, saturation * geometry.size.width)),
                              y: max(8, min(geometry.size.height - 8, (1 - brightness) * geometry.size.height)))
            }.clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? .white.opacity(0.85) : .white.opacity(0.12), lineWidth: focused ? 2 : 1))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    focused = true
                    saturation = StationColorComponents.unit(value.location.x / max(1, geometry.size.width))
                    brightness = StationColorComponents.unit(1 - value.location.y / max(1, geometry.size.height))
                })
        }.focusable().focused($focused)
            .onMoveCommand { direction in
                switch direction {
                case .left: saturation = max(0, saturation - 0.01)
                case .right: saturation = min(1, saturation + 0.01)
                case .up: brightness = min(1, brightness + 0.01)
                case .down: brightness = max(0, brightness - 0.01)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Saturation and color brightness")
            .accessibilityValue("\(Int(saturation * 100)) percent saturation, \(Int(brightness * 100)) percent brightness")
            .accessibilityHint("Use left and right arrows for saturation, up and down arrows for brightness. Separate sliders are also available below.")
    }
}

private struct StationHueTrack: View {
    @Binding var hue: Double
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                Circle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(Circle().strokeBorder(.white, lineWidth: focused ? 3 : 2))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1).frame(width: 18, height: 18)
                    .offset(x: hue * max(0, geometry.size.width - 18))
            }.frame(height: geometry.size.height).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    focused = true
                    hue = StationColorComponents.unit((value.location.x - 9) / max(1, geometry.size.width - 18))
                })
        }.focusable().focused($focused)
            .onMoveCommand { direction in
                switch direction {
                case .left, .down: hue = max(0, hue - 1 / 360)
                case .right, .up: hue = min(1, hue + 1 / 360)
                default: break
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Hue")
            .accessibilityValue("\(Int((hue * 360).rounded())) degrees")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: hue = min(1, hue + 1 / 360)
                case .decrement: hue = max(0, hue - 1 / 360)
                @unknown default: break
                }
            }
    }
}
