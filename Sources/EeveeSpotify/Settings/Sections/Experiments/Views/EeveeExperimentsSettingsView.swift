import SwiftUI
import UIKit
import EeveeSpotifyC

struct EeveeExperimentsSettingsView: View {
    @State var experimentsOptions = UserDefaults.experimentsOptions
    @State private var recorderEnabled: Bool = EeveeAudioRecorderEnabled()
    @State private var isRecording: Bool = EeveeAudioRecorderIsRecording()
    @State private var recorderStatus: String = EeveeRecorderStatusLine() ?? ""
    @State private var recorderAvailable: Bool = false
    @State private var saveArtwork: Bool = EeveeRecorderSaveArtwork()
    @State private var embedLyrics: Bool = EeveeRecorderEmbedLyrics()

    private func refreshRecorder() {
        isRecording = EeveeAudioRecorderIsRecording()
        recorderStatus = EeveeRecorderStatusLine() ?? ""
    }

    var body: some View {
        List {
            Section(
                header: Text("audio_recording".localized),
                footer: Text(!recorderEnabled
                    ? "recorder_disabled_description".localized
                    : recorderAvailable
                        ? "recording_storage_description".localized
                        : "recorder_unavailable_description".localized)
            ) {
                Toggle(
                    "enable_recording".localized,
                    isOn: Binding<Bool>(
                        get: { recorderEnabled },
                        set: { enabled in
                            recorderEnabled = enabled
                            EeveeAudioRecorderSetEnabled(enabled)
                            recorderAvailable = enabled && EeveeAudioRecorderSupported()
                            if enabled { startRecorderTrackTimer() }
                            else { stopRecorderTrackTimer() }
                            refreshRecorder()
                        }
                    )
                )

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
                .disabled(!recorderEnabled || !recorderAvailable)

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
                .disabled(!recorderEnabled || !recorderAvailable)

                Toggle(
                    "embed_genius_lyrics".localized,
                    isOn: Binding<Bool>(
                        get: { embedLyrics },
                        set: {
                            embedLyrics = $0
                            EeveeRecorderSetEmbedLyrics($0)
                        }
                    )
                )
                .disabled(!recorderEnabled || !recorderAvailable)

                if recorderEnabled && !recorderStatus.isEmpty {
                    Text(recorderStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            if !EeveeSpotify.isSpotify91OrNewer {
                Section(
                    footer: Text("show_instagram_destination_description"
                        .localizeWithFormat("restart_is_required_description".localized))
                ) {
                    Toggle(
                        "show_instagram_destination".localized,
                        isOn: $experimentsOptions.showInstagramDestination
                    )
                }
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
            recorderEnabled = EeveeAudioRecorderEnabled()
            recorderAvailable = recorderEnabled && EeveeAudioRecorderSupported()
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
        .onChange(of: experimentsOptions) { options in
            UserDefaults.experimentsOptions = options

            if options.showInstagramDestination {
                OfflineHelper.resetData()
            }
        }
        .animation(.default, value: experimentsOptions)
    }
}
