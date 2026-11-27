/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDController: Video's application delegate. The menus, File > Open
 * and Open Recent, the files File Viewer and other apps open with
 * Video (application:openFile:), and the New Recording windows.
 */

#ifndef _VD_CONTROLLER_H_
#define _VD_CONTROLLER_H_

#import <AppKit/AppKit.h>

@interface VDController : NSObject
{
  NSMutableArray *players;
  NSMutableArray *recordings;
  NSMenu *recentMenu;
  BOOL launched;
}

- (BOOL) openPath: (NSString *)path;

- (void) openDocument: (id)sender;
- (void) openRecent: (id)sender;
- (void) clearRecent: (id)sender;
- (void) newScreenRecording: (id)sender;
- (void) newCameraRecording: (id)sender;
- (void) newSoundRecording: (id)sender;
@end

#endif
