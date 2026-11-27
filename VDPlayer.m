/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "VDPlayer.h"
#import "VDStyle.h"
#import <GNUstepBase/GNUstep.h>

#include <math.h>
#include <string.h>
#include <time.h>

/* Layout, in points, as drawn. */
#define VDBarWidth 640.0
#define VDBarHeight 75.0
#define VDBarBottom 22.0
#define VDBarSide 16.0
#define VDButton 34.0
#define VDRowTop 10.0
#define VDVolumeWidth 80.0
#define VDSpeedWidth 38.0
#define VDTimeWidth 44.0
#define VDMinWidth 480.0
#define VDAudioHeight 220.0

/* Timing, in seconds. */
#define VDTick (1.0 / 60.0)
#define VDRestSeconds 2.5		/* the controls fade after this */
#define VDFadeStep (1.0 / 12.0)		/* alpha a tick */
#define VDKeySkip 5.0
#define VDButtonSkip 10.0
#define VDVolumeStep 0.1f

#define VDVolumeKey @"VideoVolume"

NSString *const VDPlayerClosedNotification = @"VDPlayerClosed";

static const double VDSpeeds[] = { 0.5, 1.0, 1.25, 1.5, 2.0 };
#define VDSpeedCount ((int) (sizeof (VDSpeeds) / sizeof (VDSpeeds[0])))

static double
VDMonotonic (void)
{
  struct timespec ts;

  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + ts.tv_nsec / 1e9;
}

static NSString *
VDSpeedString (double speed)
{
  if (speed == floor (speed))
    return [NSString stringWithFormat: @"%d×", (int) speed];
  if (speed * 10 == floor (speed * 10))
    return [NSString stringWithFormat: @"%.1f×", speed];
  return [NSString stringWithFormat: @"%.2f×", speed];
}

/* The largest rect of size's shape that fits in bounds, centred. */
static NSRect
VDFit (NSRect bounds, NSSize size)
{
  CGFloat scale;
  NSRect r;

  if (size.width <= 0 || size.height <= 0)
    return bounds;
  scale = MIN (bounds.size.width / size.width,
               bounds.size.height / size.height);
  r.size.width = floor (size.width * scale);
  r.size.height = floor (size.height * scale);
  r.origin.x = floor (NSMidX (bounds) - r.size.width / 2);
  r.origin.y = floor (NSMidY (bounds) - r.size.height / 2);
  return r;
}

static NSColor *
VDFaded (NSColor *color, float alpha)
{
  return [color colorWithAlphaComponent: [color alphaComponent] * alpha];
}

static void
VDDrawText (NSString *text, NSRect rect, NSFont *font, NSColor *color,
            NSTextAlignment alignment)
{
  NSMutableParagraphStyle *p = AUTORELEASE ([[NSMutableParagraphStyle
                                                defaultParagraphStyle]
                                               mutableCopy]);
  NSDictionary *attributes;

  [p setAlignment: alignment];
  attributes = [NSDictionary dictionaryWithObjectsAndKeys:
                               font, NSFontAttributeName,
                             color, NSForegroundColorAttributeName,
                             p, NSParagraphStyleAttributeName, nil];
  [text drawInRect: rect withAttributes: attributes];
}

/* ---- the control bar ---- */

typedef enum
{
  VDPartNone,
  VDPartMute,
  VDPartVolume,
  VDPartBack,
  VDPartPlay,
  VDPartForward,
  VDPartSpeed,
  VDPartFullScreen,
  VDPartScrubber
} VDPart;

@interface VDControlBar : NSView
{
  VDPlayer *player;		/* not retained: it owns this */
  VDPart dragging;
}
- (id) initWithFrame: (NSRect)frame player: (VDPlayer *)p;
@end

@implementation VDControlBar

- (id) initWithFrame: (NSRect)frame player: (VDPlayer *)p
{
  if ((self = [super initWithFrame: frame]) != nil)
    player = p;
  return self;
}

- (BOOL) isFlipped
{
  return YES;
}

- (BOOL) acceptsFirstMouse: (NSEvent *)event
{
  return YES;
}

- (CGFloat) timeWidth
{
  return [player duration] >= 3600 ? 56.0 : VDTimeWidth;
}

