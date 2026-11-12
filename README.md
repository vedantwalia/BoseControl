# BoseControl

BoseControl is a macOS menu bar app for Bose QuietComfort Headphones (2023). It
shows the battery level and lets you switch between Quiet, Aware, Commute, and
Home noise-control modes over Bluetooth.

The app only connects when the headphones are already connected to your Mac; it
does not take the Bluetooth connection away from another device.

## Requirements

- macOS 13 or later
- Swift compiler and Apple frameworks from the Xcode Command Line Tools
- Bose headphones paired with and connected to your Mac

## Build and run

1. Find the headphones' Bluetooth address by building the probe tool and running
   `./bmapprobe list` (see [BMAP probe](#bmap-probe) below).
2. Set `deviceAddress` near the top of `BoseControl.swift` to that address,
   using hyphens between the address pairs.
3. Build the app:

   ```sh
   ./build.sh
   ```

4. Open it:

   ```sh
   open BoseControl.app
   ```

macOS may ask you to allow Bluetooth access. The build script uses ad-hoc code
signing and does not create a distributable installer.

## BMAP probe

`bmapprobe.swift` is a command-line utility for inspecting paired Bluetooth
devices and exploring the Bose BMAP RFCOMM service. Compile it with:

```sh
swiftc -O bmapprobe.swift -o bmapprobe -framework IOBluetooth
```

Examples:

```sh
./bmapprobe list
./bmapprobe services <address>
./bmapprobe probe <address> [channel]
./bmapprobe watch <address> <channel>
```

The probe also provides `send` and `sweep` commands. Use them only when you
understand the data being sent to the headphones.

## Notes

- The implementation targets Bose QuietComfort Headphones (2023); other Bose
  models may use different services or protocol behavior.
- `build.sh` recreates `BoseControl.app`. Generated app and probe binaries are
  excluded from version control.
- The Bluetooth protocol details were determined experimentally and may vary
  across firmware versions.
