import Foundation

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto?

    /// What a track LRCLIB explicitly flags as instrumental renders as. Built
    /// in one place so the LRCLIB repository and the "no lyrics found" path in
    /// CustomLyrics say exactly the same thing.
    static var instrumental: LyricsDto {
        LyricsDto(
            lines: [
                LyricsLineDto(content: "song_is_instrumental".localized),
                LyricsLineDto(content: "let_the_music_play".localized),
                LyricsLineDto(content: "")
            ],
            timeSynced: false,
            romanization: .original
        )
    }
    
    func toSpotifyLyricsData(source: String) -> LyricsData {
        var lyricsData = LyricsData.with {
            $0.timeSynchronized = timeSynced && !lines.isEmpty
                && lines.allSatisfy { ($0.offsetMs ?? -1) >= 0 }
                && Set(lines.compactMap(\.offsetMs)).count > 1
            $0.restriction = .unrestricted
            $0.providedBy = "\(source) (EeveeSpotify)"
        }
        
        let shouldRomanize = UserDefaults.lyricsOptions.romanization
        
        if lines.isEmpty {
            // Reached when every provider failed or nothing was found. That
            // says nothing about the track being instrumental, so use a
            // neutral unavailable message instead.
            //
            // 9.1.x has no ErrorViewController left to hook, so "hide on
            // error" is served here: an empty payload renders an empty card
            // instead of the message.
            if UserDefaults.lyricsOptions.hideOnError {
                return lyricsData
            }

            lyricsData.lines = [
                LyricsLine.with {
                    $0.content = "lyrics_not_found".localized
                },
                LyricsLine.with {
                    $0.content = ""
                }
            ]
        }
        else {
            let sortedLines = lyricsData.timeSynchronized
                ? lines.sorted { ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0) }
                : lines
            lyricsData.lines = sortedLines.map { line in
                LyricsLine.with {
                    $0.content = (shouldRomanize && romanization == .canBeRomanized)
                        ? line.content.applyingTransform(.toLatin, reverse: false)!
                        : line.content
                    $0.offsetMs = lyricsData.timeSynchronized
                        ? Int32(clamping: line.offsetMs ?? 0) : 0
                }
            }
        }
        
        if let translation = translation {
            lyricsData.translation = LyricsTranslation.with {
                $0.languageCode = translation.languageCode
                $0.lines = translation.lines
            }
        }
        
        return lyricsData
    }
}
