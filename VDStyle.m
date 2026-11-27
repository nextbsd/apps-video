/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "VDStyle.h"
#import <GNUstepGUI/GSTheme.h>

NSString *const VDStyleChangedNotification = @"VDStyleChanged";

static BOOL light = NO;
static BOOL haveRead = NO;

#define PICK(d, l) ([VDStyle light] ? (l) : (d))

@implementation VDStyle

+ (void) reload
{
  NSArray *allowed = [NSArray arrayWithObjects: @"dark", @"light", nil];
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  id v;

  [defs synchronize];
  v = [[defs persistentDomainForName: NSGlobalDomain]
        objectForKey: @"NBAppearance"];
  if (![allowed containsObject: v])
    v = [defs objectForKey: @"NBAppearance"];
  if (![allowed containsObject: v])
    v = [[[GSTheme theme] infoDictionary] objectForKey: @"NBAppearance"];
  light = [v isEqual: @"light"];
  haveRead = YES;
}

+ (BOOL) light
{
  if (!haveRead)
    [self reload];
  return light;
}

+ (NSColor *) rgb: (unsigned)v alpha: (CGFloat)a
{
  return [NSColor colorWithCalibratedRed: ((v >> 16) & 255) / 255.0
                                   green: ((v >> 8) & 255) / 255.0
                                    blue: (v & 255) / 255.0
                                   alpha: a];
}

+ (NSColor *) accent { return PICK([self rgb: 0x00d4ff alpha: 1], [self rgb: 0x00a3c7 alpha: 1]); }
+ (NSColor *) page { return PICK([self rgb: 0x1c1e23 alpha: 1], [self rgb: 0xf7f7f9 alpha: 1]); }
+ (NSColor *) text { return PICK([self rgb: 0xe9ebef alpha: 1], [self rgb: 0x1d1f24 alpha: 1]); }
+ (NSColor *) dim { return PICK([self rgb: 0x9aa0ac alpha: 1], [self rgb: 0x5f6470 alpha: 1]); }
+ (NSColor *) line { return PICK([self rgb: 0xffffff alpha: .09], [self rgb: 0x000000 alpha: .10]); }

+ (NSColor *) hud { return [self rgb: 0x1c1f25 alpha: .82]; }
+ (NSColor *) hudLine { return [self rgb: 0xffffff alpha: .10]; }
+ (NSColor *) hudText { return [self rgb: 0xffffff alpha: 1]; }
+ (NSColor *) hudDim { return [self rgb: 0xd9dce2 alpha: 1]; }

+ (NSFont *) fontOfSize: (CGFloat)size bold: (BOOL)bold
{
  NSFont *f = bold ? [NSFont boldSystemFontOfSize: size]
    : [NSFont systemFontOfSize: size];

  return f != nil ? f : [NSFont userFontOfSize: size];
}

/* An arc of the 24 grid, as SVG's "a" draws it, from the path's current
   point to (x, y): radius r, the short way or the long way, clockwise on
   screen (sweep) or not. */
static void
VDArc (NSBezierPath *p, CGFloat r, BOOL large, BOOL sweep, CGFloat x,
       CGFloat y)
{
  NSPoint from = [p currentPoint];
  CGFloat dx = (x - from.x) / 2, dy = (y - from.y) / 2;
  CGFloat d2 = dx * dx + dy * dy, h, cx, cy, a0, a1;

  if (d2 > r * r)
    r = sqrt (d2);
  h = sqrt (MAX (r * r - d2, 0)) / sqrt (d2);
  /* The centre is to one side of the chord's middle. */
  if (large == sweep)
    h = -h;
  cx = from.x + dx - h * dy;
  cy = from.y + dy + h * dx;
  a0 = atan2 (from.y - cy, from.x - cx) * 180 / M_PI;
  a1 = atan2 (y - cy, x - cx) * 180 / M_PI;
  /* In a flipped view, clockwise on screen is the angle going up. */
  [p appendBezierPathWithArcWithCenter: NSMakePoint (cx, cy) radius: r
                            startAngle: a0 endAngle: a1 clockwise: !sweep];
}

