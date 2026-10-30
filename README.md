# TrainKit

TrainKit is a free, native iOS and Android controller for SBrick and SBrick Plus motor hubs. It connects directly over Bluetooth Low Energy and does not require an account or network connection.

Native iOS and Android projects are included. The Android Studio project is in `Android/` and uses Kotlin, Jetpack Compose, and the Android Bluetooth APIs.

## Features

- Scans for SBrick devices, including older firmware that does not advertise the control service
- Gives every SBrick a stable ID, custom locomotive name, and independent port profile
- Saves reusable named locomotive profiles with an optional photo
- Saves consists with one lead locomotive and ordered appended locomotives
- Runs every consist motor from one throttle with per-locomotive directional-light switches
- Controls all four physical ports with the correct A/B/C/D channel mapping
- Configures each port as a slider, dial, toggle, or momentary push buttons
- Supports simultaneous forward and reverse motor output
- Assigns each port as a motor, forward light, reverse light, or unused output
- Assigns multiple ports to forward or reverse directional lights
- Sets independent positive or negative polarity for each forward and reverse light output
- Includes hold-to-run forward/reverse port testing for every SBrick
- Persists custom names, port functions, direction reversal, and output limits
- Reads battery voltage from SBrick notifications
- Provides an all-port emergency brake
- Configures the SBrick watchdog, sends a safe control heartbeat, and automatically reconnects at zero output
- Offers a per-locomotive connection-loss policy: emergency stop or keep the last output until reconnection
- Keeps connected SBricks available for Bluetooth control while the app is in the background
- Restores active Core Bluetooth connections when iOS relaunches the app in the background
- Contains no ads, subscriptions, purchases, analytics, or third-party dependencies

## Requirements

- iOS 18.0 or later
- Xcode 16 or later
- An SBrick or SBrick Plus running firmware with the public remote-control service

SBrick Light is discoverable but its 24-channel lighting protocol is not a motor-control protocol and is not presented as a compatible motor hub.

## Build

Open `TrainKit.xcodeproj` or run:

```sh
xcodebuild -project TrainKit.xcodeproj -scheme TrainKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build test
```

Bluetooth device control must be tested on a physical iPhone or iPad.

For Android, open the `Android` directory in Android Studio and run the `app` configuration. Bluetooth control must be tested on a physical Android device.
