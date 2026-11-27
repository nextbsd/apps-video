/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "VDRecording.h"
#import "VDScreenRecording.h"
#import "VDStyle.h"
#import <GNUstepBase/GNUstep.h>

#include "VDAudio.h"
#include "VDRecorder.h"
#include "WCCapture.h"

#include <math.h>
#include <string.h>
#include <time.h>

/* Layout, in points, as drawn. */
#define VDWindowWidth 760.0
#define VDWindowHeight 530.0
#define VDBarWidth 680.0
#define VDBarHeight 64.0
#define VDBarBottom 20.0
#define VDPad 14.0
#define VDSegmentHeight 30.0
#define VDRecordButton 44.0
#define VDMeterBars 16
#define VDMicWidth 150.0
#define VDCountWidth 64.0

#define VDTick (1.0 / 60.0)		/* cameras make 30 a second */
#define VDSoundChunk 4096

#define VDMicrophoneKey @"VideoMicrophone"
#define VDCameraKey @"VideoCamera"
#define VDFolderKey @"VideoRecordingsFolder"
#define VDTestSourcesKey @"VideoTestSources"

NSString *const VDRecordingClosedNotification = @"VDRecordingClosed";

static double
VDMonotonic (void)
{
  struct timespec ts;

  clock_gettime (CLOCK_MONOTONIC, &ts);
  return (double) ts.tv_sec + ts.tv_nsec / 1e9;
}

static NSDictionary *
VDTextAttributes (NSFont *font, NSColor *color, NSTextAlignment alignment)
{
  NSMutableParagraphStyle *p = AUTORELEASE ([[NSMutableParagraphStyle
                                                defaultParagraphStyle]
                                               mutableCopy]);

  [p setAlignment: alignment];
  [p setLineBreakMode: NSLineBreakByTruncatingTail];
  return [NSDictionary dictionaryWithObjectsAndKeys:
                         font, NSFontAttributeName,
                       color, NSForegroundColorAttributeName,
                       p, NSParagraphStyleAttributeName, nil];
}

@class VDRecordBar;

@interface VDRecording ()
- (id) initWithSource: (VDSource)s;
- (VDSource) source;
- (void) setSource: (VDSource)s;
- (NSString *) microphoneName;
- (void) chooseMicrophoneFromView: (NSView *)v event: (NSEvent *)event;
- (float) level;
- (BOOL) canRecord;
- (double) seconds;
- (long long) bytes;
- (NSBitmapImageRep *) picture;
- (NSString *) message;
@end

/* ---- the bar ---- */

@interface VDRecordBar : NSView
{
  VDRecording *recording;	/* not retained */
}
- (id) initWithFrame: (NSRect)frame recording: (VDRecording *)r;
@end

static NSString *const VDSourceNames[] = { @"Screen", @"Selection",
                                           @"Camera", @"Sound only" };
static const VDGlyph VDSourceGlyphs[] = { VDGlyphScreen, VDGlyphSelection,
                                          VDGlyphCamera, VDGlyphMicrophone };

@implementation VDRecordBar

