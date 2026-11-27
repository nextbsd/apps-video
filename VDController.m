/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "VDController.h"
#import "VDPlayer.h"
#import "VDRecording.h"
#import "VDStyle.h"
#import <GNUstepBase/GNUstep.h>

#define VDRecentKey @"VideoRecentFiles"
#define VDRecentMost 10

/* What Video opens: the same list as NSTypes in VideoInfo.plist. */
static NSArray *
VDOpenableTypes (void)
{
  return [NSArray arrayWithObjects:
                    @"mov", @"mp4", @"m4v", @"mkv", @"webm", @"avi", @"mpg",
                  @"mpeg", @"m1v", @"m2v", @"vob", @"ogv", @"ts", @"mts",
                  @"m2ts", @"3gp", @"3g2", @"mj2",
                  @"mp3", @"m4a", @"aac", @"flac", @"ogg", @"oga", @"opus",
                  @"wav", @"aif", @"aiff", @"caf", @"au", @"ac3", @"mka",
                  nil];
}

static id<NSMenuItem>
VDAddItem (NSMenu *menu, NSString *title, SEL action, NSString *key,
           unsigned int modifiers)
{
  id<NSMenuItem> item = [menu addItemWithTitle: title action: action
                                 keyEquivalent: key];

  if (modifiers != 0)
    [item setKeyEquivalentModifierMask: modifiers];
  return item;
}

static NSMenu *
VDSubmenu (NSMenu *menu, NSString *title)
{
  NSMenu *sub = AUTORELEASE ([[NSMenu alloc] initWithTitle: title]);
  id<NSMenuItem> item = [menu addItemWithTitle: title action: NULL
                                 keyEquivalent: @""];

  [menu setSubmenu: sub forItem: item];
  return sub;
}

@implementation VDController

- (id) init
{
  if ((self = [super init]) != nil)
    {
      players = [[NSMutableArray alloc] init];
      recordings = [[NSMutableArray alloc] init];
    }
  return self;
}

- (void) dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver: self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver: self];
  RELEASE (players);
  RELEASE (recordings);
  RELEASE (recentMenu);
  [super dealloc];
}

/* ---- menus ---- */

- (void) rebuildRecent
{
  NSArray *recent = [[NSUserDefaults standardUserDefaults]
                      arrayForKey: VDRecentKey];
  id<NSMenuItem> item;
  NSUInteger i;

  while ([recentMenu numberOfItems] > 0)
    [recentMenu removeItemAtIndex: 0];
  for (i = 0; i < [recent count]; i++)
    {
      NSString *p = [recent objectAtIndex: i];

      item = [recentMenu addItemWithTitle: [p lastPathComponent]
                                   action: @selector(openRecent:)
                            keyEquivalent: @""];
      [item setRepresentedObject: p];
      [item setTarget: self];
    }
  if ([recent count] > 0)
    [recentMenu addItem: [NSMenuItem separatorItem]];
  item = [recentMenu addItemWithTitle: @"Clear Menu"
                               action: @selector(clearRecent:)
                        keyEquivalent: @""];
  [item setTarget: self];
}

- (void) noteRecent: (NSString *)path
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  NSMutableArray *recent = [NSMutableArray arrayWithArray:
                                             [defs arrayForKey: VDRecentKey]];

  [recent removeObject: path];
  [recent insertObject: path atIndex: 0];
  while ([recent count] > VDRecentMost)
    [recent removeLastObject];
  [defs setObject: recent forKey: VDRecentKey];
  [self rebuildRecent];
}

