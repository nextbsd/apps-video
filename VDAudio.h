/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * VDAudio: sound in and out through OSS, as a plain C interface.
 *
 * NextBSD has no audio daemon: a sound device is a pcmN in /dev/sndstat
 * (its /dev/dspN), or a userspace one such as a Bluetooth headset's
 * virtual_oss (/dev/dsp.btN). Playback goes to /dev/dsp, which follows
 * the system's default device (Sound.app sets it). Recording opens the
 * microphone the user picks.
 *
 * Every format here is signed 16-bit, interleaved.
 */

#ifndef _VD_AUDIO_H_
#define _VD_AUDIO_H_

#include <stddef.h>
#include <stdint.h>

#define VDAudioMaxInputs 16

/* The test tone input, listed only with the VideoTestSources default:
   a microphone for machines without one. */
#define VDAudioToneDevice "tone"

typedef struct
{
  char dsp[64];			/* "/dev/dsp0", "/dev/dsp.bt0", "tone" */
  char name[192];		/* "Realtek ALC257 (Analog)" */
  int isDefault;		/* /dev/dsp records from it */
} VDAudioInput;

/* The inputs that record, default first; with tone, the test tone
   too. Returns how many (at most max). */
int VDAudioListInputs (VDAudioInput *inputs, int max, int tone);

/* ---- output ---- */

typedef struct VDAudioOut VDAudioOut;

/* Opens /dev/dsp for 16-bit stereo, at 48 kHz if the device takes it;
   rate and channels say what it took. NULL, with why in error, when
   there's no sound device. */
VDAudioOut *VDAudioOutOpen (int *rate, int *channels, char *error,
                            size_t errorSize);

/* Writes frames (blocking while the device's buffer is full). 0, or -1
   if the device went away. */
int VDAudioOutWrite (VDAudioOut *out, const int16_t *samples, int frames);

/* Seconds of sound written but not yet heard. */
double VDAudioOutDelay (VDAudioOut *out);

/* Drops what is buffered (a seek). */
void VDAudioOutReset (VDAudioOut *out);

void VDAudioOutClose (VDAudioOut *out);

/* ---- input ---- */

typedef struct VDAudioIn VDAudioIn;

/* Starts recording from input on a thread of its own, 16-bit at 48 kHz
   where it can; rate and channels say what it got. NULL with why in
   error. Nothing is kept until VDAudioInSetCollecting; the level is
   always measured. */
VDAudioIn *VDAudioInOpen (const VDAudioInput *input, int *rate,
                          int *channels, char *error, size_t errorSize);

/* The loudest sample since the last call, 0.0-1.0. */
float VDAudioInLevel (VDAudioIn *in);

/* Keep what is recorded from now on (1), or drop it (0, the start). */
void VDAudioInSetCollecting (VDAudioIn *in, int on);

/* Takes up to maxFrames frames kept so far. Returns how many. */
int VDAudioInRead (VDAudioIn *in, int16_t *samples, int maxFrames);

/* Non-zero once the device has failed (unplugged); error says why. */
int VDAudioInFailed (VDAudioIn *in, char *error, size_t errorSize);

void VDAudioInClose (VDAudioIn *in);

#endif /* _VD_AUDIO_H_ */
