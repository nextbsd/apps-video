/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "VDScreenRecording.h"
#import <AppKit/AppKit.h>

#define VDScreenshotDefault @"/System/Applications/Screenshot.app"

NSString *
VDScreenshotAppPath (void)
{
  NSString *app = [[NSWorkspace sharedWorkspace]
                    fullPathForApplication: @"Screenshot"];
  BOOL isDir = NO;

  if (app == nil
      && [[NSFileManager defaultManager] fileExistsAtPath: VDScreenshotDefault
                                              isDirectory: &isDir] && isDir)
    app = VDScreenshotDefault;
  return app;
}

BOOL
VDStartScreenRecording (BOOL selection, NSString **why)
{
  NSString *app = VDScreenshotAppPath ();
  NSString *executable;
  NSTask *task;

  if (app == nil)
    {
      *why = @"Screen recordings are made by Screenshot, which isn't"
        @" installed.";
      return NO;
    }
  executable = [[NSBundle bundleWithPath: app] executablePath];
  if (executable == nil)
    {
      *why = [NSString stringWithFormat: @"%@ has no program in it.", app];
      return NO;
    }
  task = AUTORELEASE ([[NSTask alloc] init]);
  [task setLaunchPath: executable];
  [task setArguments: [NSArray arrayWithObjects: @"-Record",
                               selection ? @"selection" : @"screen", nil]];
  [task setCurrentDirectoryPath: NSHomeDirectory ()];
  NS_DURING
    [task launch];
  NS_HANDLER
    *why = [NSString stringWithFormat: @"Screenshot couldn't be started: %@",
                     [localException reason]];
    return NO;
  NS_ENDHANDLER
  return YES;
}
