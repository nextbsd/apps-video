/*
 * Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "VDAudio.h"

#include <sys/ioctl.h>
#include <sys/soundcard.h>

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define VDWantRate 48000
#define VDInFrames 1024			/* a read */
#define VDInKeepSeconds 10		/* kept until VDAudioInRead */

/* ---- /dev/sndstat ---- */

/* /dev/sndstat, whole: a device, so its size is 0 and it's read to the
   end by hand. Returns a malloc'ed string or NULL. */
static char *
VDReadSndstat (void)
{
  char *text = NULL, *bigger;
  size_t length = 0, size = 0;
  ssize_t n;
  int fd = open ("/dev/sndstat", O_RDONLY | O_CLOEXEC);

  if (fd < 0)
    return NULL;
  for (;;)
    {
      if (size - length < 1024)
        {
          size = size ? size * 2 : 4096;
          if ((bigger = realloc (text, size)) == NULL)
            break;
          text = bigger;
        }
      if ((n = read (fd, text + length, size - length - 1)) <= 0)
        break;
      length += (size_t) n;
    }
  close (fd);
  if (text != NULL)
    text[length] = '\0';
  return text;
}

/* One sndstat line, "pcm0: <Realtek ALC257 (Analog)> (play/rec) default"
   or "dsp.bt0: <virtual_oss device> (play/rec)". 1 if it's a device that
   records. */
static int
VDParseLine (const char *line, int userspace, VDAudioInput *input)
{
  const char *colon = strchr (line, ':');
  const char *open = strchr (line, '<');
  const char *close = strrchr (line, '>');
  const char *group;
  char ident[32];
  size_t n;
  int unit, p = 0, r = 0, record;

  if (colon == NULL || open == NULL || close == NULL || close < open
      || colon > open || colon == line)
    return 0;
  n = (size_t) (colon - line);
  if (n >= sizeof (ident))
    return 0;
  memcpy (ident, line, n);
  ident[n] = '\0';
  group = strchr (close, '(');
  if (group == NULL)
    return 0;
  record = strstr (group, "rec") != NULL;
  if (!record && sscanf (group, "(%dp:%*dv/%dr", &p, &r) == 2)
    record = r > 0;
  if (!record)
    return 0;

  memset (input, 0, sizeof (*input));
  n = (size_t) (close - open - 1);
  if (n >= sizeof (input->name))
    n = sizeof (input->name) - 1;
  memcpy (input->name, open + 1, n);
  input->name[n] = '\0';
  if (!userspace)
    {
      if (sscanf (ident, "pcm%d", &unit) != 1)
        return 0;
      snprintf (input->dsp, sizeof (input->dsp), "/dev/dsp%d", unit);
      input->isDefault = strstr (close, "default") != NULL;
    }
  else
    {
      /* Every virtual_oss says "virtual_oss device": add the node. */
      n = strlen (input->name);
      snprintf (input->name + n, sizeof (input->name) - n, " (%s)", ident);
      snprintf (input->dsp, sizeof (input->dsp), "/dev/%s", ident);
      input->isDefault = strcmp (ident, "dsp") == 0;
    }
  return 1;
}

int
VDAudioListInputs (VDAudioInput *inputs, int max, int tone)
{
  char *text = VDReadSndstat (), *line, *next;
  VDAudioInput input, swap;
  int count = 0, userspace = 0, i;

  for (line = text; line != NULL && *line != '\0'; line = next)
    {
      next = strchr (line, '\n');
      if (next != NULL)
        *next++ = '\0';
      if (strncmp (line, "Installed devices from userspace", 32) == 0)
        {
          userspace = 1;
          continue;
        }
      if (count < max && VDParseLine (line, userspace, &input))
        inputs[count++] = input;
    }
  free (text);

  /* The default first. */
  for (i = 1; i < count; i++)
    if (inputs[i].isDefault && !inputs[0].isDefault)
      {
        swap = inputs[0];
        inputs[0] = inputs[i];
        inputs[i] = swap;
      }

  if (tone && count < max)
    {
      memset (&input, 0, sizeof (input));
      snprintf (input.dsp, sizeof (input.dsp), "%s", VDAudioToneDevice);
      snprintf (input.name, sizeof (input.name), "Test Tone");
      inputs[count++] = input;
    }
  return count;
}

/* Sets 16-bit, channels and rate on an open dsp. 0 or -1. */
static int
VDSetFormat (int fd, int *rate, int *channels, char *error,
             size_t errorSize)
{
  int format = AFMT_S16_LE;

  if (ioctl (fd, SNDCTL_DSP_SETFMT, &format) < 0 || format != AFMT_S16_LE)
    {
      snprintf (error, errorSize, "The sound device doesn't take 16-bit"
                " sound");
      return -1;
    }
  if (ioctl (fd, SNDCTL_DSP_CHANNELS, channels) < 0 || *channels < 1
      || *channels > 2)
    {
      snprintf (error, errorSize, "The sound device doesn't take mono or"
                " stereo sound");
      return -1;
    }
  if (ioctl (fd, SNDCTL_DSP_SPEED, rate) < 0 || *rate < 8000)
    {
      snprintf (error, errorSize, "The sound device refused the rate");
      return -1;
    }
  return 0;
}

