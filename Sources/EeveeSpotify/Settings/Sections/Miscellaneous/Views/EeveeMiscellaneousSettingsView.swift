import SwiftUI
import UIKit
import EeveeSpotifyC

struct EeveeMiscellaneousSettingsView: View {
    @State var blockSpotifyAnalytics = UserDefaults.blockSpotifyAnalytics
    @State var blockRatingPrompts = UserDefaults.blockRatingPrompts
    @State private var isRecording: Bool = EeveeAudioRecorderIsRecording()
    @State private var recorderStatus: String = EeveeRecorderStatusLine() ?? ""
    @State private var recorderAvailable: Bool = EeveeAudioRecorderSupported()
    @State private var showRecordButton: Bool = EeveeRecorderShowButton()
    @State private var saveArtwork: Bool = EeveeRecorderSaveArtwork()

    private func refreshRecorder() {
        isRecording = EeveeAudioRecorderIsRecording()
        recorderStatus = EeveeRecorderStatusLine() ?? ""
    }

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

            Section(
                header: Text("audio_recording".localized),
                footer: Text(recorderAvailable
                    ? "recording_storage_description".localized
                    : "recorder_unavailable_description".localized)
            ) {
                Toggle(
                    "record_button".localized,
                    isOn: Binding<Bool>(
                        get: { showRecordButton },
                        set: {
                            showRecordButton = $0
                            EeveeRecorderSetShowButton($0)
                        }
                    )
                )
                .disabled(!recorderAvailable)

                Button {
                    if isRecording {
                        EeveeAudioRecorderStop()
                    } else {
                        _ = EeveeAudioRecorderStart()
                    }
                    // State notification is posted on the main thread, but the
                    // split/finalize step can take a moment; refresh now for the
                    // common case and again when the notification arrives.
                    refreshRecorder()
                } label: {
                    HStack {
                        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                            .foregroundColor(isRecording ? .red : .accentColor)
                        Text(isRecording ? "stop_recording".localized : "start_recording".localized)
                    }
                }
                .disabled(!recorderAvailable)

                Toggle(
                    "save_artwork".localized,
                    isOn: Binding<Bool>(
                        get: { saveArtwork },
                        set: {
                            saveArtwork = $0
                            EeveeRecorderSetSaveArtwork($0)
                        }
                    )
                )
                .disabled(!recorderAvailable)

                Text(recorderStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
        .onAppear {
            refreshRecorder()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .EeveeRecorderStateDidChange)) { _ in
            refreshRecorder()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .EeveeRecorderDidFinish)) { _ in
            refreshRecorder()
        }
        .onChange(of: blockSpotifyAnalytics) { enabled in
            UserDefaults.blockSpotifyAnalytics = enabled
        }
        .onChange(of: blockRatingPrompts) { enabled in
            UserDefaults.blockRatingPrompts = enabled
        }
    }
}
