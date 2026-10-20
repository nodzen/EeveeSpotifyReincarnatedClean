// EVRecorder.h - public API of the Eevee audio recorder.
// Import this from include/Tweak.h so Swift can call it.
#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Posted on the main thread when recording starts, stops or fails.
extern NSString *const EeveeRecorderStateDidChangeNotification;
// Posted on the main thread when the per-track files are written.
// userInfo: files (NSArray<NSURL*>), folder (NSURL), tracks (NSArray<NSDictionary*>),
//           error (NSString, optional), download (NSNumber, optional)
extern NSString *const EeveeRecorderDidFinishNotification;

// Existing API (unchanged signatures)
BOOL EeveeAudioRecorderStart(void);
void EeveeAudioRecorderStop(void);
// Restarts the current track, captures exactly one track and exports it as AAC.
// Starts asynchronously; the finish notification reports the saved file.
BOOL EeveeAudioRecorderDownloadCurrentTrack(void);
BOOL EeveeAudioRecorderIsRecording(void);
NSString *EeveeAudioRecorderCurrentPath(void);

// NO when the process has no inline-hooking shim (plain sideload without JIT).
BOOL EeveeAudioRecorderSupported(void);
// On-screen record button preference. Takes effect on the next launch.
BOOL EeveeRecorderShowButton(void);
void EeveeRecorderSetShowButton(BOOL show);

// New API
NSString *EeveeAudioRecorderLastError(void);          // why the last Start failed, nil if none
NSString *EeveeRecorderStatusLine(void);              // short text for a settings row
void EeveeRecorderSetExtraMetadata(NSDictionary *md); // title, artist, album, albumArtist, genre, trackNumber, discNumber, year, uri, isrc
BOOL EeveeRecorderSaveArtwork(void);                  // keep a separate JPG next to the M4A
void EeveeRecorderSetSaveArtwork(BOOL save);
BOOL EeveeRecorderEmbedLyrics(void);                  // write cached Genius lyrics into the M4A
void EeveeRecorderSetEmbedLyrics(BOOL embed);
void EeveeRecorderSetLyrics(NSString *lyrics, NSString *uri, NSString *title, NSString *artist);
NSString *EeveeRecorderDebugReport(void);             // main thread only
void EeveeRecorderPresentDebugPanel(void);            // main thread only

#ifdef __cplusplus
}
#endif