- (NSRect) rectOfPart: (VDPart)part
{
  NSRect b = [self bounds];
  CGFloat mid = NSMidX (b), right = NSMaxX (b) - VDBarSide;
  CGFloat row2 = VDRowTop + VDButton + 6, tw = [self timeWidth];

  switch (part)
    {
    case VDPartMute:
      return NSMakeRect (VDBarSide - 6, VDRowTop, VDButton, VDButton);
    case VDPartVolume:
      return NSMakeRect (VDBarSide - 6 + VDButton, VDRowTop, VDVolumeWidth,
                         VDButton);
    case VDPartBack:
      return NSMakeRect (mid - VDButton * 1.5 - 6, VDRowTop, VDButton,
                         VDButton);
    case VDPartPlay:
      return NSMakeRect (mid - VDButton / 2, VDRowTop, VDButton, VDButton);
    case VDPartForward:
      return NSMakeRect (mid + VDButton / 2 + 6, VDRowTop, VDButton,
                         VDButton);
    case VDPartFullScreen:
      return NSMakeRect (right - VDButton + 6, VDRowTop, VDButton, VDButton);
    case VDPartSpeed:
      return NSMakeRect (right - VDButton + 6 - 4 - VDSpeedWidth,
                         VDRowTop + 7, VDSpeedWidth, 20);
    case VDPartScrubber:
      return NSMakeRect (VDBarSide + tw + 6, row2 - 4,
                         b.size.width - 2 * (VDBarSide + tw + 6), 21);
    default:
      return NSZeroRect;
    }
}

- (VDPart) partAt: (NSPoint)p
{
  VDPart parts[] = { VDPartMute, VDPartVolume, VDPartBack, VDPartPlay,
                     VDPartForward, VDPartSpeed, VDPartFullScreen,
                     VDPartScrubber };
  unsigned i;

  for (i = 0; i < sizeof (parts) / sizeof (parts[0]); i++)
    if (NSPointInRect (p, NSInsetRect ([self rectOfPart: parts[i]], -2, -2)))
      return parts[i];
  return VDPartNone;
}

- (void) drawRect: (NSRect)rect
{
  float a = [player barAlpha];
  NSRect b = [self bounds], r, track;
  NSBezierPath *path;
  NSColor *white = VDFaded ([VDStyle hudText], a);
  NSColor *dimText = VDFaded ([VDStyle hudDim], a);
  NSFont *font = [VDStyle fontOfSize: 11.5 bold: NO];
  double duration = [player duration], t = [player time];
  CGFloat fraction, tw = [self timeWidth], row2;
  float volume = [player isMuted] ? 0 : [player volume];

  if (a <= 0)
    return;

  /* The bar. */
  path = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect (b, 0.5, 0.5)
                                         xRadius: 14 yRadius: 14];
  [VDFaded ([VDStyle hud], a) set];
  [path fill];
  [VDFaded ([VDStyle hudLine], a) set];
  [path setLineWidth: 1];
  [path stroke];

  /* Volume. */
  r = [self rectOfPart: VDPartMute];
  [VDStyle drawGlyph: volume > 0 ? VDGlyphVolume : VDGlyphMuted
              inRect: NSInsetRect (r, 8, 8) color: white];
  r = [self rectOfPart: VDPartVolume];
  track = NSMakeRect (NSMinX (r), NSMidY (r) - 2, NSWidth (r), 4);
  [VDFaded ([VDStyle rgb: 0xffffff alpha: .25], a) set];
  [[NSBezierPath bezierPathWithRoundedRect: track xRadius: 2 yRadius: 2]
    fill];
  track.size.width = floor (NSWidth (r) * volume);
  if (track.size.width > 0)
    {
      [white set];
      [[NSBezierPath bezierPathWithRoundedRect: track xRadius: 2 yRadius: 2]
        fill];
    }

  /* Skip, play and pause. */
  [VDStyle drawGlyph: VDGlyphBack
              inRect: NSInsetRect ([self rectOfPart: VDPartBack], 7, 7)
               color: white];
  [VDStyle drawGlyph: [player isPlaying] ? VDGlyphPause : VDGlyphPlay
              inRect: NSInsetRect ([self rectOfPart: VDPartPlay], 6, 6)
               color: white];
  [VDStyle drawGlyph: VDGlyphForward
              inRect: NSInsetRect ([self rectOfPart: VDPartForward], 7, 7)
               color: white];

  /* Speed and full screen. */
  r = [self rectOfPart: VDPartSpeed];
  [VDFaded ([VDStyle rgb: 0xffffff alpha: .12], a) set];
  [[NSBezierPath bezierPathWithRoundedRect: r xRadius: 5 yRadius: 5] fill];
  VDDrawText (VDSpeedString ([player speed]),
              NSMakeRect (NSMinX (r), NSMinY (r) + 3, NSWidth (r), 16),
              [VDStyle fontOfSize: 12 bold: YES], white,
              NSCenterTextAlignment);
  [VDStyle drawGlyph: [player isFullScreen] ? VDGlyphExitFullScreen
                                            : VDGlyphFullScreen
              inRect: NSInsetRect ([self rectOfPart: VDPartFullScreen],
                                   8.5, 8.5)
               color: [player hasVideo] ? white : VDFaded (white, .35)];

  /* The scrubber, between the time played and the length. */
  row2 = VDRowTop + VDButton + 6;
  VDDrawText ([VDStyle timeString: t],
              NSMakeRect (VDBarSide - 4, row2 - 1, tw, 16), font, dimText,
              NSLeftTextAlignment);
  VDDrawText (duration > 0 ? [VDStyle timeString: duration] : @"--:--",
              NSMakeRect (NSMaxX (b) - VDBarSide - tw + 4, row2 - 1, tw, 16),
              font, dimText, NSRightTextAlignment);
  r = [self rectOfPart: VDPartScrubber];
  track = NSMakeRect (NSMinX (r), row2 + 4, NSWidth (r), 5);
  [VDFaded ([VDStyle rgb: 0xffffff alpha: .22], a) set];
  [[NSBezierPath bezierPathWithRoundedRect: track xRadius: 2.5 yRadius: 2.5]
    fill];
  fraction = duration > 0 ? MIN (MAX (t / duration, 0), 1) : 0;
  track.size.width = floor (NSWidth (r) * fraction);
  if (track.size.width > 0)
    {
      [VDFaded ([VDStyle accent], a) set];
      [[NSBezierPath bezierPathWithRoundedRect: track xRadius: 2.5
                                       yRadius: 2.5] fill];
    }
  [white set];
  [[NSBezierPath bezierPathWithOvalInRect:
                   NSMakeRect (NSMinX (r) + NSWidth (r) * fraction - 6.5,
                               row2 + 4 + 2.5 - 6.5, 13, 13)] fill];
}