- (void) makeMenu
{
  NSMenu *menu = AUTORELEASE ([[NSMenu alloc] initWithTitle: @"Video"]);
  NSMenu *file, *edit, *view, *speed, *windows, *help;
  id<NSMenuItem> item;
  unsigned int cmd = NSCommandKeyMask;
  int speeds[] = { 50, 100, 125, 150, 200 };
  unsigned i;

  VDAddItem (menu, @"About Video", @selector(orderFrontStandardInfoPanel:),
             @"", 0);

  file = VDSubmenu (menu, @"File");
  VDAddItem (file, @"New Screen Recording", @selector(newScreenRecording:),
             @"n", cmd | NSAlternateKeyMask);
  VDAddItem (file, @"New Camera Recording", @selector(newCameraRecording:),
             @"n", cmd | NSShiftKeyMask);
  VDAddItem (file, @"New Sound Recording", @selector(newSoundRecording:),
             @"n", cmd | NSAlternateKeyMask | NSControlKeyMask);
  [file addItem: [NSMenuItem separatorItem]];
  VDAddItem (file, @"Open…", @selector(openDocument:), @"o", 0);
  recentMenu = RETAIN (VDSubmenu (file, @"Open Recent"));
  [self rebuildRecent];
  [file addItem: [NSMenuItem separatorItem]];
  VDAddItem (file, @"Close", @selector(performClose:), @"w", 0);
  VDAddItem (file, @"Save…", @selector(saveCopy:), @"s", 0);
  VDAddItem (file, @"Get Info", @selector(showInfo:), @"i", 0);
  [file addItem: [NSMenuItem separatorItem]];
  VDAddItem (file, @"Start Recording", @selector(toggleRecording:), @"r", 0);

  edit = VDSubmenu (menu, @"Edit");
  VDAddItem (edit, @"Cut", @selector(cut:), @"x", 0);
  VDAddItem (edit, @"Copy", @selector(copy:), @"c", 0);
  VDAddItem (edit, @"Paste", @selector(paste:), @"v", 0);
  VDAddItem (edit, @"Select All", @selector(selectAll:), @"a", 0);

  view = VDSubmenu (menu, @"View");
  VDAddItem (view, @"Play", @selector(togglePlay:), @"", 0);
  VDAddItem (view, @"Skip Forward", @selector(skipForward:), @"", 0);
  VDAddItem (view, @"Skip Back", @selector(skipBackward:), @"", 0);
  [view addItem: [NSMenuItem separatorItem]];
  VDAddItem (view, @"Volume Up", @selector(volumeUp:), @"", 0);
  VDAddItem (view, @"Volume Down", @selector(volumeDown:), @"", 0);
  VDAddItem (view, @"Mute", @selector(toggleMute:), @"", 0);
  speed = VDSubmenu (view, @"Speed");
  for (i = 0; i < sizeof (speeds) / sizeof (speeds[0]); i++)
    {
      item = VDAddItem (speed, speeds[i] % 100 == 0
                        ? [NSString stringWithFormat: @"%d×",
                                    speeds[i] / 100]
                        : [NSString stringWithFormat: @"%g×",
                                    speeds[i] / 100.0],
                        @selector(setSpeedFromMenu:), @"", 0);
      [item setTag: speeds[i]];
    }
  [view addItem: [NSMenuItem separatorItem]];
  VDAddItem (view, @"Enter Full Screen", @selector(toggleFullScreen:),
             @"f", 0);

  windows = VDSubmenu (menu, @"Window");
  VDAddItem (windows, @"Minimize", @selector(performMiniaturize:), @"m", 0);
  VDAddItem (windows, @"Close", @selector(performClose:), @"", 0);
  [NSApp setWindowsMenu: windows];

  help = VDSubmenu (menu, @"Help");
  VDAddItem (help, @"Video Help", @selector(showHelp:), @"?", 0);

  VDAddItem (menu, @"Hide", @selector(hide:), @"h", 0);
  VDAddItem (menu, @"Quit", @selector(terminate:), @"q", 0);
  [NSApp setMainMenu: menu];
}

- (BOOL) validateMenuItem: (id <NSMenuItem>)item
{
  return YES;
}

/* ---- opening ---- */

- (BOOL) openPath: (NSString *)path
{
  VDPlayer *player;
  NSUInteger i;

  path = [path stringByStandardizingPath];
  for (i = 0; i < [players count]; i++)
    {
      player = [players objectAtIndex: i];
      if ([[player path] isEqual: path])
        {
          [[player window] makeKeyAndOrderFront: nil];
          return YES;
        }
    }
  player = [VDPlayer playerWithPath: path];
  if (player == nil)
    return NO;
  [players addObject: player];
  [player show];
  [self noteRecent: path];
  return YES;
}

- (void) openDocument: (id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  NSArray *files;
  NSUInteger i;

  [panel setAllowsMultipleSelection: YES];
  [panel setTitle: @"Open"];
  if ([panel runModalForDirectory: nil file: nil
                            types: VDOpenableTypes ()] != NSOKButton)
    return;
  files = [panel filenames];
  for (i = 0; i < [files count]; i++)
    [self openPath: [files objectAtIndex: i]];
}

- (void) openRecent: (id)sender
{
  NSString *path = [sender representedObject];

  if (path != nil)
    [self openPath: path];
}