/* ---- output ---- */

struct VDAudioOut
{
  int fd;
  int rate;
  int channels;
};

VDAudioOut *
VDAudioOutOpen (int *rate, int *channels, char *error, size_t errorSize)
{
  VDAudioOut *out;
  int fd, fragment;

  fd = open ("/dev/dsp", O_WRONLY | O_CLOEXEC);
  if (fd < 0)
    {
      if (errno == ENOENT || errno == ENXIO || errno == ENODEV)
        snprintf (error, errorSize, "No sound output");
      else
        snprintf (error, errorSize, "Can't play sound: %s",
                  strerror (errno));
      return NULL;
    }
  /* About 85 ms of buffer: 8 fragments of 2 KB. Pausing lets it drain,
     so it's kept short. */
  fragment = (8 << 16) | 11;
  ioctl (fd, SNDCTL_DSP_SETFRAGMENT, &fragment);
  *rate = VDWantRate;
  *channels = 2;
  if (VDSetFormat (fd, rate, channels, error, errorSize) != 0)
    {
      close (fd);
      return NULL;
    }
  out = calloc (1, sizeof (*out));
  if (out == NULL)
    {
      close (fd);
      snprintf (error, errorSize, "Out of memory");
      return NULL;
    }
  out->fd = fd;
  out->rate = *rate;
  out->channels = *channels;
  return out;
}

int
VDAudioOutWrite (VDAudioOut *out, const int16_t *samples, int frames)
{
  const char *p = (const char *) samples;
  size_t left = (size_t) frames * (size_t) out->channels * 2;
  ssize_t n;

  while (left > 0)
    {
      n = write (out->fd, p, left);
      if (n < 0)
        {
          if (errno == EINTR)
            continue;
          return -1;
        }
      p += n;
      left -= (size_t) n;
    }
  return 0;
}

double
VDAudioOutDelay (VDAudioOut *out)
{
  int bytes = 0;

  if (ioctl (out->fd, SNDCTL_DSP_GETODELAY, &bytes) < 0 || bytes < 0)
    return 0;
  return (double) bytes / (double) (out->rate * out->channels * 2);
}

void
VDAudioOutReset (VDAudioOut *out)
{
  ioctl (out->fd, SNDCTL_DSP_HALT_OUTPUT, NULL);
}

void
VDAudioOutClose (VDAudioOut *out)
{
  if (out == NULL)
    return;
  close (out->fd);
  free (out);
}

/* ---- input ---- */

struct VDAudioIn
{
  int fd;			/* -1: the test tone */
  int rate;
  int channels;
  pthread_t thread;
  pthread_mutex_t lock;
  int quit;
  int failed;
  char error[128];
  float peak;
  int collecting;
  int16_t *keep;		/* a ring of what's kept */
  int keepFrames;		/* its size, in frames */
  int keepRead;
  int keepCount;
};

static void
VDInKeep (VDAudioIn *in, const int16_t *samples, int frames)
{
  int i, at, peak = 0, v;

  for (i = 0; i < frames * in->channels; i++)
    {
      v = samples[i] < 0 ? -samples[i] : samples[i];
      if (v > peak)
        peak = v;
    }
  pthread_mutex_lock (&in->lock);
  if (peak / 32768.0f > in->peak)
    in->peak = peak / 32768.0f;
  if (in->collecting)
    for (i = 0; i < frames; i++)
      {
        if (in->keepCount == in->keepFrames)
          break;		/* nobody's reading: drop the newest */
        at = (in->keepRead + in->keepCount) % in->keepFrames;
        memcpy (in->keep + at * in->channels,
                samples + i * in->channels,
                sizeof (int16_t) * (size_t) in->channels);
        in->keepCount++;
      }
  pthread_mutex_unlock (&in->lock);
}

/* The test tone: a 440 Hz note whose loudness comes and goes, so the
   meter moves, at the real rate. */
static void
VDInTone (VDAudioIn *in, int16_t *buffer, long long *done)
{
  struct timespec start, now;
  long long due;
  int i, c;
  double t, amp;

  clock_gettime (CLOCK_MONOTONIC, &start);
  while (!in->quit)
    {
      for (i = 0; i < VDInFrames; i++)
        {
          t = (double) (*done + i) / in->rate;
          amp = 0.15 + 0.35 * (0.5 + 0.5 * sin (2 * M_PI * 0.5 * t));
          for (c = 0; c < in->channels; c++)
            buffer[i * in->channels + c] =
              (int16_t) (32767 * amp * sin (2 * M_PI * 440 * t));
        }
      *done += VDInFrames;
      VDInKeep (in, buffer, VDInFrames);
      /* Wait until that much time has gone by. */
      for (;;)
        {
          clock_gettime (CLOCK_MONOTONIC, &now);
          due = (long long) ((now.tv_sec - start.tv_sec) * 1000000LL
                             + (now.tv_nsec - start.tv_nsec) / 1000);
          if (due * in->rate / 1000000LL >= *done || in->quit)
            break;
          usleep (5000);
        }
    }
}