- (void) trackPart: (VDPart)part at: (NSPoint)p
{
  NSRect r = [self rectOfPart: part];
  double fraction = (p.x - NSMinX (r)) / NSWidth (r);

  fraction = MIN (MAX (fraction, 0), 1);
  if (part == VDPartVolume)
    [player setVolume: (float) fraction];
  else if (part == VDPartScrubber)
    [player scrubTo: fraction];
}

- (void) mouseDown: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  VDPart part = [self partAt: p];

  [player pointerMoved];
  dragging = VDPartNone;
  switch (part)
    {
    case VDPartMute:
      [player toggleMute: self];
      break;
    case VDPartBack:
      [player skipBackward: self];
      break;
    case VDPartPlay:
      [player togglePlay: self];
      break;
    case VDPartForward:
      [player skipForward: self];
      break;
    case VDPartSpeed:
      [player cycleSpeed: self];
      break;
    case VDPartFullScreen:
      [player toggleFullScreen: self];
      break;
    case VDPartVolume:
      dragging = part;
      [self trackPart: part at: p];
      break;
    case VDPartScrubber:
      dragging = part;
      [player scrubBegin];
      [self trackPart: part at: p];
      break;
    default:
      break;
    }
  [self setNeedsDisplay: YES];
}

- (void) mouseDragged: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];

  [player pointerMoved];
  if (dragging != VDPartNone)
    {
      [self trackPart: dragging at: p];
      [self setNeedsDisplay: YES];
    }
}

- (void) mouseUp: (NSEvent *)event
{
  if (dragging == VDPartScrubber)
    [player scrubEnd];
  dragging = VDPartNone;
  [self setNeedsDisplay: YES];
}

- (void) mouseMoved: (NSEvent *)event
{
  [player pointerMoved];
  [player pointerOverBar: YES];
}

- (void) mouseEntered: (NSEvent *)event
{
  [player pointerOverBar: YES];
}

- (void) mouseExited: (NSEvent *)event
{
  [player pointerOverBar: NO];
}

@end

/* ---- the video ---- */

@interface VDPlayerView : NSView
{
  VDPlayer *player;		/* not retained */
  VDControlBar *bar;
  NSTrackingRectTag viewTag;
  NSTrackingRectTag barTag;
}
- (id) initWithFrame: (NSRect)frame player: (VDPlayer *)p;
- (VDControlBar *) bar;
- (NSRect) videoRect;
- (void) layoutBar;
- (void) resetTracking;
@end

@implementation VDPlayerView

- (id) initWithFrame: (NSRect)frame player: (VDPlayer *)p
{
  if ((self = [super initWithFrame: frame]) != nil)
    {
      player = p;
      bar = [[VDControlBar alloc] initWithFrame: NSMakeRect (0, 0, VDBarWidth,
                                                             VDBarHeight)
                                         player: p];
      [self addSubview: bar];
      [self layoutBar];
    }
  return self;
}

- (void) dealloc
{
  RELEASE (bar);
  [super dealloc];
}

- (VDControlBar *) bar
{
  return bar;
}

- (BOOL) acceptsFirstResponder
{
  return YES;
}

- (BOOL) acceptsFirstMouse: (NSEvent *)event
{
  return YES;
}

- (BOOL) isOpaque
{
  return YES;
}

- (void) resetTracking
{
  if (viewTag != 0)
    [self removeTrackingRect: viewTag];
  if (barTag != 0)
    [bar removeTrackingRect: barTag];
  viewTag = barTag = 0;
  if ([self window] == nil)
    return;
  viewTag = [self addTrackingRect: [self bounds] owner: self userData: NULL
                     assumeInside: NO];
  barTag = [bar addTrackingRect: [bar bounds] owner: bar userData: NULL
                   assumeInside: NO];
}

