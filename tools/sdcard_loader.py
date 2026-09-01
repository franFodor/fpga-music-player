#!/usr/bin/env python3
"""Writes WAV files as raw PCM sectors + a manifest directly onto an SD
card's raw block device, for the FPGA player's raw-sector-streaming layout
(no filesystem).

On-disk layout (512-byte sectors, matching the SD block size):
  sector 0            manifest
  sector 1..           song data, one song per contiguous, sector-aligned
                       run (the last sector of each song is zero-padded)

Manifest (sector 0), all integers little-endian:
  offset 0   4 bytes   magic "SDMP"
  offset 4   4 bytes   uint32 song count N (<= 63)
  offset 8   N * 8B    entries: uint32 start_sector, uint32 length_sectors

Source WAVs must already be 16-bit PCM, 44.1kHz, stereo -- the format the
FPGA side is expected to stream verbatim; convert first if yours aren't.
"""
import argparse
import os
import struct
import sys
import wave

SECTOR_SIZE = 512
MANIFEST_SECTOR = 0
FIRST_DATA_SECTOR = 1
MAX_SONGS = 63
MANIFEST_MAGIC = b"SDMP"
EXPECTED_CHANNELS = 2
EXPECTED_SAMPWIDTH = 2  # bytes/sample = 16-bit
EXPECTED_FRAMERATE = 44100


def read_wav_pcm(path):
    with wave.open(path, "rb") as w:
        if w.getnchannels() != EXPECTED_CHANNELS:
            raise ValueError(f"{path}: expected {EXPECTED_CHANNELS} channels, got {w.getnchannels()}")
        if w.getsampwidth() != EXPECTED_SAMPWIDTH:
            raise ValueError(f"{path}: expected {EXPECTED_SAMPWIDTH * 8}-bit samples, got {w.getsampwidth() * 8}-bit")
        if w.getframerate() != EXPECTED_FRAMERATE:
            raise ValueError(f"{path}: expected {EXPECTED_FRAMERATE} Hz, got {w.getframerate()} Hz")
        return w.readframes(w.getnframes())


def build_layout(pcm_blobs):
    entries = []
    cursor = FIRST_DATA_SECTOR
    for pcm in pcm_blobs:
        length_sectors = (len(pcm) + SECTOR_SIZE - 1) // SECTOR_SIZE
        entries.append((cursor, length_sectors))
        cursor += length_sectors
    return entries


def build_manifest(entries):
    manifest = bytearray(SECTOR_SIZE)
    manifest[0:4] = MANIFEST_MAGIC
    struct.pack_into("<I", manifest, 4, len(entries))
    offset = 8
    for start_sector, length_sectors in entries:
        struct.pack_into("<II", manifest, offset, start_sector, length_sectors)
        offset += 8
    return bytes(manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("device", help="raw block device path, e.g. /dev/rdisk4 (macOS) or /dev/sdX (Linux)")
    parser.add_argument("songs", nargs="+", help="WAV files, in playback-index order")
    parser.add_argument("--dry-run", action="store_true", help="print the layout without writing anything")
    parser.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    args = parser.parse_args()

    if len(args.songs) > MAX_SONGS:
        sys.exit(f"error: {len(args.songs)} songs given, manifest supports at most {MAX_SONGS}")

    pcm_blobs = []
    for path in args.songs:
        try:
            pcm_blobs.append(read_wav_pcm(path))
        except (ValueError, wave.Error) as e:
            sys.exit(f"error: {e}")

    entries = build_layout(pcm_blobs)

    print(f"Target device: {args.device}")
    print(f"{len(entries)} song(s):")
    for i, ((start, length), path) in enumerate(zip(entries, args.songs)):
        print(f"  [{i}] {path}: sector {start}, {length} sectors ({length * SECTOR_SIZE} bytes)")
    total_sectors = entries[-1][0] + entries[-1][1] if entries else FIRST_DATA_SECTOR
    print(f"Total: {total_sectors} sectors ({total_sectors * SECTOR_SIZE} bytes) including manifest sector")

    if args.dry_run:
        return

    if not args.yes:
        reply = input(f"This will OVERWRITE {args.device}. Type the device path again to confirm: ")
        if reply != args.device:
            sys.exit("aborted: confirmation did not match")

    with open(args.device, "r+b") as f:
        for (start_sector, _length_sectors), pcm in zip(entries, pcm_blobs):
            f.seek(start_sector * SECTOR_SIZE)
            padded_len = ((len(pcm) + SECTOR_SIZE - 1) // SECTOR_SIZE) * SECTOR_SIZE
            f.write(pcm + b"\x00" * (padded_len - len(pcm)))
        f.seek(MANIFEST_SECTOR * SECTOR_SIZE)
        f.write(build_manifest(entries))
        f.flush()
        os.fsync(f.fileno())

    print("Done.")


if __name__ == "__main__":
    main()