- (id) initWithFrame: (NSRect)frame recording: (VDRecording *)r
{
  if ((self = [super initWithFrame: frame]) != nil)
    recording = r;
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

- (NSFont *) segmentFont
{
  return [VDStyle fontOfSize: 12 bold: NO];
}

- (NSRect) rectOfSegment: (int)i
{
  NSDictionary *a = VDTextAttributes ([self segmentFont], [NSColor whiteColor],
                                      NSLeftTextAlignment);
  CGFloat x = VDPad + 2, w = 0;
  int k;

  for (k = 0; k <= i; k++)
    {
      x += w;
      w = 10 + 14 + 6 + ceil ([VDSourceNames[k] sizeWithAttributes: a].width)
        + 10;
    }
  return NSMakeRect (x, (VDBarHeight - VDSegmentHeight) / 2 + 2, w,
                     VDSegmentHeight - 4);
}

- (NSRect) countRect
{
  return NSMakeRect (NSMaxX ([self bounds]) - VDPad - VDCountWidth, 0,
                     VDCountWidth, VDBarHeight);
}

- (NSRect) recordRect
{
  return NSMakeRect (NSMinX ([self countRect]) - 10 - VDRecordButton,
                     (VDBarHeight - VDRecordButton) / 2, VDRecordButton,
                     VDRecordButton);
}

- (NSRect) microphoneRect
{
  return NSMakeRect (NSMinX ([self recordRect]) - 14 - VDMicWidth, 12,
                     VDMicWidth, 18);
}

- (void) drawRect: (NSRect)rect
{
  NSRect b = [self bounds], r, seg, c;
  NSBezierPath *path;
  NSColor *white = [NSColor whiteColor];
  NSColor *soft = [VDStyle rgb: 0xcfd3da alpha: 1];
  NSColor *faint = [VDStyle rgb: 0x8d929c alpha: 1];
  NSFont *small = [VDStyle fontOfSize: 11 bold: NO];
  VDSource source = [recording source];
  BOOL recordingNow = [recording isRecording];
  BOOL soundSource = source == VDSourceCamera || source == VDSourceSound;
  float level = [recording level];
  CGFloat x, h;
  int i, lit;
  static const CGFloat heights[VDMeterBars] = { 6, 9, 12, 10, 14, 16, 13,
                                                15, 12, 14, 11, 9, 7, 5, 4,
                                                4 };

  path = [NSBezierPath bezierPathWithRoundedRect: NSInsetRect (b, 0.5, 0.5)
                                         xRadius: 14 yRadius: 14];
  [[VDStyle rgb: 0x14171d alpha: .82] set];
  [path fill];
  [[VDStyle rgb: 0xffffff alpha: .12] set];
  [path setLineWidth: 1];
  [path stroke];

  /* The sources. */
  r = NSUnionRect ([self rectOfSegment: 0], [self rectOfSegment: 3]);
  r = NSInsetRect (r, -2, -2);
  [[VDStyle rgb: 0xffffff alpha: recordingNow ? .07 : .14] set];
  [[NSBezierPath bezierPathWithRoundedRect: r xRadius: 8 yRadius: 8] fill];
  for (i = 0; i < 4; i++)
    {
      NSColor *color = recordingNow && i != (int) source ? faint : white;

      seg = [self rectOfSegment: i];
      if (i == (int) source)
        {
          [[VDStyle rgb: 0xffffff alpha: .26] set];
          [[NSBezierPath bezierPathWithRoundedRect: seg xRadius: 6 yRadius: 6]
            fill];
        }
      [VDStyle drawGlyph: VDSourceGlyphs[i]
                  inRect: NSMakeRect (NSMinX (seg) + 10, NSMidY (seg) - 7,
                                      14, 14)
                   color: color];
      [VDSourceNames[i] drawInRect: NSMakeRect (NSMinX (seg) + 30,
                                                NSMidY (seg) - 8,
                                                NSWidth (seg) - 34, 16)
                    withAttributes: VDTextAttributes ([self segmentFont],
                                                      color,
                                                      NSLeftTextAlignment)];
    }

  /* The microphone and its level. */
  r = [self microphoneRect];
  [VDStyle drawGlyph: VDGlyphMicrophone
              inRect: NSMakeRect (NSMinX (r), NSMinY (r) + 2, 13, 13)
               color: soundSource ? soft : faint];
  {
    NSString *name = [recording microphoneName];
    NSDictionary *a = VDTextAttributes (small, soundSource ? soft : faint,
                                        NSLeftTextAlignment);
    CGFloat w = MIN (ceil ([name sizeWithAttributes: a].width),
                     NSWidth (r) - 19 - 14);

    [name drawInRect: NSMakeRect (NSMinX (r) + 19, NSMinY (r) + 1, w, 16)
      withAttributes: a];
    [VDStyle drawGlyph: VDGlyphChevronDown
                inRect: NSMakeRect (NSMinX (r) + 19 + w + 4, NSMinY (r) + 4,
                                    10, 10)
                 color: faint];
  }
  lit = (int) lrint (level * VDMeterBars);
  x = NSMinX (r);
  for (i = 0; i < VDMeterBars; i++)
    {
      NSColor *color;

      h = heights[i];
      if (i < lit)
        color = i < 10 ? [VDStyle rgb: 0x7bd88f alpha: 1]
          : (i < 13 ? [VDStyle rgb: 0xf2c94c alpha: 1]
             : [VDStyle rgb: 0xff6b6b alpha: 1]);
      else
        color = [VDStyle rgb: 0xffffff alpha: .25];
      [color set];
      if (i >= lit)
        h = 4;
      [[NSBezierPath bezierPathWithRoundedRect:
                       NSMakeRect (x, NSMaxY (r) + 4 + 16 - h, 5, h)
                                       xRadius: 2 yRadius: 2] fill];
      x += 7;
    }

  /* The record button: a red dot, a red square while recording. */
  r = [self recordRect];
  path = [NSBezierPath bezierPathWithOvalInRect: NSInsetRect (r, 1.5, 1.5)];
  [([recording canRecord] || recordingNow ? white : faint) set];
  [path setLineWidth: 3];
  [path stroke];
  if (recordingNow)
    c = NSInsetRect (r, 13, 13);
  else
    c = NSInsetRect (r, 7, 7);
  [[VDStyle rgb: 0xe53935 alpha: [recording canRecord] || recordingNow
            ? 1 : .45] set];
  if (recordingNow)
    [[NSBezierPath bezierPathWithRoundedRect: c xRadius: 3 yRadius: 3] fill];
  else
    [[NSBezierPath bezierPathWithOvalInRect: c] fill];

  /* The time and the size. */
  r = [self countRect];
  [[VDStyle timeString: [recording seconds]]
    drawInRect: NSMakeRect (NSMinX (r), 15, NSWidth (r), 16)
    withAttributes: VDTextAttributes ([VDStyle fontOfSize: 12 bold: YES],
                                      white, NSRightTextAlignment)];
  [[VDStyle sizeString: [recording bytes]]
    drawInRect: NSMakeRect (NSMinX (r), 32, NSWidth (r), 16)
    withAttributes: VDTextAttributes (small,
                                      [VDStyle rgb: 0xaeb3bc alpha: 1],
                                      NSRightTextAlignment)];
}

- (void) mouseDown: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  NSRect mic = [self microphoneRect];
  int i;

  if (NSPointInRect (p, NSInsetRect ([self recordRect], -4, -4)))
    {
      [recording toggleRecording: self];
      return;
    }
  if ([recording isRecording])
    return;
  for (i = 0; i < 4; i++)
    if (NSPointInRect (p, [self rectOfSegment: i]))
      {
        [recording setSource: (VDSource) i];
        return;
      }
  mic.size.height += 22;
  if (NSPointInRect (p, mic))
    [recording chooseMicrophoneFromView: self event: event];
}