- (void) viewDidMoveToWindow
{
  [self resetTracking];
}

- (void) layoutBar
{
  NSRect b = [self bounds];
  CGFloat w = MIN (VDBarWidth, b.size.width - 2 * VDBarSide);

  [bar setFrame: NSMakeRect (floor (NSMidX (b) - w / 2), VDBarBottom, w,
                             VDBarHeight)];
}

- (void) setFrameSize: (NSSize)size
{
  [super setFrameSize: size];
  [self layoutBar];
  [self setNeedsDisplay: YES];
  [self resetTracking];
}

- (NSRect) videoRect
{
  return VDFit ([self bounds], [player videoSize]);
}

- (void) drawRect: (NSRect)rect
{
  NSBitmapImageRep *rep = [player currentPicture];
  NSRect b = [self bounds], g;
  NSAffineTransform *flip;
  NSString *name;

  [[NSColor blackColor] set];
  NSRectFill (rect);
  if (rep != nil)
    {
      [rep drawInRect: [self videoRect]];
      return;
    }
  if ([player hasVideo])
    return;

  /* Sound only: a note, and the name. */
  g = NSMakeRect (floor (NSMidX (b) - 24), NSMaxY (b) - 26 - 48, 48, 48);
  if (NSMinY (g) > VDBarBottom + VDBarHeight + 8)
    {
      [NSGraphicsContext saveGraphicsState];
      flip = [NSAffineTransform transform];
      [flip translateXBy: 0 yBy: NSMinY (g) * 2 + NSHeight (g)];
      [flip scaleXBy: 1 yBy: -1];
      [flip concat];
      [VDStyle drawGlyph: VDGlyphMusic inRect: g
                   color: [VDStyle rgb: 0x9aa0ac alpha: 1]];
      [NSGraphicsContext restoreGraphicsState];
    }
  name = [[[player path] lastPathComponent] stringByDeletingPathExtension];
  VDDrawText (name, NSMakeRect (20, NSMinY (g) - 26, NSWidth (b) - 40, 18),
              [VDStyle fontOfSize: 13 bold: YES],
              [VDStyle rgb: 0xe9ebef alpha: 1], NSCenterTextAlignment);
}

- (void) mouseDown: (NSEvent *)event
{
  [player pointerMoved];
  if ([event clickCount] == 2)
    {
      /* The first click played or paused: take it back. */
      [player togglePlay: self];
      [player toggleFullScreen: self];
    }
  else if ([event clickCount] == 1)
    [player togglePlay: self];
}

- (void) mouseMoved: (NSEvent *)event
{
  NSPoint p = [bar convertPoint: [event locationInWindow] fromView: nil];

  [player pointerMoved];
  [player pointerOverBar: NSPointInRect (p, [bar bounds])];
}

- (void) mouseEntered: (NSEvent *)event
{
  [player pointerInside: YES];
}

- (void) mouseExited: (NSEvent *)event
{
  [player pointerInside: NO];
}

- (void) keyDown: (NSEvent *)event
{
  NSString *keys = [event charactersIgnoringModifiers];
  unichar c = [keys length] > 0 ? [keys characterAtIndex: 0] : 0;

  switch (c)
    {
    case ' ':
      [player togglePlay: self];
      break;
    case NSLeftArrowFunctionKey:
      [player skipBy: -VDKeySkip];
      break;
    case NSRightArrowFunctionKey:
      [player skipBy: VDKeySkip];
      break;
    case NSUpArrowFunctionKey:
      [player volumeUp: self];
      break;
    case NSDownArrowFunctionKey:
      [player volumeDown: self];
      break;
    case 27:			/* Escape */
      if ([player isFullScreen])
        [player toggleFullScreen: self];
      break;
    default:
      [super keyDown: event];
      return;
    }
  [player pointerMoved];
}

@end

/* A borderless window may take the keys. */
@interface VDFullScreenWindow : NSWindow
@end

@implementation VDFullScreenWindow
- (BOOL) canBecomeKeyWindow
{
  return YES;
}

/* Not main: in the in-window menu style the theme gives main windows a
   menu bar, which full screen mustn't have. */
- (BOOL) canBecomeMainWindow
{
  return NO;
}
@end

/* ---- the player ---- */

@interface VDPlayer ()
- (id) initWithPath: (NSString *)p media: (VDMedia *)m;
- (void) tick: (NSTimer *)t;
- (void) updateOutputSize;
- (void) refreshBar;
@end

@implementation VDPlayer

+ (VDPlayer *) playerWithPath: (NSString *)p
{
  char error[256];
  VDMedia *m = VDMediaOpen ([p fileSystemRepresentation], error,
                            sizeof (error));

  if (m == NULL)
    {
      NSRunAlertPanel ([NSString stringWithFormat:
                                   @"“%@” can't be opened.",
                                 [p lastPathComponent]],
                       @"%@", @"OK", nil, nil,
                       [NSString stringWithUTF8String: error]);
      return nil;
    }
  return AUTORELEASE ([[VDPlayer alloc] initWithPath: p media: m]);
}

