import SwiftUI
import UIKit

struct EeveeMiscellaneousSettingsView: View {
    @State var blockSpotifyAnalytics = UserDefaults.blockSpotifyAnalytics
    @State var blockRatingPrompts = UserDefaults.blockRatingPrompts

    var body: some View {
        List {
            Section(footer: Text("clean_share_links_description".localized)) {
                Toggle(
                    "clean_share_links".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.cleanShareLinks },
                        set: { UserDefaults.cleanShareLinks = $0 }
                    )
                )
            }

            Section(footer: Text("block_spotify_analytics_description".localized)) {
                Toggle(
                    "block_spotify_analytics".localized,
                    isOn: $blockSpotifyAnalytics
                )
            }

            Section(footer: Text("block_rating_prompts_description".localized)) {
                Toggle(
                    "block_rating_prompts".localized,
                    isOn: $blockRatingPrompts
                )
            }
        }
        .listStyle(GroupedListStyle())
        .onChange(of: blockSpotifyAnalytics) { enabled in
            UserDefaults.blockSpotifyAnalytics = enabled
        }
        .onChange(of: blockRatingPrompts) { enabled in
            UserDefaults.blockRatingPrompts = enabled
        }
    }
}