@end

/* ---- the preview ---- */

@interface VDRecordView : NSView
{
  VDRecording *recording;	/* not retained */
}
- (id) initWithFrame: (NSRect)frame recording: (VDRecording *)r;
@end

@implementation VDRecordView

- (id) initWithFrame: (NSRect)frame recording: (VDRecording *)r
{
  if ((self = [super initWithFrame: frame]) != nil)
    recording = r;
  return self;
}

- (BOOL) isOpaque
{
  return YES;
}

- (void) drawRect: (NSRect)rect
{
  NSRect b = [self bounds], fit;
  NSBitmapImageRep *picture = [recording picture];
  NSString *message;
  NSGradient *g;
  CGFloat scale;

  g = AUTORELEASE ([[NSGradient alloc]
                     initWithStartingColor: [VDStyle rgb: 0x4a5566 alpha: 1]
                               endingColor: [VDStyle rgb: 0x1a1f27 alpha: 1]]);
  [[VDStyle rgb: 0x0b0d10 alpha: 1] set];
  NSRectFill (rect);
  if (picture != nil)
    {
      NSSize size = NSMakeSize ([picture pixelsWide], [picture pixelsHigh]);

      scale = MIN (b.size.width / size.width, b.size.height / size.height);
      fit.size = NSMakeSize (floor (size.width * scale),
                             floor (size.height * scale));
      fit.origin = NSMakePoint (floor (NSMidX (b) - fit.size.width / 2),
                                floor (NSMidY (b) - fit.size.height / 2));
      [picture drawInRect: fit];
      return;
    }
  [g drawInRect: b relativeCenterPosition: NSMakePoint (0, -0.2)];

  message = [recording message];
  if ([message length] > 0)
    {
      NSRect m = NSMakeRect (60, NSMidY (b) - 60, b.size.width - 120, 60);

      if ([recording source] == VDSourceSound)
        {
          NSRect glyph = NSMakeRect (floor (NSMidX (b) - 32),
                                     NSMidY (b) + 8, 64, 64);
          NSAffineTransform *flip = [NSAffineTransform transform];

          [NSGraphicsContext saveGraphicsState];
          [flip translateXBy: 0 yBy: NSMinY (glyph) * 2 + NSHeight (glyph)];
          [flip scaleXBy: 1 yBy: -1];
          [flip concat];
          [VDStyle drawGlyph: VDGlyphMicrophone inRect: glyph
                       color: [VDStyle rgb: 0xcfd3da alpha: 1]];
          [NSGraphicsContext restoreGraphicsState];
        }
      [message drawInRect: m
           withAttributes: VDTextAttributes ([VDStyle fontOfSize: 14 bold: NO],
                                             [VDStyle rgb: 0xe9ebef alpha: 1],
                                             NSCenterTextAlignment)];
    }
}