- (id) initWithPath: (NSString *)p media: (VDMedia *)m
{
  NSRect visible = [[NSScreen mainScreen] visibleFrame], frame;
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  NSSize size;
  CGFloat scale;

  if ((self = [super init]) == nil)
    {
      VDMediaClose (m);
      return nil;
    }
  path = [p copy];
  media = m;
  VDMediaGetInfo (media, &info);
  speed = 1.0;
  volume = [defs objectForKey: VDVolumeKey] != nil
    ? [defs floatForKey: VDVolumeKey] : 1.0f;
  VDMediaSetVolume (media, volume);
  barAlpha = 1;
  lastMove = VDMonotonic ();
  pointerInside = YES;		/* the controls show for a moment */

  /* The video's own size, made to fit on the screen, and not so small
     the controls don't fit. */
  if (info.hasVideo && info.width > 0 && info.height > 0)
    size = NSMakeSize (info.width, info.height);
  else
    size = NSMakeSize (VDBarWidth + 2 * VDBarSide, VDAudioHeight);
  scale = MIN (1.0, MIN (visible.size.width * 0.85 / size.width,
                         visible.size.height * 0.85 / size.height));
  size.width = floor (size.width * scale);
  size.height = floor (size.height * scale);
  if (size.width < VDMinWidth)
    {
      size.height = floor (size.height * VDMinWidth / size.width);
      size.width = VDMinWidth;
    }

  frame = NSMakeRect (0, 0, size.width, size.height);
  window = [[NSWindow alloc]
             initWithContentRect: frame
                       styleMask: (NSTitledWindowMask | NSClosableWindowMask
                                   | NSMiniaturizableWindowMask
                                   | NSResizableWindowMask)
                         backing: NSBackingStoreBuffered
                           defer: NO];
  [window setReleasedWhenClosed: NO];
  [window setTitle: [path lastPathComponent]];
  [window setRepresentedFilename: path];
  [window setBackgroundColor: [NSColor blackColor]];
  [window setAcceptsMouseMovedEvents: YES];
  [window setDelegate: (id) self];
  if (info.hasVideo && info.width > 0 && info.height > 0)
    [window setContentAspectRatio: size];
  [window setContentMinSize: NSMakeSize (VDMinWidth * 0.75,
                                         VDBarHeight + 2 * VDBarBottom)];
  view = [[VDPlayerView alloc] initWithFrame: frame player: self];
  bar = [view bar];
  [window setContentView: view];
  [window makeFirstResponder: view];
  [window center];
  [self updateOutputSize];
  return self;
}

- (void) dealloc
{
  [timer invalidate];
  [window setDelegate: nil];
  [fullScreenWindow setDelegate: nil];
  VDMediaClose (media);
  VDImageFree (&image);
  RELEASE (rep);
  RELEASE (view);
  RELEASE (window);
  RELEASE (fullScreenWindow);
  RELEASE (infoPanel);
  RELEASE (shownTime);
  RELEASE (path);
  [super dealloc];
}

- (NSString *) path
{
  return path;
}

- (NSWindow *) window
{
  return fullScreenWindow != nil ? fullScreenWindow : window;
}

- (void) show
{
  NSRunLoop *loop = [NSRunLoop currentRunLoop];

  [window makeKeyAndOrderFront: nil];
  if (timer == nil)
    {
      timer = [NSTimer timerWithTimeInterval: VDTick target: self
                                    selector: @selector(tick:)
                                    userInfo: nil repeats: YES];
      [loop addTimer: timer forMode: NSDefaultRunLoopMode];
      [loop addTimer: timer forMode: NSEventTrackingRunLoopMode];
      [loop addTimer: timer forMode: NSModalPanelRunLoopMode];
    }
  VDMediaPlay (media);
}

- (void) close
{
  if (fullScreenWindow != nil)
    [self toggleFullScreen: nil];
  [window performClose: nil];
}

- (void) windowWillClose: (NSNotification *)n
{
  if ([n object] != window)
    return;
  [timer invalidate];
  timer = nil;
  VDMediaPause (media);
  [infoPanel close];
  [[NSNotificationCenter defaultCenter]
    postNotificationName: VDPlayerClosedNotification object: self];
}

- (void) windowDidResize: (NSNotification *)n
{
  [self updateOutputSize];
}

- (void) updateOutputSize
{
  NSRect r = [view videoRect];

  VDMediaSetOutputSize (media, (int) NSWidth (r), (int) NSHeight (r));
}

/* ---- the clock ---- */