static void *
VDInThread (void *arg)
{
  VDAudioIn *in = arg;
  int16_t buffer[VDInFrames * 2];
  long long done = 0;
  size_t want = sizeof (int16_t) * VDInFrames * (size_t) in->channels;
  ssize_t n;

  if (in->fd < 0)
    {
      VDInTone (in, buffer, &done);
      return NULL;
    }
  while (!in->quit)
    {
      struct pollfd p = { in->fd, POLLIN, 0 };

      /* Non-blocking, so closing never waits on a device that has
         stopped sending. */
      if (poll (&p, 1, 100) == 0)
        continue;
      n = read (in->fd, buffer, want);
      if (n < 0 && (errno == EINTR || errno == EAGAIN))
        continue;
      if (n <= 0)
        {
          pthread_mutex_lock (&in->lock);
          in->failed = 1;
          snprintf (in->error, sizeof (in->error), "The microphone %s",
                    n == 0 ? "stopped" : strerror (errno));
          pthread_mutex_unlock (&in->lock);
          break;
        }
      VDInKeep (in, buffer,
                (int) (n / (ssize_t) (sizeof (int16_t) * in->channels)));
    }
  return NULL;
}

VDAudioIn *
VDAudioInOpen (const VDAudioInput *input, int *rate, int *channels,
               char *error, size_t errorSize)
{
  VDAudioIn *in;
  int fd = -1, trigger;

  *rate = VDWantRate;
  *channels = 2;
  if (strcmp (input->dsp, VDAudioToneDevice) != 0)
    {
      fd = open (input->dsp, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
      if (fd < 0)
        {
          snprintf (error, errorSize, "Can't open %s: %s", input->name,
                    strerror (errno));
          return NULL;
        }
      if (VDSetFormat (fd, rate, channels, error, errorSize) != 0)
        {
          close (fd);
          return NULL;
        }
      trigger = PCM_ENABLE_INPUT;
      ioctl (fd, SNDCTL_DSP_SETTRIGGER, &trigger);
    }
  in = calloc (1, sizeof (*in));
  if (in == NULL)
    {
      if (fd >= 0)
        close (fd);
      snprintf (error, errorSize, "Out of memory");
      return NULL;
    }
  in->fd = fd;
  in->rate = *rate;
  in->channels = *channels;
  in->keepFrames = in->rate * VDInKeepSeconds;
  in->keep = malloc (sizeof (int16_t) * (size_t) in->keepFrames
                     * (size_t) in->channels);
  pthread_mutex_init (&in->lock, NULL);
  if (in->keep == NULL
      || pthread_create (&in->thread, NULL, VDInThread, in) != 0)
    {
      snprintf (error, errorSize, "Can't start recording");
      if (fd >= 0)
        close (fd);
      pthread_mutex_destroy (&in->lock);
      free (in->keep);
      free (in);
      return NULL;
    }
  return in;
}

float
VDAudioInLevel (VDAudioIn *in)
{
  float peak;

  pthread_mutex_lock (&in->lock);
  peak = in->peak;
  in->peak = 0;
  pthread_mutex_unlock (&in->lock);
  return peak;
}

void
VDAudioInSetCollecting (VDAudioIn *in, int on)
{
  pthread_mutex_lock (&in->lock);
  in->collecting = on;
  in->keepCount = 0;
  pthread_mutex_unlock (&in->lock);
}

int
VDAudioInRead (VDAudioIn *in, int16_t *samples, int maxFrames)
{
  int n, i;

  pthread_mutex_lock (&in->lock);
  n = in->keepCount < maxFrames ? in->keepCount : maxFrames;
  for (i = 0; i < n; i++)
    {
      memcpy (samples + i * in->channels,
              in->keep + in->keepRead * in->channels,
              sizeof (int16_t) * (size_t) in->channels);
      in->keepRead = (in->keepRead + 1) % in->keepFrames;
    }
  in->keepCount -= n;
  pthread_mutex_unlock (&in->lock);
  return n;
}

int
VDAudioInFailed (VDAudioIn *in, char *error, size_t errorSize)
{
  int failed;

  pthread_mutex_lock (&in->lock);
  failed = in->failed;
  if (failed)
    snprintf (error, errorSize, "%s", in->error);
  pthread_mutex_unlock (&in->lock);
  return failed;
}

void
VDAudioInClose (VDAudioIn *in)
{
  if (in == NULL)
    return;
  in->quit = 1;
  pthread_join (in->thread, NULL);
  if (in->fd >= 0)
    close (in->fd);
  pthread_mutex_destroy (&in->lock);
  free (in->keep);
  free (in);
}