@end

/* ---- the recording ---- */

@implementation VDRecording
{
  NSWindow *window;
  VDRecordView *view;
  VDRecordBar *bar;
  NSTimer *timer;
  VDSource source;

  VDAudioInput inputs[VDAudioMaxInputs];
  int inputCount;
  int input;			/* in inputs, or -1: none */
  VDAudioIn *audioIn;
  int audioRate;
  int audioChannels;
  float level;

  WCCapture *camera;
  WCFrame frame;		/* the last picture */
  NSBitmapImageRep *picture;
  NSString *cameraProblem;

  VDRecorder *recorder;
  NSString *path;
  double started;
  double elapsed;
  long long bytes;
  int16_t *sound;
}

+ (VDRecording *) recordingWithSource: (VDSource)s
{
  return AUTORELEASE ([[VDRecording alloc] initWithSource: s]);
}

- (BOOL) testSources
{
  return [[NSUserDefaults standardUserDefaults] boolForKey: VDTestSourcesKey];
}

- (void) listInputs
{
  NSString *chosen = [[NSUserDefaults standardUserDefaults]
                       stringForKey: VDMicrophoneKey];
  int i;

  inputCount = VDAudioListInputs (inputs, VDAudioMaxInputs,
                                  [self testSources]);
  input = inputCount > 0 ? 0 : -1;
  if ([chosen isEqual: @"none"])
    input = -1;
  else if (chosen != nil)
    for (i = 0; i < inputCount; i++)
      if (strcmp (inputs[i].dsp, [chosen UTF8String]) == 0)
        input = i;
}

- (id) initWithSource: (VDSource)s
{
  NSRect frameRect = NSMakeRect (0, 0, VDWindowWidth, VDWindowHeight);

  if ((self = [super init]) == nil)
    return nil;
  sound = malloc (sizeof (int16_t) * VDSoundChunk * 2);
  window = [[NSWindow alloc]
             initWithContentRect: frameRect
                       styleMask: (NSTitledWindowMask | NSClosableWindowMask
                                   | NSMiniaturizableWindowMask)
                         backing: NSBackingStoreBuffered
                           defer: NO];
  [window setReleasedWhenClosed: NO];
  [window setTitle: @"New Recording"];
  [window setDelegate: (id) self];
  view = [[VDRecordView alloc] initWithFrame: frameRect recording: self];
  bar = [[VDRecordBar alloc]
          initWithFrame: NSMakeRect (floor ((VDWindowWidth - VDBarWidth) / 2),
                                     VDBarBottom, VDBarWidth, VDBarHeight)
              recording: self];
  [view addSubview: bar];
  [window setContentView: view];
  [window center];
  [self listInputs];
  source = (VDSource) -1;
  [self setSource: s];
  return self;
}

- (void) dealloc
{
  [timer invalidate];
  [window setDelegate: nil];
  if (recorder != NULL)
    {
      char error[160];
      VDRecorderFinish (recorder, error, sizeof (error));
    }
  VDAudioInClose (audioIn);
  WCCaptureClose (camera);
  free (frame.rgb);
  free (sound);
  RELEASE (picture);
  RELEASE (cameraProblem);
  RELEASE (path);
  RELEASE (bar);
  RELEASE (view);
  RELEASE (window);
  [super dealloc];
}

- (NSWindow *) window
{
  return window;
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
}

/* ---- sources ---- */

- (void) closeCamera
{
  WCCaptureClose (camera);
  camera = NULL;
  frame.width = frame.height = 0;
  DESTROY (picture);
}