- (void) clearRecent: (id)sender
{
  [[NSUserDefaults standardUserDefaults] removeObjectForKey: VDRecentKey];
  [self rebuildRecent];
}

- (BOOL) application: (NSApplication *)app openFile: (NSString *)file
{
  return [self openPath: file];
}

- (void) application: (NSApplication *)app openFiles: (NSArray *)files
{
  NSUInteger i;

  for (i = 0; i < [files count]; i++)
    [self openPath: [files objectAtIndex: i]];
}

/* ---- recording ---- */

- (void) newRecording: (VDSource)source
{
  NSArray *open = [NSArray arrayWithArray: recordings];
  VDRecording *recording;
  NSUInteger i;

  /* One New Recording window at a time, as QuickTime has. */
  for (i = 0; i < [open count]; i++)
    {
      recording = [open objectAtIndex: i];
      if (![recording isRecording])
        [[recording window] close];
    }
  for (i = 0; i < [recordings count]; i++)
    if ([[recordings objectAtIndex: i] isRecording])
      {
        [[[recordings objectAtIndex: i] window] makeKeyAndOrderFront: nil];
        return;
      }
  recording = [VDRecording recordingWithSource: source];
  [recordings addObject: recording];
  [recording show];
}

- (void) newScreenRecording: (id)sender
{
  [self newRecording: VDSourceScreen];
}

- (void) newCameraRecording: (id)sender
{
  [self newRecording: VDSourceCamera];
}

- (void) newSoundRecording: (id)sender
{
  [self newRecording: VDSourceSound];
}

/* ---- windows closing ---- */

- (void) playerClosed: (NSNotification *)n
{
  id player = [n object];

  /* It's in the middle of closing: let it finish first. */
  AUTORELEASE (RETAIN (player));
  [players removeObjectIdenticalTo: player];
}

- (void) recordingClosed: (NSNotification *)n
{
  id recording = [n object];
  NSString *path = [[n userInfo] objectForKey: @"path"];

  AUTORELEASE (RETAIN (recording));
  [recordings removeObjectIdenticalTo: recording];
  if (path != nil)
    [self performSelector: @selector(openPath:) withObject: path
               afterDelay: 0];
}

/* ---- appearance ---- */

- (void) settingsChanged: (NSNotification *)n
{
  NSString *key = [[n userInfo] objectForKey: @"key"];

  if (key != nil && ![key isEqual: @"NBAppearance"])
    return;
  [VDStyle reload];
  [[NSNotificationCenter defaultCenter]
    postNotificationName: VDStyleChangedNotification object: nil];
}

/* ---- the application ---- */

- (void) applicationWillFinishLaunching: (NSNotification *)n
{
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

  [self makeMenu];
  [nc addObserver: self selector: @selector(playerClosed:)
             name: VDPlayerClosedNotification object: nil];
  [nc addObserver: self selector: @selector(recordingClosed:)
             name: VDRecordingClosedNotification object: nil];
  [[NSDistributedNotificationCenter defaultCenter]
    addObserver: self selector: @selector(settingsChanged:)
           name: @"org.nextbsd.DesktopSettingsChanged" object: nil];
}

/* Files named on the command line: "Video movie.mov". */
- (void) openArguments
{
  NSArray *args = [[NSProcessInfo processInfo] arguments];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSUInteger i;
  NSString *a;

  for (i = 1; i < [args count]; i++)
    {
      a = [args objectAtIndex: i];
      if ([a hasPrefix: @"-"])
        {
          i++;			/* -Default value */
          continue;
        }
      if ([fm fileExistsAtPath: a])
        [self openPath: a];
    }
}

- (void) offerOpen
{
  /* Started on its own, with nothing to play: ask what to open, as
     QuickTime does. */
  if ([players count] == 0 && [recordings count] == 0)
    [self openDocument: nil];
}

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];

  launched = YES;
  [self openArguments];
  if (![defs boolForKey: @"VideoNoOpenPanel"])
    [self performSelector: @selector(offerOpen) withObject: nil
               afterDelay: 0.5];
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)app
{
  return NO;
}

- (void) applicationWillTerminate: (NSNotification *)n
{
  NSArray *open = [NSArray arrayWithArray: recordings];
  NSUInteger i;

  /* A recording under way is kept. */
  for (i = 0; i < [open count]; i++)
    [[[open objectAtIndex: i] window] close];
}

@end
