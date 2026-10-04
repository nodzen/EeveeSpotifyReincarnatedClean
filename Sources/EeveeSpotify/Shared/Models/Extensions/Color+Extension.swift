import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    var components: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        UIColor(self).eeveeRGBAComponents ?? (0, 0, 0, 1)
    }

    func lighter(by amount: CGFloat = 0.2) -> Self { Self(UIColor(self).lighter(by: amount)) }
    func darker(by amount: CGFloat = 0.2) -> Self { Self(UIColor(self).darker(by: amount)) }

    var brightness: CGFloat {
        (
            components.red * 299
            + components.green * 587
            + components.blue * 114
        ) / 1000
    }

    func normalized(_ by: CGFloat) -> Color {
        let target = min(max(by, 0), 1)
        let current = brightness
        guard abs(current - target) > 0.001 else { return self }

        // Mixing with white/black by the raw brightness difference does not
        // reach the requested target and makes the slider appear ineffective.
        // Because brightness is a linear weighted sum, this amount reaches
        // the target while preserving the hue as much as RGB mixing allows.
        if current < target {
            let amount = (target - current) / max(1 - current, 0.001)
            return self.lighter(by: amount)
        }

        let amount = (current - target) / max(current, 0.001)
        return self.darker(by: amount)
    }
    
    var hexString: String {
         String(
            format: "%02X%02X%02X",
            Int(components.red * 255),
            Int(components.green * 255),
            Int(components.blue * 255)
         )
    }
    
    var uInt32: UInt32 {
        UInt32(components.alpha * 255) << 24
            | UInt32(components.red * 255) << 16
            | UInt32(components.green * 255) << 8
            | UInt32(components.blue * 255)
    }
}
