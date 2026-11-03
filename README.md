# SoundRouter: Virtual Audio Router for macOS

![Platform](https://img.shields.io/badge/platform-macOS%2014.2%2B-blue)
![Chip](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange)
![Educational](https://img.shields.io/badge/purpose-educational-green)

**SoundRouter** is a free, open-source **virtual audio device and audio routing app for macOS**. Create virtual
microphones and speakers, capture audio from any app or the whole system, and route it wherever you need with simple drag-and-drop virtual cables. Built with Swift, SwiftUI and CoreAudio as an educational project.

## What can you do with it?

- **Create virtual audio devices** (up to 8, with 2 to 16 channels each) that show up as microphones in other apps.
- **Capture app audio or system audio** and send it to Zoom, Google Meet, Discord, OBS Studio, or a DAW.
- **Mix several sources** (apps, system sound, microphones) into one virtual device.
- **Route audio with virtual cables**: connect any source channel to any output channel.
- **Monitor** the result on your headphones or speakers while you stream, record, or present.

## Common use cases

- Share a video's sound in a **Zoom or Google Meet call** without echo.
- Stream or record **game, music, and microphone audio separately** in OBS.
- Record **system audio on Mac** into a DAW or screen recorder.
- Learn how **CoreAudio AudioServerPlugIn** drivers and **process taps** work on modern macOS.

## Requirements

- macOS 14.2 or later
- Apple Silicon Mac (M1, M2, M3, M4 and newer)
- Xcode Command Line Tools (only to build from source)

## Quick start

1. Build the app (see below) and open `build/SoundRouter.app`.
2. Click **Install** on the first-run banner and enter your admin password once.
3. Create a device with **File → New Virtual Device** (⌘N).
4. Press **+** under Sources to add an app, system audio, or a microphone.
5. Drag a cable from a source dot to an output dot.
6. Select the new SoundRouter device as the microphone in your other app.

## Build from source

    git clone https://github.com/mharits-s/SoundRouter.git
    cd SoundRouter
    ./scripts/build.sh

The app is created at `build/SoundRouter.app`.

## Permissions

- **Microphone**: only needed if you use a microphone as a source.
- **System Audio Recording**: needed to capture audio from apps or the whole system.

## Uninstall

Delete `/Library/Audio/Plug-Ins/HAL/SoundRouter.driver` and `/Library/Application Support/SoundRouter`, then run
`sudo killall coreaudiod`.

## Project structure

    app/        SwiftUI macOS app
    driver/     Virtual audio driver (CoreAudio AudioServerPlugIn, C)
    scripts/    Build and install scripts
    tests/      Automated tests
    docs/       Images and documentation

## Keywords

macOS virtual audio device, virtual microphone for Mac, macOS audio router, route app audio on Mac, capture system
audio on macOS, CoreAudio, AudioServerPlugIn, free audio routing software for Mac, SwiftUI, Zoom, OBS, Discord.

## Disclaimer

This project is for learning and experimentation. It is not a commercial product and comes with no warranty.
