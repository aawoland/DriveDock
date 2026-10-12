# DriveDock

DriveDock is a native, menu bar only macOS app for viewing and safely ejecting external drives.

## Build

Requires macOS 13 or later and Swift 5.10 or later. On an Apple silicon Mac, run:

```sh
./build-app.sh
open .build/DriveDock.app
```

The app detects external physical disks through Disk Arbitration, lists their mounted volumes, and ejects the physical disk so its volumes are unmounted together. It does not eject drives automatically. If macOS reports that a drive is busy, close files or apps using it and try again.
