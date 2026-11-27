/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDScreenRecording: hands a screen recording over to Screenshot.
 *
 * Screen capture belongs to Screenshot.app (nextbsd/nextbsd#715, in
 * apps-settings), which WindowServer trusts to record without asking;
 * it writes the .mov and opens it with NSWorkspace, so it plays here.
 *
 * The interface is Screenshot's own (its SSRequest.h, "Asking
 * Screenshot" in its README): Screenshot's executable is started with
 *
 *     -Record screen        the toolbar, ready to record the screen
 *     -Record selection     the toolbar, ready to record a selection
 *
 * and a copy already running takes the request (apps-settings#24).
 * It's started from inside the session (NSTask), so it gets the
 * session's display. Nothing else in Video knows how it's asked.
 */

#ifndef _VD_SCREEN_RECORDING_H_
#define _VD_SCREEN_RECORDING_H_

#import <Foundation/Foundation.h>

/* Where Screenshot is, or nil when it isn't installed. */
NSString *VDScreenshotAppPath (void);

/* Starts Screenshot recording the screen (or a selection). NO, with why
   in *why, if it couldn't be started. */
BOOL VDStartScreenRecording (BOOL selection, NSString **why);

#endif
