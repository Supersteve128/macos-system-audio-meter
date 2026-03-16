# System Audio Meter for macOS

Small macOS utility built with SwiftUI, Core Audio, and Accelerate to measure live system audio levels in dBFS.

This app listens to a routed system-audio device, computes real-time RMS and peak values, smooths the meter response, and renders a minimal desktop UI for monitoring output volume.

## Features

- Real-time stereo audio capture through Core Audio AUHAL
- RMS and peak metering in dBFS
- Peak-hold decay plus attack/release smoothing
- SwiftUI interface with start, stop, and reset controls
- No third-party dependencies

## Technical Highlights

- `AudioUnit` HAL input callback for low-level device capture
- `Accelerate/vDSP` for efficient peak and RMS calculations
- Main-thread UI throttling to keep rendering stable
- Sandboxed macOS app with audio capture permission

## Stack

- Swift
- SwiftUI
- Core Audio / AudioToolbox
- Accelerate

## Requirements

- macOS 15.2+
- Xcode 16+
- A loopback audio device such as `BlackHole 2ch`

## Running Locally

1. Install and configure a loopback device such as `BlackHole 2ch`.
2. Route system audio through that device.
3. Open `audiodb.xcodeproj` in Xcode.
4. Build and run the `audiodb` scheme.
5. Grant audio capture permission if prompted, then click `Start`.

## Notes

- The meter currently looks for a device named `BlackHole 2ch` by default.
- If your loopback device uses a different name, update `start(deviceName:)` in `audiodb/SystemAudioMeter.swift`.

## Why It’s Resume-Worthy

This project demonstrates desktop app development, low-level Core Audio integration, real-time signal metering, and performance-aware UI updates in Swift.