- (void) tick: (NSTimer *)t
{
  BOOL rest, playing;
  NSString *now;
  float target;

  if (VDMediaCopyFrame (media, &image))
    {
      NSBitmapImageRep *r;
      unsigned char *data;
      int y;

      r = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes: NULL
                          pixelsWide: image.width
                          pixelsHigh: image.height
                       bitsPerSample: 8
                     samplesPerPixel: 3
                            hasAlpha: NO
                            isPlanar: NO
                      colorSpaceName: NSDeviceRGBColorSpace
                         bytesPerRow: image.width * 3
                        bitsPerPixel: 24];
      data = [r bitmapData];
      if (data != NULL)
        {
          for (y = 0; y < image.height; y++)
            memcpy (data + (size_t) y * image.width * 3,
                    image.rgb + (size_t) y * image.stride,
                    (size_t) image.width * 3);
          ASSIGN (rep, r);
          [view setNeedsDisplayInRect: [view videoRect]];
        }
      RELEASE (r);
    }

  /* The controls fade while it plays and the pointer rests on the
     video; sound alone keeps them. */
  playing = VDMediaIsPlaying (media);
  rest = playing && info.hasVideo && !scrubbing && !pointerOverBar
    && (VDMonotonic () - lastMove > VDRestSeconds || !pointerInside);
  if (rest && fullScreenWindow == nil && !pointerInside)
    rest = VDMonotonic () - lastMove > 0.6;
  target = rest ? 0 : 1;
  if (barAlpha != target)
    {
      barAlpha = target > barAlpha ? MIN (barAlpha + VDFadeStep * 2, 1)
        : MAX (barAlpha - VDFadeStep, 0);
      [bar setHidden: barAlpha <= 0];
      [view setNeedsDisplayInRect: [bar frame]];
      if (barAlpha <= 0 && fullScreenWindow != nil)
        [NSCursor setHiddenUntilMouseMoves: YES];
    }

  /* The time shown, and the play button, as they change. */
  now = [NSString stringWithFormat: @"%@ %d",
                  [VDStyle timeString: VDMediaTime (media)], playing];
  if (![now isEqual: shownTime])
    {
      ASSIGN (shownTime, now);
      [view setNeedsDisplayInRect: [bar frame]];
    }
}

- (void) refreshBar
{
  DESTROY (shownTime);
  [view setNeedsDisplayInRect: [bar frame]];
}

- (NSBitmapImageRep *) currentPicture
{
  return rep;
}

- (NSSize) videoSize
{
  if (!info.hasVideo || info.width <= 0 || info.height <= 0)
    return NSZeroSize;
  return NSMakeSize (info.width, info.height);
}

/* ---- the controls ---- */

- (BOOL) isPlaying
{
  return VDMediaIsPlaying (media);
}

- (double) time
{
  return VDMediaTime (media);
}

- (double) duration
{
  return info.duration;
}

- (float) volume
{
  return volume;
}

- (BOOL) isMuted
{
  return muted;
}

- (double) speed
{
  return speed;
}

- (BOOL) isFullScreen
{
  return fullScreenWindow != nil;
}

- (BOOL) hasVideo
{
  return info.hasVideo;
}

- (float) barAlpha
{
  return barAlpha;
}

- (void) pointerMoved
{
  lastMove = VDMonotonic ();
  pointerInside = YES;
}

- (void) pointerOverBar: (BOOL)over
{
  pointerOverBar = over;
}

- (void) pointerInside: (BOOL)inside
{
  pointerInside = inside;
  if (!inside)
    pointerOverBar = NO;
}

- (void) togglePlay: (id)sender
{
  if (VDMediaIsPlaying (media))
    VDMediaPause (media);
  else
    VDMediaPlay (media);
  [self refreshBar];
}

- (void) skipBy: (double)seconds
{
  VDMediaSeek (media, VDMediaTime (media) + seconds);
  [self refreshBar];
}

- (void) skipForward: (id)sender
{
  [self skipBy: VDButtonSkip];
}

- (void) skipBackward: (id)sender
{
  [self skipBy: -VDButtonSkip];
}

- (void) setVolume: (float)v
{
  volume = MIN (MAX (v, 0), 1);
  muted = NO;
  VDMediaSetVolume (media, volume);
  [[NSUserDefaults standardUserDefaults] setFloat: volume
                                           forKey: VDVolumeKey];
  [self refreshBar];
}

- (void) volumeUp: (id)sender
{
  [self setVolume: volume + VDVolumeStep];
}

- (void) volumeDown: (id)sender
{
  [self setVolume: volume - VDVolumeStep];
}

- (void) toggleMute: (id)sender
{
  muted = !muted;
  VDMediaSetVolume (media, muted ? 0 : volume);
  [self refreshBar];
}

- (void) setSpeed: (double)s
{
  speed = s;
  VDMediaSetSpeed (media, s);
  [self refreshBar];
}

- (void) setSpeedFromMenu: (id)sender
{
  [self setSpeed: [sender tag] / 100.0];
}

