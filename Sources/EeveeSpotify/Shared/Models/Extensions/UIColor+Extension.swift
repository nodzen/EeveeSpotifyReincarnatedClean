import SwiftUI
import UIKit

extension UIColor {
    /// Returns a stable sRGB representation even for grayscale colors. Spotify
    /// frequently supplies artwork/background colors as grayscale or extended
    /// colors, for which UIColor.getRed(_:green:blue:alpha:) returns false.
    var eeveeRGBAComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return (
                red: red.clamped(to: 0...1),
                green: green.clamped(to: 0...1),
                blue: blue.clamped(to: 0...1),
                alpha: alpha.clamped(to: 0...1)
            )
        }

        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            let value = white.clamped(to: 0...1)
            return (
                red: value,
                green: value,
                blue: value,
                alpha: alpha.clamped(to: 0...1)
            )
        }

        guard let components = cgColor.components else { return nil }
        if components.count >= 4 {
            return (
                red: components[0].clamped(to: 0...1),
                green: components[1].clamped(to: 0...1),
                blue: components[2].clamped(to: 0...1),
                alpha: components[3].clamped(to: 0...1)
            )
        }
        if components.count == 2 {
            let value = components[0].clamped(to: 0...1)
            return (
                red: value,
                green: value,
                blue: value,
                alpha: components[1].clamped(to: 0...1)
            )
        }
        return nil
    }

    func mix(with target: UIColor, amount: CGFloat) -> Self {
        let source = eeveeRGBAComponents ?? (0, 0, 0, 1)
        let destination = target.eeveeRGBAComponents ?? (0, 0, 0, 1)
        let clampedAmount = amount.clamped(to: 0...1)

        return Self(
            red: source.red * (1.0 - clampedAmount) + destination.red * clampedAmount,
            green: source.green * (1.0 - clampedAmount) + destination.green * clampedAmount,
            blue: source.blue * (1.0 - clampedAmount) + destination.blue * clampedAmount,
            alpha: source.alpha * (1.0 - clampedAmount) + destination.alpha * clampedAmount
        )
    }

    func lighter(by amount: CGFloat = 0.2) -> Self { mix(with: .white, amount: amount) }
    func darker(by amount: CGFloat = 0.2) -> Self { mix(with: .black, amount: amount) }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
