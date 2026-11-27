/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDRecording: the New Recording window. A bar floats over the preview:
 * the source (Screen, Selection, Camera, Sound only), the microphone
 * with its level live, the red record button, and the time and size
 * counting up. A camera or sound recording is written here (VDRecorder)
 * to ~/Videos and opens to play when it stops.
 *
 * The screen and a selection are recorded by Screenshot (#715), which
 * owns screen capture: the record button hands over to it
 * (VDScreenRecording.h), and the movie it makes opens in Video when it
 * stops, through NSWorkspace.
 *
 * Cameras come through WCCapture, as Webcam.app gets them (V4L2). With
 * the VideoTestSources default on, a test pattern camera and a test
 * tone microphone are listed too, for machines without either.
 */

#ifndef _VD_RECORDING_H_
#define _VD_RECORDING_H_

#import <AppKit/AppKit.h>

typedef enum
{
  VDSourceScreen,
  VDSourceSelection,
  VDSourceCamera,
  VDSourceSound
} VDSource;

/* Posted with the recording when its window closes; userInfo's "path"
   is the movie it made, if it made one. */
extern NSString *const VDRecordingClosedNotification;

@interface VDRecording : NSObject
+ (VDRecording *) recordingWithSource: (VDSource)source;
- (NSWindow *) window;
- (void) show;
- (BOOL) isRecording;
- (void) toggleRecording: (id)sender;
@end

#endif
