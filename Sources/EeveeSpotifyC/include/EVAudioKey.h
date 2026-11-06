// EVAudioKey.h - capture the AES key of the playing stream and download it offline.
// The player has to decrypt the audio before the demuxer sees it, so the key
// passes through the process in plain form. Capturing it makes a track
// downloadable in one Range pass instead of a real-time recording.
#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Installs the capture hooks. Safe to call repeatedly; hooks stay installed
// once enabled, but key/URL capture is gated by the recorder master switch.
void EVAudioKeySetEnabled(BOOL enabled);

// Captured keys, newest first. Each entry:
//   key        NSData (16)   AES-128 key
//   iv         NSData (16)   CTR counter
//   date       NSDate
NSArray<NSDictionary *> *EVAudioKeyRecent(void);

// Manifest the player last handed to its demuxer: URL, fileID, encryption.
NSDictionary *EVAudioKeyCurrentManifest(void);

// Download the current stream with Range requests, decrypt it and write the
// Ogg to Documents/Streams. Runs in the background; done fires on the main thread.
void EVAudioKeyGrabCurrent(void (^done)(BOOL ok, NSString *text, NSURL *file));

// Multi-line status for the debug panel.
NSArray<NSString *> *EVAudioKeyDebugLines(void);

// Export network URLs, manifest bytes and key-store contents into one folder.
// Used to work out which endpoint carries the audio and where keys live.
void EVAudioKeyExportDiagnostics(void (^done)(NSURL *folder, NSString *summary));

#ifdef __cplusplus
}
#endif