- (void) openCamera
{
  WCCameraInfo cameras[WCCaptureMaxCameras];
  NSString *chosen = [[NSUserDefaults standardUserDefaults]
                       stringForKey: VDCameraKey];
  char error[256];
  int count, i, pick = 0;

  DESTROY (cameraProblem);
  count = WCCaptureV4L2Backend.list (cameras, WCCaptureMaxCameras);
  if (count < 0)
    count = 0;
  if (count == 0 && [self testSources])
    count = WCCaptureTestPatternBackend.list (cameras, WCCaptureMaxCameras);
  if (count <= 0)
    {
      cameraProblem = RETAIN (@"No camera is connected.\nPlug one in, then"
                              @" choose Camera again.");
      return;
    }
  for (i = 0; i < count; i++)
    if (chosen != nil && strcmp (cameras[i].ident, [chosen UTF8String]) == 0)
      pick = i;
  camera = WCCaptureOpen (&cameras[pick], error, sizeof (error));
  if (camera == NULL)
    cameraProblem = [[NSString alloc]
                      initWithFormat: @"The camera can't be used.\n%s",
                      error];
}

- (void) closeMicrophone
{
  VDAudioInClose (audioIn);
  audioIn = NULL;
  level = 0;
}

- (void) openMicrophone
{
  char error[256];

  [self closeMicrophone];
  if (input < 0 || input >= inputCount
      || (source != VDSourceCamera && source != VDSourceSound))
    return;
  audioIn = VDAudioInOpen (&inputs[input], &audioRate, &audioChannels,
                           error, sizeof (error));
  if (audioIn == NULL)
    NSLog (@"Video: %s", error);
}

- (VDSource) source
{
  return source;
}

- (void) setSource: (VDSource)s
{
  if (s == source || recorder != NULL)
    return;
  source = s;
  if (source == VDSourceCamera)
    {
      if (camera == NULL)
        [self openCamera];
    }
  else
    [self closeCamera];
  [self openMicrophone];
  [window setTitle: source == VDSourceSound ? @"New Sound Recording"
                  : (source == VDSourceCamera ? @"New Camera Recording"
                     : @"New Screen Recording")];
  [view setNeedsDisplay: YES];
}

- (NSString *) microphoneName
{
  if (source == VDSourceScreen || source == VDSourceSelection)
    return @"Screenshot's microphone";
  if (input < 0 || input >= inputCount)
    return inputCount == 0 ? @"No microphone" : @"None";
  return [NSString stringWithUTF8String: inputs[input].name];
}

- (void) chooseMicrophone: (id)sender
{
  int i = [sender tag];

  input = i;
  [[NSUserDefaults standardUserDefaults]
    setObject: (i >= 0 ? [NSString stringWithUTF8String: inputs[i].dsp]
                : @"none")
       forKey: VDMicrophoneKey];
  [self openMicrophone];
  [bar setNeedsDisplay: YES];
}

- (void) chooseMicrophoneFromView: (NSView *)v event: (NSEvent *)event
{
  NSMenu *menu;
  id<NSMenuItem> item;
  int i;

  if (source != VDSourceCamera && source != VDSourceSound)
    return;
  [self listInputs];
  menu = AUTORELEASE ([[NSMenu alloc] initWithTitle: @"Microphone"]);
  item = [menu addItemWithTitle: @"None" action: @selector(chooseMicrophone:)
                  keyEquivalent: @""];
  [item setTag: -1];
  [item setTarget: self];
  [item setState: input < 0 ? NSOnState : NSOffState];
  for (i = 0; i < inputCount; i++)
    {
      item = [menu addItemWithTitle: [NSString stringWithUTF8String:
                                                 inputs[i].name]
                             action: @selector(chooseMicrophone:)
                      keyEquivalent: @""];
      [item setTag: i];
      [item setTarget: self];
      [item setState: i == input ? NSOnState : NSOffState];
    }
  [NSMenu popUpContextMenu: menu withEvent: event forView: v];
}

- (float) level
{
  return level;
}

- (BOOL) canRecord
{
  if (source == VDSourceScreen || source == VDSourceSelection)
    return VDScreenshotAppPath () != nil;
  if (source == VDSourceCamera)
    return camera != NULL && frame.width > 0;
  return audioIn != NULL;
}

- (double) seconds
{
  return elapsed;
}

- (long long) bytes
{
  return bytes;
}

- (NSBitmapImageRep *) picture
{
  return picture;
}

