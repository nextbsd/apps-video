# Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# Video.app: plays video and sound, and records the camera and sound, as
# QuickTime Player on a Mac. Installed in the SYSTEM domain, as
# /System/Applications/Video.app.
#
# Playing and recording use NextBSD's ffmpeg libraries (in
# NextBSD-gnustep-support, and in the GNUstep SDK): libavformat and
# libavcodec decode, libswscale and libswresample convert, and the
# MPEG-4 and AAC encoders and the mov muxer write recordings. Sound goes
# in and out through OSS. Cameras come through WCCapture, a copy of
# apps-settings' Webcam's (V4L2, with libjpeg for MJPEG cameras); keep
# the WC* files in step with Webcam's.

ifeq ($(GNUSTEP_MAKEFILES),)
 GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES)
endif
include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = Video
Video_OBJC_FILES = main.m VDController.m VDPlayer.m VDRecording.m \
	VDScreenRecording.m VDStyle.m
Video_C_FILES = VDMedia.c VDAudio.c VDRecorder.c \
	WCCapture.c WCCaptureV4L2.c WCCaptureTestPattern.c WCImage.c
Video_HEADER_FILES = VDController.h VDPlayer.h VDRecording.h \
	VDScreenRecording.h VDStyle.h VDMedia.h VDAudio.h VDRecorder.h \
	WCCapture.h WCV4L2.h WCImage.h
Video_RESOURCE_FILES = Resources/Video.png
Video_APPLICATION_ICON = Video.png
Video_OBJCFLAGS = -Wall -Wextra -Wno-unused-parameter
Video_CFLAGS = -Wall -Wextra -Wno-unused-parameter
Video_GUI_LIBS += -lavformat -lavcodec -lswscale -lswresample -lavutil \
	-lpng16 -ljpeg -lpthread -lm

include $(GNUSTEP_MAKEFILES)/application.make
