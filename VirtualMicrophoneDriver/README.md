# Baton Remote Microphone

This Audio Server plug-in exposes a CoreAudio input named `Baton Remote Microphone`.
Baton feeds decoded Siri Remote audio into the device's output stream; recording apps
read the same samples from its input stream. The driver uses a 16,384-frame, sample-time
addressed ring buffer and never performs file or network I/O on CoreAudio's real-time thread.

The driver is derived from Apple's permissively licensed “Creating an Audio Server Driver
Plug-in” sample. See `LICENSE-APPLE-SAMPLE.txt`. BlackHole was used only as an architectural
reference; no BlackHole GPL source is included.

Build with `./build_driver.sh`. Installing or removing a HAL driver requires administrator
approval and restarts `coreaudiod`, so the app must always present this as an explicit user action.
