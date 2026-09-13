import SwiftUI

/// Animated album-art-colored backdrop for the karaoke overlay.
///
/// The upstream Metal renderer depended on an extra metallib build
/// step. Keep this path self-contained: it uses the same extracted palette and
/// remains available in ordinary Theos builds.
@available(iOS 15.0, *)
struct KaraokeBackgroundView: View {
    @State private var colors: [Color] = Self.placeholderColors

    private static let placeholderColors: [Color] = [
        Color(red: 0.07, green: 0.35, blue: 0.45),
        Color(red: 0.10, green: 0.55, blue: 0.40),
        Color(red: 0.05, green: 0.20, blue: 0.55),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            RadialGradient(
                colors: colors,
                center: animatedCenter(t: t),
                startRadius: 20,
                endRadius: 500
            )
            .ignoresSafeArea()
            .background(Color.black)
        }
        .onAppear(perform: loadAlbumArtPalette)
    }

    private func loadAlbumArtPalette() {
        guard let image = AlbumArtLocator.currentAlbumArt() else {
            writeDebugLog("[Karaoke] no album art found; using placeholder gradient")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let extracted = AlbumArtColorExtractor.dominantColors(from: image, count: 3)
            guard extracted.count >= 2 else {
                writeDebugLog("[Karaoke] album art palette unavailable; using placeholder gradient")
                return
            }
            let palette = extracted.map { Color($0) }
            DispatchQueue.main.async {
                colors = palette
            }
        }
    }

    private func animatedCenter(t: TimeInterval) -> UnitPoint {
        UnitPoint(
            x: 0.5 + 0.3 * sin(t * 0.13),
            y: 0.5 + 0.3 * cos(t * 0.09)
        )
    }
}