- (NSString *) message
{
  switch (source)
    {
    case VDSourceScreen:
    case VDSourceSelection:
      if (VDScreenshotAppPath () == nil)
        return @"Screen recordings are made by Screenshot,\nwhich isn't"
          @" installed.";
      return source == VDSourceScreen
        ? @"Screenshot records the whole screen.\nClick the record button"
        @" for its toolbar; the recording opens here when it stops."
        : @"Screenshot records part of the screen.\nClick the record button"
        @" for its toolbar, then drag over the part to record.";
    case VDSourceCamera:
      return cameraProblem != nil ? cameraProblem : @"Starting the camera…";
    case VDSourceSound:
      if (inputCount == 0)
        return @"No microphone is connected.";
      if (input < 0)
        return @"Choose a microphone to record sound.";
      if (audioIn == NULL)
        return @"The microphone can't be used.";
      return [self microphoneName];
    }
  return nil;
}

/* ---- the timer ---- */

- (void) fail: (NSString *)why
{
  char error[160];

  if (recorder != NULL)
    VDRecorderFinish (recorder, error, sizeof (error));
  recorder = NULL;
  NSRunAlertPanel (@"The recording stopped.", @"%@", @"OK", nil, nil, why);
}

- (void) tick: (NSTimer *)t
{
  char error[256];
  WCFrame f;
  int n, got;
  float now;

  if (camera != NULL)
    {
      memset (&f, 0, sizeof (f));
      n = WCCaptureRead (camera, &f, error, sizeof (error));
      if (n < 0)
        {
          [self closeCamera];
          ASSIGN (cameraProblem,
                  ([NSString stringWithFormat: @"The camera stopped.\n%s",
                             error]));
          if (recorder != NULL)
            [self toggleRecording: self];
          [view setNeedsDisplay: YES];
        }
      else if (n > 0)
        {
          NSBitmapImageRep *rep;
          unsigned char *data;
          int y;

          frame.width = f.width;
          frame.height = f.height;
          rep = [[NSBitmapImageRep alloc]
                  initWithBitmapDataPlanes: NULL
                                pixelsWide: f.width
                                pixelsHigh: f.height
                             bitsPerSample: 8
                           samplesPerPixel: 3
                                  hasAlpha: NO
                                  isPlanar: NO
                            colorSpaceName: NSDeviceRGBColorSpace
                               bytesPerRow: f.width * 3
                              bitsPerPixel: 24];
          data = [rep bitmapData];
          if (data != NULL)
            for (y = 0; y < f.height; y++)
              memcpy (data + (size_t) y * f.width * 3,
                      f.rgb + (size_t) y * f.stride, (size_t) f.width * 3);
          ASSIGN (picture, rep);
          RELEASE (rep);
          [view setNeedsDisplay: YES];
          if (recorder != NULL
              && VDRecorderAddPicture (recorder, f.rgb, f.width, f.height,
                                       f.stride, VDMonotonic () - started,
                                       error, sizeof (error)) != 0)
            [self fail: [NSString stringWithUTF8String: error]];
        }
    }

  if (audioIn != NULL)
    {
      if (VDAudioInFailed (audioIn, error, sizeof (error)))
        {
          [self closeMicrophone];
          if (recorder != NULL)
            [self toggleRecording: self];
        }
      else
        {
          now = VDAudioInLevel (audioIn);
          /* A meter that falls back slowly, in decibels from -60. */
          now = now > 0 ? (float) MAX (0, 1 + log10 (now) * 20 / 60) : 0;
          level = now > level ? now : MAX (0, level - 0.02f);
          while (recorder != NULL
                 && (got = VDAudioInRead (audioIn, sound, VDSoundChunk)) > 0)
            if (VDRecorderAddSound (recorder, sound, got, error,
                                    sizeof (error)) != 0)
              {
                [self fail: [NSString stringWithUTF8String: error]];
                break;
              }
        }
    }

  if (recorder != NULL)
    {
      elapsed = VDMonotonic () - started;
      bytes = VDRecorderBytes (recorder);
    }
  [bar setNeedsDisplay: YES];
}

/* ---- recording ---- */

- (NSString *) folder
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *folder = [[NSUserDefaults standardUserDefaults]
                       stringForKey: VDFolderKey];
  BOOL isDir = NO;

  if ([folder length] == 0)
    folder = [NSHomeDirectory () stringByAppendingPathComponent: @"Videos"];
  folder = [folder stringByExpandingTildeInPath];
  if (![fm fileExistsAtPath: folder isDirectory: &isDir])
    [fm createDirectoryAtPath: folder withIntermediateDirectories: YES
                   attributes: nil error: NULL];
  return folder;
}

