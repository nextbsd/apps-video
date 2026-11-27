/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDStyle: Video's colours, fonts and glyphs. The window chrome is the
 * theme's; the video, its control bar and the recording bar are dark in
 * both appearances, as QuickTime's are, and the accent and the Info
 * panel follow NBAppearance (the person's choice in NSGlobalDomain, else
 * the theme's default, else dark), as every NextBSD app reads it.
 */

#ifndef _VD_STYLE_H_
#define _VD_STYLE_H_

#import <AppKit/AppKit.h>

/* Posted in this process when the appearance changes. */
extern NSString *const VDStyleChangedNotification;

/* The glyphs, drawn on a 24 x 24 grid in a flipped view. */
typedef enum
{
  VDGlyphPlay,
  VDGlyphPause,
  VDGlyphBack,
  VDGlyphForward,
  VDGlyphVolume,
  VDGlyphMuted,
  VDGlyphFullScreen,
  VDGlyphExitFullScreen,
  VDGlyphScreen,
  VDGlyphSelection,
  VDGlyphCamera,
  VDGlyphMicrophone,
  VDGlyphChevronDown,
  VDGlyphMusic
} VDGlyph;

@interface VDStyle : NSObject
+ (BOOL) light;
+ (void) reload;

+ (NSColor *) accent;
+ (NSColor *) page;		/* the Info panel */
+ (NSColor *) text;
+ (NSColor *) dim;
+ (NSColor *) line;

/* The bars over the video. */
+ (NSColor *) hud;
+ (NSColor *) hudLine;
+ (NSColor *) hudText;
+ (NSColor *) hudDim;

+ (NSFont *) fontOfSize: (CGFloat)size bold: (BOOL)bold;

/* RGB as 0xrrggbb. */
+ (NSColor *) rgb: (unsigned)value alpha: (CGFloat)alpha;

/* Draws glyph in rect (any size; the 24 grid is scaled), in a flipped
   view. */
+ (void) drawGlyph: (VDGlyph)glyph inRect: (NSRect)rect
             color: (NSColor *)color;

/* "1:02:03", "2:13", "0:00". */
+ (NSString *) timeString: (double)seconds;

/* "Zero KB", "640 KB", "12.3 MB". */
+ (NSString *) sizeString: (long long)bytes;
@end

#endif
