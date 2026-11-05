# ASFireWire

> **This is an unofficial fork of [mrmidi/ASFireWire](https://github.com/mrmidi/ASFireWire) that adds HDV capture.**
> The fork is not maintained by or affiliated with the ASFireWire author, and its changes are not in upstream.
> See [What this fork adds](#what-this-fork-adds). The rest of this README, including everything written as "I",
> is the upstream author's text, and its website, sponsor, and contact links are upstream's. Please do not report
> problems with this fork's changes to upstream.

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=mrmidi_ASFW&metric=alert_status&token=3ca1b3d10414117bb3e75b1779090b4ea47f1585)](https://sonarcloud.io/summary/new_code?id=mrmidi_ASFW) [![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/mrmidi/ASFireWire)

ASFireWire restores FireWire (IEEE 1394) functionality removed from macOS Tahoe (26).
It rebuilds the stack with DriverKit and PCIDriverKit, with AudioDriverKit for audio
and SCSIControllerDriverKit for SBP-2 devices.

I started it to keep useful FireWire audio hardware running on modern Macs.
Contributors have since helped extend it to DV cameras and film scanners.

## What this fork adds

- **HDV capture.** The capture view also records HDV camcorders, which send an MPEG-2
  transport stream (IEC 61883-4) instead of DV. The driver detects the format from the
  stream and the app writes the transport stream to a `.m2t` file.
- **Automatic file names.** You choose an output folder instead of a file. Each capture
  gets its own file, such as `capture-2026-11-01-135615.m2t` or `.dv`, with the extension
  matching what the camcorder sends. Existing files are never overwritten.
- **Tape dropout counter (HDV only).** The capture view shows how many times the
  camcorder skipped tape it could not read, and when, for example `1 (at 0:17)`. Times
  count from the start of the capture, not the start of the tape. Packets lost on the
  FireWire bus are counted separately.
- **Fixes.** The output picker now opens on ad-hoc installs, and the end of a capture is
  no longer cut off when you stop it. Dev builds also get increasing build numbers, so
  each one can replace the last.

See [CHANGELOG.md](CHANGELOG.md) for details.

### What has been tested

Everything was tested with one setup: a Sony HVR-Z1U on an Apple Thunderbolt to FireWire
Adapter, connected to an Intel Mac Pro (2019) running macOS 26.7.

- HDV capture from tape: no bad packets or lost packets, and the files play in VLC.
- DV capture from the same camera with i.LINK CONV on: complete, valid frames.
- A tape with a known damaged spot: one dropout reported at the right time, followed by a
  brief freeze in VLC and normal playback after it.
- A recording stop point on tape: not counted as a dropout (one stop point checked).

Other camcorders have not been tested. Builds include Apple silicon code, but this fork
has not been run on an Apple silicon Mac.

### Known limitations

- On the HVR-Z1U the driver falls back to listening on broadcast channel 63 rather than
  setting up a dedicated connection. Captures were not affected.
- The transport buttons can report "no FCP response" even though the camera acts on the
  command.
- The output folder is not remembered between app launches.

### Installing this fork

The signed builds on the website below are upstream's and do not include these changes.
This fork has no signed builds or GitHub releases. Its builds are unsigned packages made
by the **Release (prebuilt tester build)** workflow under
[Actions](https://github.com/yshen0111/ASFireWire_HDV/actions/workflows/release.yml).
Workflow downloads require a GitHub login and expire after a while; to make your own,
fork this repository and run the workflow there.

1. Read upstream's [Installing](https://github.com/mrmidi/ASFireWire/wiki/Installing) guide.
   This path needs SIP (System Integrity Protection) disabled, which lowers your Mac's
   security.
2. Unzip the package into a local folder such as `~/Downloads`. Do not use iCloud Drive,
   because its file attributes break code signing.
3. Run `./install.sh` from that folder, then click **Install** in the app.
4. Run `systemextensionsctl list` to see which driver is active. After an upgrade the old
   driver can keep running until you reconnect the FireWire adapter or restart your Mac.

Use this fork's app with this fork's driver. The fork changed the capture ring they share,
so neither works with upstream's version of the other.

To capture, open the capture view, choose an output folder, click **Start Capture**, then
start playback. For HDV, turn i.LINK CONV off on the HVR-Z1U; with it on, the camera
converts to DV.

## Download and installation

**[Download ASFW and read the installation guide →](https://www.asfw.net/install/)**

The website provides signed and notarized builds, installation requirements,
upgrade instructions, and release notes.
Its tester guide covers Apple silicon Macs running macOS 26 or later.

Local development builds and older unsigned GitHub packages use a different signing
and installation path. Do not apply their SIP-disabled instructions to the hosted
signed build. See [Installing](https://github.com/mrmidi/ASFireWire/wiki/Installing)
and [Building and Signing](https://github.com/mrmidi/ASFireWire/wiki/Building-and-Signing).

Intel results are recorded separately in the compatibility wiki; the hosted tester
guide is not a claim that every Intel Mac or patched macOS installation works.

## Support development

For well over a year, ASFireWire has effectively been my full-time job — just without
the salary.

The project is free and open source, but the work behind it isn't free. Financial
contributions help cover my everyday living expenses and development tools, making
it possible for me to continue developing and maintaining ASFireWire.

ASFireWire is also a comprehensive real-world implementation built on Apple's
DriverKit frameworks. Its public source brings together controller initialization,
DMA, interrupts, device discovery, protocol handling, audio, and SCSI integration
in one stack, providing a practical reference for low-level driver development on
modern macOS. [Read more about the work](https://www.asfw.net/support/).

If ASFireWire has helped you keep your hardware running, or you believe this kind of
independent engineering work deserves to continue, please consider supporting it.

**[GitHub Sponsors](https://github.com/sponsors/mrmidi) ·
[Buy Me a Coffee](https://buymeacoffee.com/mistermidi)**

## Current capabilities

- FireWire controller bring-up, bus management, topology, and device discovery.
- Asynchronous transactions and isochronous communication.
- Audio streaming through AV/C, DICE/TCAT, MOTU, and RME device protocols.
- DV capture to `.dv` files, HDV capture to `.m2t` files (this fork), and AV/C tape
  transport control.
- SBP-2/SCSI integration for storage devices and scanners.

Contributors have verified DV capture from various MiniDV camcorders and scanning
with Nikon Coolscan 4000 and 9000 devices. These are results for particular devices,
not guarantees for an entire protocol family.

See [Architecture Overview](https://github.com/mrmidi/ASFireWire/wiki/Architecture-Overview)
for how the stack fits together and
[Device Compatibility](https://github.com/mrmidi/ASFireWire/wiki/Device-Compatibility)
for tested behavior, limitations, evidence, and contributor credits.

## Hardware compatibility

**[Check your device and host →](https://github.com/mrmidi/ASFireWire/wiki/Device-Compatibility)**

Support varies by model, chipset revision, firmware, and implementation maturity.
The wiki distinguishes maintainer-tested and contributor-tested results, enabled
implementations without hardware validation, and recognized but unsupported devices.
Reports identify the tested build where available and preserve known regressions.

Generic AV/C or DICE discovery does not guarantee working audio. A device appearing
in the app, or telemetry showing packets, does not establish playback or capture.

## Testing and contributing

Hardware tests, reproducible failures, diagnostic traces, and regression reports are
particularly valuable. A well-documented failed test can help as much as a success.

- [Hardware reports and compatibility](https://github.com/mrmidi/ASFireWire/wiki/Device-Compatibility).
- [Reporting Issues](https://github.com/mrmidi/ASFireWire/wiki/Reporting-Issues).
- [Exporting and collecting logs](https://github.com/mrmidi/ASFireWire/wiki/Logging).
- [Contribution policy](CONTRIBUTING.md).

Include your device, Mac, Intel/Apple silicon architecture, macOS version/build,
ASFW version, actual loaded driver build, connection chain, and reproduction steps.
Attach relevant logs and reports when available; explain when they cannot be collected.
Descriptions provide context, but logs and other evidence usually make a failure
possible to investigate.

Discuss substantial code changes in an issue before implementing them. Focused fixes,
simplification, and maintaining compatibility take priority over adding more code.
Contributors remain responsible for understanding and validating AI-assisted work.

## Documentation

| Topic | Resource |
| --- | --- |
| Public documentation | [Wiki home](https://github.com/mrmidi/ASFireWire/wiki) |
| Installation and downloads | [Website guide](https://www.asfw.net/install/) |
| Architecture and layer boundaries | [Architecture Overview](https://github.com/mrmidi/ASFireWire/wiki/Architecture-Overview) |
| Protocol background and historical references | [FireWire Fundamentals](https://github.com/mrmidi/ASFireWire/wiki/FireWire-Fundamentals) |
| Local builds, signing, and tests | [Building and Signing](https://github.com/mrmidi/ASFireWire/wiki/Building-and-Signing) |
| Hardware results | [Device Compatibility](https://github.com/mrmidi/ASFireWire/wiki/Device-Compatibility) |
| Troubleshooting | [Troubleshooting](https://github.com/mrmidi/ASFireWire/wiki/Troubleshooting) |
| Developer onboarding and optional MCP diagnostics | [Development](https://github.com/mrmidi/ASFireWire/wiki/Development) |

Implementation contracts live alongside source. `documentation/fixtures/` retains
captured hardware reports and test evidence; public technical guides live in the wiki.
[CHANGELOG.md](CHANGELOG.md) records changes associated with releases.

## License

ASFireWire is licensed under the [Apache License, Version 2.0](LICENSE).
Contributions use the same terms (inbound = outbound, per section 5).

Linux, Apple, libffado, and other reference stacks are consulted as read-only
behavioral sources. They are not distributed with this repository, and their code
must not be copied into the driver. See [NOTICE](NOTICE) for attribution.

Hardware testers and code contributors are credited in the compatibility wiki and
release history. Both make this work possible.

## Contact and professional opportunities

- [Discord community](https://discord.gg/c82rmSEEPY).
- Email: [me@mrmidi.net](mailto:me@mrmidi.net).
- [LinkedIn](https://www.linkedin.com/in/mrmidi/).

I'm open to employment or contract opportunities in systems programming, driver
and low-level C/C++ development, embedded systems, and real-time audio/video software.
This project is a public example of my engineering work.