- (NSString *) newPath
{
  NSDateFormatter *df = AUTORELEASE ([[NSDateFormatter alloc] init]);
  NSString *base, *candidate;
  int i;

  [df setDateFormat: @"yyyy-MM-dd 'at' HH.mm.ss"];
  base = [NSString stringWithFormat: @"%@ Recording %@",
                   source == VDSourceSound ? @"Sound" : @"Camera",
                   [df stringFromDate: [NSDate date]]];
  candidate = [[[self folder] stringByAppendingPathComponent: base]
                stringByAppendingPathExtension: @VDRecorderExtension];
  for (i = 2; [[NSFileManager defaultManager] fileExistsAtPath: candidate];
       i++)
    candidate = [[[self folder] stringByAppendingPathComponent:
                                  [NSString stringWithFormat: @"%@ %d", base,
                                            i]]
                  stringByAppendingPathExtension: @VDRecorderExtension];
  return candidate;
}

- (BOOL) isRecording
{
  return recorder != NULL;
}

- (void) toggleRecording: (id)sender
{
  char error[256];
  NSString *why = nil;

  if (recorder != NULL)
    {
      /* Stop: what the microphone still holds goes in, then it's
         finished and opens to play. */
      int got;

      if (audioIn != NULL)
        {
          while ((got = VDAudioInRead (audioIn, sound, VDSoundChunk)) > 0)
            if (VDRecorderAddSound (recorder, sound, got, error,
                                    sizeof (error)) != 0)
              break;
          VDAudioInSetCollecting (audioIn, 0);
        }
      if (VDRecorderFinish (recorder, error, sizeof (error)) != 0)
        {
          recorder = NULL;
          NSRunAlertPanel (@"The recording couldn't be saved.", @"%s", @"OK",
                           nil, nil, error);
          [bar setNeedsDisplay: YES];
          return;
        }
      recorder = NULL;
      [window close];
      return;
    }

  if (![self canRecord])
    {
      NSBeep ();
      return;
    }
  if (source == VDSourceScreen || source == VDSourceSelection)
    {
      if (!VDStartScreenRecording (source == VDSourceSelection, &why))
        {
          NSRunAlertPanel (@"The screen can't be recorded.", @"%@", @"OK",
                           nil, nil, why);
          return;
        }
      [window close];
      return;
    }

  ASSIGN (path, [self newPath]);
  recorder = VDRecorderStart ([path fileSystemRepresentation],
                              source == VDSourceCamera ? frame.width : 0,
                              source == VDSourceCamera ? frame.height : 0,
                              audioIn != NULL ? audioRate : 0,
                              audioIn != NULL ? audioChannels : 0,
                              error, sizeof (error));
  if (recorder == NULL)
    {
      DESTROY (path);
      NSRunAlertPanel (@"The recording couldn't be started.", @"%s", @"OK",
                       nil, nil, error);
      return;
    }
  if (audioIn != NULL)
    VDAudioInSetCollecting (audioIn, 1);
  started = VDMonotonic ();
  elapsed = 0;
  bytes = VDRecorderBytes (recorder);
  [window setTitle: source == VDSourceSound ? @"Sound Recording"
                  : @"Camera Recording"];
  [bar setNeedsDisplay: YES];
}

- (BOOL) windowShouldClose: (id)sender
{
  return YES;
}

- (void) windowWillClose: (NSNotification *)n
{
  NSDictionary *userInfo = nil;
  char error[256];

  [timer invalidate];
  timer = nil;
  if (recorder != NULL)
    {
      /* Closed while recording: it's kept, as if stopped. */
      if (VDRecorderFinish (recorder, error, sizeof (error)) != 0)
        DESTROY (path);
      recorder = NULL;
    }
  [self closeMicrophone];
  [self closeCamera];
  if (path != nil
      && [[NSFileManager defaultManager] fileExistsAtPath: path])
    userInfo = [NSDictionary dictionaryWithObject: path forKey: @"path"];
  [[NSNotificationCenter defaultCenter]
    postNotificationName: VDRecordingClosedNotification object: self
                  userInfo: userInfo];
}

- (BOOL) validateMenuItem: (id <NSMenuItem>)item
{
  if ([item action] == @selector(toggleRecording:))
    {
      [item setTitle: recorder != NULL ? @"Stop Recording"
                                       : @"Start Recording"];
      return recorder != NULL || [self canRecord];
    }
  return YES;
}

@end