static NSBezierPath *
VDLines (const CGFloat *xy, int n, BOOL closed)
{
  NSBezierPath *p = [NSBezierPath bezierPath];
  int i;

  [p moveToPoint: NSMakePoint (xy[0], xy[1])];
  for (i = 1; i < n; i++)
    [p lineToPoint: NSMakePoint (xy[2 * i], xy[2 * i + 1])];
  if (closed)
    [p closePath];
  return p;
}

+ (void) drawGlyph: (VDGlyph)glyph inRect: (NSRect)rect
             color: (NSColor *)color
{
  CGFloat s = rect.size.width / 24.0;
  NSAffineTransform *t = [NSAffineTransform transform];
  NSBezierPath *stroke = [NSBezierPath bezierPath];
  NSBezierPath *fill = [NSBezierPath bezierPath];
  CGFloat width = 2.0;
  BOOL mirror = NO;

  switch (glyph)
    {
    case VDGlyphPlay:
      {
        CGFloat a[] = { 8, 5, 8, 19, 19, 12 };
        [fill appendBezierPath: VDLines (a, 3, YES)];
        break;
      }
    case VDGlyphPause:
      [fill appendBezierPathWithRect: NSMakeRect (6.5, 5, 3.5, 14)];
      [fill appendBezierPathWithRect: NSMakeRect (14, 5, 3.5, 14)];
      break;
    case VDGlyphForward:
      mirror = YES;
      /* fall through */
    case VDGlyphBack:
      {
        CGFloat head[] = { 4, 4, 4, 8, 8, 8 };
        [stroke moveToPoint: NSMakePoint (4, 12)];
        VDArc (stroke, 8, YES, NO, 6.3, 6.4);
        [stroke appendBezierPath: VDLines (head, 3, NO)];
        break;
      }
    case VDGlyphMuted:
    case VDGlyphVolume:
      {
        CGFloat speaker[] = { 4, 9.5, 8, 9.5, 13, 5.5, 13, 18.5, 8, 14.5,
                              4, 14.5 };
        [stroke appendBezierPath: VDLines (speaker, 6, YES)];
        if (glyph == VDGlyphVolume)
          {
            [stroke moveToPoint: NSMakePoint (16.5, 9)];
            VDArc (stroke, 4, NO, YES, 16.5, 15);
          }
        else
          {
            [stroke moveToPoint: NSMakePoint (16.5, 9.5)];
            [stroke lineToPoint: NSMakePoint (21.5, 14.5)];
            [stroke moveToPoint: NSMakePoint (21.5, 9.5)];
            [stroke lineToPoint: NSMakePoint (16.5, 14.5)];
          }
        break;
      }
    case VDGlyphFullScreen:
      {
        CGFloat a[] = { 4, 9, 4, 4, 9, 4 }, b[] = { 15, 4, 20, 4, 20, 9 };
        CGFloat c[] = { 20, 15, 20, 20, 15, 20 }, d[] = { 9, 20, 4, 20, 4, 15 };
        [stroke appendBezierPath: VDLines (a, 3, NO)];
        [stroke appendBezierPath: VDLines (b, 3, NO)];
        [stroke appendBezierPath: VDLines (c, 3, NO)];
        [stroke appendBezierPath: VDLines (d, 3, NO)];
        break;
      }
    case VDGlyphExitFullScreen:
      {
        CGFloat a[] = { 4, 9, 9, 9, 9, 4 }, b[] = { 15, 4, 15, 9, 20, 9 };
        CGFloat c[] = { 20, 15, 15, 15, 15, 20 }, d[] = { 9, 20, 9, 15, 4, 15 };
        [stroke appendBezierPath: VDLines (a, 3, NO)];
        [stroke appendBezierPath: VDLines (b, 3, NO)];
        [stroke appendBezierPath: VDLines (c, 3, NO)];
        [stroke appendBezierPath: VDLines (d, 3, NO)];
        break;
      }
    case VDGlyphScreen:
      {
        CGFloat a[] = { 3, 5, 21, 5, 21, 17, 3, 17 };
        width = 1.8;
        [stroke appendBezierPath: VDLines (a, 4, YES)];
        [stroke moveToPoint: NSMakePoint (8, 21)];
        [stroke lineToPoint: NSMakePoint (16, 21)];
        [stroke moveToPoint: NSMakePoint (12, 17)];
        [stroke lineToPoint: NSMakePoint (12, 21)];
        break;
      }
    case VDGlyphSelection:
      {
        CGFloat a[] = { 4, 8, 4, 4, 8, 4 }, b[] = { 16, 4, 20, 4, 20, 8 };
        CGFloat c[] = { 20, 16, 20, 20, 16, 20 }, d[] = { 8, 20, 4, 20, 4, 16 };
        width = 1.8;
        [stroke appendBezierPath: VDLines (a, 3, NO)];
        [stroke appendBezierPath: VDLines (b, 3, NO)];
        [stroke appendBezierPath: VDLines (c, 3, NO)];
        [stroke appendBezierPath: VDLines (d, 3, NO)];
        break;
      }
    case VDGlyphCamera:
      {
        CGFloat a[] = { 4, 7, 15, 7, 15, 17, 4, 17 };
        CGFloat b[] = { 15, 10, 20, 7, 20, 17, 15, 14 };
        width = 1.8;
        [stroke appendBezierPath: VDLines (a, 4, YES)];
        [stroke appendBezierPath: VDLines (b, 4, NO)];
        break;
      }
    case VDGlyphMicrophone:
      width = 1.8;
      [stroke appendBezierPathWithRoundedRect: NSMakeRect (9, 3, 6, 12)
                                      xRadius: 3 yRadius: 3];
      [stroke moveToPoint: NSMakePoint (5.5, 11)];
      VDArc (stroke, 6.5, NO, NO, 18.5, 11);
      [stroke moveToPoint: NSMakePoint (12, 17.5)];
      [stroke lineToPoint: NSMakePoint (12, 21)];
      break;
    case VDGlyphChevronDown:
      {
        CGFloat a[] = { 6, 9, 12, 15, 18, 9 };
        [stroke appendBezierPath: VDLines (a, 3, NO)];
        break;
      }
    case VDGlyphMusic:
      {
        CGFloat a[] = { 9, 17, 9, 5, 20, 3, 20, 15 };
        width = 1.6;
        [stroke appendBezierPath: VDLines (a, 4, NO)];
        [fill appendBezierPathWithOvalInRect: NSMakeRect (4.5, 14.5, 5, 5)];
        [fill appendBezierPathWithOvalInRect: NSMakeRect (15.5, 12.5, 5, 5)];
        break;
      }
    }

  [t translateXBy: rect.origin.x yBy: rect.origin.y];
  if (mirror)
    {
      [t translateXBy: rect.size.width yBy: 0];
      [t scaleXBy: -s yBy: s];
    }
  else
    [t scaleBy: s];
  [stroke transformUsingAffineTransform: t];
  [fill transformUsingAffineTransform: t];
  [color set];
  [fill fill];
  [stroke setLineWidth: width * s];
  [stroke setLineCapStyle: NSRoundLineCapStyle];
  [stroke setLineJoinStyle: NSRoundLineJoinStyle];
  [stroke stroke];
}

+ (NSString *) timeString: (double)seconds
{
  long t = seconds > 0 ? (long) floor (seconds) : 0;

  if (t >= 3600)
    return [NSString stringWithFormat: @"%ld:%02ld:%02ld", t / 3600,
                     (t / 60) % 60, t % 60];
  return [NSString stringWithFormat: @"%ld:%02ld", t / 60, t % 60];
}

+ (NSString *) sizeString: (long long)bytes
{
  if (bytes <= 0)
    return @"Zero KB";
  if (bytes < 1000 * 1000)
    return [NSString stringWithFormat: @"%lld KB", (bytes + 999) / 1000];
  if (bytes < 1000LL * 1000 * 1000)
    return [NSString stringWithFormat: @"%.1f MB", bytes / 1e6];
  return [NSString stringWithFormat: @"%.2f GB", bytes / 1e9];
}

@end
