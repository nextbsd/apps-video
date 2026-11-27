/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Video.app: plays video and sound, and records the camera and sound,
 * as QuickTime Player on a Mac.
 */

#import <AppKit/AppKit.h>
#import "VDController.h"

int
main (int argc, const char **argv)
{
  CREATE_AUTORELEASE_POOL (pool);
  VDController *controller;

  [NSApplication sharedApplication];
  controller = [[VDController alloc] init];
  [NSApp setDelegate: controller];
  [NSApp run];
  RELEASE (controller);
  RELEASE (pool);
  return 0;
}
