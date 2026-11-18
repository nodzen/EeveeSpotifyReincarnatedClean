import SwiftUI
import UIKit

struct EeveeMiscellaneousSettingsView: View {
    @State var blockSpotifyAnalytics = UserDefaults.blockSpotifyAnalytics
    @State var blockRatingPrompts = UserDefaults.blockRatingPrompts
    @State var localPlaylistDownload = UserDefaults.localPlaylistDownloadEnabled

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

            if UserDefaults.patchType.isPatching {
                Section(footer: Text("local_playlist_download_button_description".localized)) {
                    Toggle(
                        "local_playlist_download_button".localized,
                        isOn: $localPlaylistDownload
                    )
                }
            }

            Section(footer: Text("livecontainer_sharing_description".localized)) {
                Toggle(
                    "livecontainer_sharing".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.experimentsOptions.liveContainerSharing },
                        set: {
                            var options = UserDefaults.experimentsOptions
                            options.liveContainerSharing = $0
                            UserDefaults.experimentsOptions = options
                        }
                    )
                )
            }

            // Spotify's tab bar overlays the hosting view; this spacer gives the
            // list enough scroll range to bring the last section above it.
            Section {
                Color.clear
                    .frame(height: 80)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(GroupedListStyle())
        .onChange(of: blockSpotifyAnalytics) { enabled in
            UserDefaults.blockSpotifyAnalytics = enabled
        }
        .onChange(of: blockRatingPrompts) { enabled in
            UserDefaults.blockRatingPrompts = enabled
        }
        .onChange(of: localPlaylistDownload) { enabled in
            UserDefaults.localPlaylistDownloadEnabled = enabled
        }
    }
}