- (void) cycleSpeed: (id)sender
{
  int i;

  for (i = 0; i < VDSpeedCount; i++)
    if (VDSpeeds[i] > speed + 0.01)
      break;
  [self setSpeed: i < VDSpeedCount ? VDSpeeds[i] : VDSpeeds[0]];
}

- (void) scrubBegin
{
  scrubbing = YES;
  wasPlaying = VDMediaIsPlaying (media);
  VDMediaPause (media);
}

- (void) scrubTo: (double)fraction
{
  if (info.duration > 0)
    VDMediaSeek (media, fraction * info.duration);
  [self refreshBar];
}

- (void) scrubEnd
{
  scrubbing = NO;
  if (wasPlaying)
    VDMediaPlay (media);
  [self refreshBar];
}

- (void) toggleFullScreen: (id)sender
{
  NSScreen *screen;
  NSRect frame;

  if (fullScreenWindow == nil)
    {
      if (!info.hasVideo)
        return;
      screen = [window screen] != nil ? [window screen]
        : [NSScreen mainScreen];
      frame = [screen frame];
      fullScreenWindow = [[VDFullScreenWindow alloc]
                           initWithContentRect: frame
                                     styleMask: NSBorderlessWindowMask
                                       backing: NSBackingStoreBuffered
                                         defer: NO];
      [fullScreenWindow setReleasedWhenClosed: NO];
      [fullScreenWindow setBackgroundColor: [NSColor blackColor]];
      [fullScreenWindow setAcceptsMouseMovedEvents: YES];
      [fullScreenWindow setLevel: NSScreenSaverWindowLevel];
      [fullScreenWindow setTitle: [window title]];
      [fullScreenWindow setDelegate: (id) self];
      RETAIN (view);
      [window setContentView: AUTORELEASE ([[NSView alloc]
                                             initWithFrame: [view frame]])];
      [fullScreenWindow setContentView: view];
      RELEASE (view);
      [window orderOut: nil];
      [fullScreenWindow makeKeyAndOrderFront: nil];
      [fullScreenWindow makeFirstResponder: view];
    }
  else
    {
      RETAIN (view);
      [fullScreenWindow setContentView:
                          AUTORELEASE ([[NSView alloc]
                                         initWithFrame: [view frame]])];
      [fullScreenWindow orderOut: nil];
      [window setContentView: view];
      RELEASE (view);
      [window makeKeyAndOrderFront: nil];
      [window makeFirstResponder: view];
      [fullScreenWindow setDelegate: nil];
      DESTROY (fullScreenWindow);
    }
  [view layoutBar];
  [view resetTracking];
  [view setNeedsDisplay: YES];
  [self updateOutputSize];
  [self pointerMoved];
  [self refreshBar];
}

/* ---- Info ---- */

static NSTextField *
VDLabel (NSRect frame, NSString *text, NSFont *font, NSColor *color,
         NSTextAlignment alignment)
{
  NSTextField *label = AUTORELEASE ([[NSTextField alloc]
                                      initWithFrame: frame]);

  [label setStringValue: text != nil ? text : @""];
  [label setEditable: NO];
  [label setSelectable: YES];
  [label setBordered: NO];
  [label setBezeled: NO];
  [label setDrawsBackground: NO];
  [label setFont: font];
  [label setTextColor: color];
  [label setAlignment: alignment];
  return label;
}

