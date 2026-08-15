# mic-spike

`mic-spike` is a standalone research tool for verifying the Siri Remote A1962 microphone path. It extracts the remote's Opus frames from a PacketLogger HCI capture and decodes them to a 16 kHz, mono WAV file.

It is not part of the Baton application build. Reading `.pklg` files requires Apple's **Bluetooth Logging for macOS** profile and `PacketLogger.app`.

## Build

```bash
brew install opus
./mic-spike/build.sh
```

## Decode a PacketLogger capture

```bash
./mic-spike/mic-spike decode-pklg siri.pklg siri.wav
```

The command reports capture sessions, Opus-frame count, sequence gaps, decode failures, and output duration.

## Extract frames separately

```bash
./mic-spike/mic-spike parse siri.pklg frames.txt
./mic-spike/mic-spike decode frames.txt siri.wav
```

`frames.txt` contains one frame per line as `[Opus length][Opus packet]` hexadecimal bytes.

## Decode a live PacketLogger stream

```bash
sudo /Applications/PacketLogger.app/Contents/Resources/packetlogger \
  convert --stdout --format itpnahdsr \
  | ./mic-spike/mic-spike stream live.wav
```

Press and hold the Siri button while speaking. Press Control-C when finished; `mic-spike` ignores the pipeline interrupt long enough to finalize the WAV header and prints capture statistics.
