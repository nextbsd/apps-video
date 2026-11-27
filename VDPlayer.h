/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDPlayer: a movie's window. The window is the video; the controls
 * float over it at the bottom and fade when the pointer rests:
 * volume, skip back and forward, play and pause, the speed, full
 * screen, and the scrubber with the time played and the length.
 *
 * Keys: Space plays and pauses, Left and Right skip 5 seconds, Up and
 * Down change the volume, Command-F and Escape go in and out of full
 * screen. A click on the video plays or pauses; a double click goes
 * full screen.
 */

#ifndef _VD_PLAYER_H_
#define _VD_PLAYER_H_

#import <AppKit/AppKit.h>
#import "VDMedia.h"

@class VDPlayerView, VDControlBar;

/* Posted with the player when its window closes. */
extern NSString *const VDPlayerClosedNotification;

@interface VDPlayer : NSObject
{
  NSString *path;
  VDMedia *media;
  VDMediaInfo info;
  NSWindow *window;
  NSWindow *fullScreenWindow;
  VDPlayerView *view;
  VDControlBar *bar;
  NSTimer *timer;
  VDImage image;
  NSBitmapImageRep *rep;
  NSPanel *infoPanel;

  float volume;
  BOOL muted;
  double speed;
  BOOL scrubbing;
  BOOL wasPlaying;		/* before the scrub */
  double lastMove;		/* when the pointer last moved */
  float barAlpha;
  BOOL pointerOverBar;
  BOOL pointerInside;
  NSString *shownTime;
}

/* Opens path in a window of its own. nil, with an alert shown, if it
   can't be played. */
+ (VDPlayer *) playerWithPath: (NSString *)path;

- (NSString *) path;
- (NSWindow *) window;
- (void) show;
- (void) close;

/* Actions, for the menus and the controls. */
- (void) togglePlay: (id)sender;
- (void) skipForward: (id)sender;
- (void) skipBackward: (id)sender;
- (void) skipBy: (double)seconds;
- (void) volumeUp: (id)sender;
- (void) volumeDown: (id)sender;
- (void) toggleMute: (id)sender;
- (void) setSpeedFromMenu: (id)sender;
- (void) cycleSpeed: (id)sender;
- (void) toggleFullScreen: (id)sender;
- (void) showInfo: (id)sender;
- (void) saveCopy: (id)sender;

/* For the control bar. */
- (BOOL) isPlaying;
- (double) time;
- (double) duration;
- (float) volume;
- (BOOL) isMuted;
- (double) speed;
- (BOOL) isFullScreen;
- (BOOL) hasVideo;
- (float) barAlpha;
- (void) setVolume: (float)v;
- (void) scrubBegin;
- (void) scrubTo: (double)fraction;
- (void) scrubEnd;
- (void) pointerMoved;
- (void) pointerOverBar: (BOOL)over;
- (void) pointerInside: (BOOL)inside;

/* The picture of the moment, and where it goes, for the view. */
- (NSBitmapImageRep *) currentPicture;
- (NSSize) videoSize;
@end

#endif