- (void) showInfo: (id)sender
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *attributes = [fm fileAttributesAtPath: path
                                         traverseLink: YES];
  NSMutableArray *rows = [NSMutableArray array];
  NSView *content;
  NSFont *font = [VDStyle fontOfSize: 12 bold: NO];
  NSFont *bold = [VDStyle fontOfSize: 12 bold: YES];
  NSString *kind;
  CGFloat y, height, labelWidth = 92, width = 440;
  unsigned i;

  if (infoPanel != nil)
    {
      [infoPanel makeKeyAndOrderFront: nil];
      return;
    }
  kind = info.hasVideo ? [NSString stringWithFormat: @"%@ movie",
                                  [[path pathExtension] uppercaseString]]
    : [NSString stringWithFormat: @"%@ sound",
                [[path pathExtension] uppercaseString]];
  [rows addObject: [NSArray arrayWithObjects: @"Kind:", kind, nil]];
  [rows addObject: [NSArray arrayWithObjects: @"Size:",
                            [NSString stringWithFormat: @"%@ (%llu bytes)",
                                      [VDStyle sizeString:
                                                 [attributes fileSize]],
                                      [attributes fileSize]], nil]];
  [rows addObject: [NSArray arrayWithObjects: @"Length:",
                            info.duration > 0
                            ? [VDStyle timeString: info.duration]
                            : @"Unknown", nil]];
  if (info.hasVideo)
    {
      [rows addObject: [NSArray arrayWithObjects: @"Dimensions:",
                                [NSString stringWithFormat: @"%d × %d",
                                          info.width, info.height], nil]];
      if (info.frameRate > 0)
        [rows addObject: [NSArray arrayWithObjects: @"Frame rate:",
                                  [NSString stringWithFormat:
                                              @"%.4g frames a second",
                                            info.frameRate], nil]];
      [rows addObject: [NSArray arrayWithObjects: @"Video:",
                                [NSString stringWithUTF8String:
                                            info.videoCodec], nil]];
    }
  if (info.hasAudio)
    [rows addObject: [NSArray arrayWithObjects: @"Sound:",
                              [NSString stringWithFormat: @"%s, %s, %.1f kHz",
                                        info.audioCodec,
                                        info.channels == 1 ? "mono"
                                        : (info.channels == 2 ? "stereo"
                                           : "surround"),
                                        info.sampleRate / 1000.0], nil]];
  if (VDMediaAudioStatus (media)[0] != '\0')
    [rows addObject: [NSArray arrayWithObjects: @"",
                              [NSString stringWithUTF8String:
                                          VDMediaAudioStatus (media)], nil]];
  if (info.bitRate > 0)
    [rows addObject: [NSArray arrayWithObjects: @"Data rate:",
                              [NSString stringWithFormat: @"%.0f kbit/s",
                                        info.bitRate / 1000.0], nil]];
  [rows addObject: [NSArray arrayWithObjects: @"Format:",
                            [NSString stringWithUTF8String: info.container],
                            nil]];
  [rows addObject: [NSArray arrayWithObjects: @"Where:",
                            [[path stringByDeletingLastPathComponent]
                              stringByAbbreviatingWithTildeInPath], nil]];

  height = 16 + 24 + 10 + [rows count] * 20 + 14;
  infoPanel = [[NSPanel alloc]
                initWithContentRect: NSMakeRect (0, 0, width, height)
                          styleMask: NSTitledWindowMask | NSClosableWindowMask
                            backing: NSBackingStoreBuffered
                              defer: NO];
  [infoPanel setReleasedWhenClosed: NO];
  [infoPanel setTitle: @"Info"];
  [infoPanel setBackgroundColor: [VDStyle page]];
  content = [infoPanel contentView];
  y = height - 16 - 20;
  {
    NSTextField *name = VDLabel (NSMakeRect (16, y, width - 32, 20),
                                 [path lastPathComponent],
                                 [VDStyle fontOfSize: 14 bold: YES],
                                 [VDStyle text], NSLeftTextAlignment);

    [name setSelectable: NO];
    [content addSubview: name];
  }
  y -= 14;
  for (i = 0; i < [rows count]; i++)
    {
      NSArray *row = [rows objectAtIndex: i];

      y -= 20;
      [content addSubview: VDLabel (NSMakeRect (16, y, labelWidth, 18),
                                    [row objectAtIndex: 0], bold,
                                    [VDStyle dim], NSRightTextAlignment)];
      [content addSubview: VDLabel (NSMakeRect (16 + labelWidth + 8, y,
                                                width - labelWidth - 40, 18),
                                    [row objectAtIndex: 1], font,
                                    [VDStyle text], NSLeftTextAlignment)];
    }
  [infoPanel center];
  [infoPanel makeKeyAndOrderFront: nil];
}

/* ---- Save ---- */

- (void) saveCopy: (id)sender
{
  NSSavePanel *panel = [NSSavePanel savePanel];
  NSString *to;

  [panel setTitle: @"Save"];
  [panel setRequiredFileType: [path pathExtension]];
  if ([panel runModalForDirectory: [path stringByDeletingLastPathComponent]
                             file: [path lastPathComponent]] != NSOKButton)
    return;
  to = [panel filename];
  if ([to isEqual: path])
    return;
  if ([[NSFileManager defaultManager] fileExistsAtPath: to])
    [[NSFileManager defaultManager] removeFileAtPath: to handler: nil];
  if (![[NSFileManager defaultManager] copyPath: path toPath: to
                                        handler: nil])
    NSRunAlertPanel (@"The movie couldn't be saved.",
                     @"It couldn't be copied to %@.", @"OK", nil, nil, to);
}

/* ---- menus ---- */

- (BOOL) validateMenuItem: (id <NSMenuItem>)item
{
  SEL action = [item action];

  if (action == @selector(togglePlay:))
    [item setTitle: VDMediaIsPlaying (media) ? @"Pause" : @"Play"];
  else if (action == @selector(toggleFullScreen:))
    {
      [item setTitle: fullScreenWindow != nil ? @"Exit Full Screen"
                                              : @"Enter Full Screen"];
      return info.hasVideo;
    }
  else if (action == @selector(toggleMute:))
    [item setState: muted ? NSOnState : NSOffState];
  else if (action == @selector(setSpeedFromMenu:))
    [item setState: fabs ([item tag] / 100.0 - speed) < 0.01
          ? NSOnState : NSOffState];
  return YES;
}

@end
