# iPhone control compatibility build

Manual, unsigned device-build experiment based on [EliotAndres/iphone-use-app](https://github.com/EliotAndres/iphone-use-app), pinned to commit `20ac0665eea956f8fc3f96115f781b0ee9cdde9e`.

The upstream app and its source are licensed under [AGPL-3.0](https://github.com/EliotAndres/iphone-use-app/blob/20ac0665eea956f8fc3f96115f781b0ee9cdde9e/LICENSE). This repository contains the build recipe, a compiler compatibility patch, and an AGPL-3.0 iPhone glasses companion overlay. The workflow checks out that exact public source, applies the patches, tests cryptographic interoperability with Glasscast, and builds without Apple credentials.

Run the workflow manually from Actions. It uses a standard public-repository macOS runner and refuses to run in private repositories. The resulting `iphone-control-unsigned.ipa` requires local signing before installation; `SHA256SUMS` records its checksum. Artifacts expire after three days.

This build uses `BUILTIN_VPN=NO` and removes bundled app extensions; it requires LocalDevVPN separately. Do not upload Apple credentials, certificates, pairing files, phone identifiers or personal data. Do not add secrets to this repository.

A successful compile is not proof of working on-device control. Screen capture, touch input, background operation and eventual glasses connectivity require separate physical-device testing.

## Experimental glasses companion

The eyeglasses toolbar button opens a separate screen for configuring an existing HTTPS Glasscast server. It uses Glasscast's phone protocol: numeric-comparison P-256 pairing, per-session mutual authentication, authenticated SDP, and a native WebRTC screen track and input data channel. Server registration and glasses pairing tokens stay in this device's Keychain. Each sharing session requires approval on the iPhone. Stop, a lost glasses heartbeat, capture failure, and phone locking end the session. No AI API or microphone capture is used.

This first build uses direct ICE candidates, so the phone and glasses must have a reachable network path. The relay server handles setup only. Current inputs: tap, double tap, swipe, drag-on-release, Home, edge-swipe Back, double-Home Apps, notification swipe, printable ASCII text and Enter. Switch-app, Send, Backspace and non-ASCII text return unsupported. The video is sampled from developer-service screenshots, so it is not a high-frame-rate screen recorder.

WebRTC is pinned to [stasel/WebRTC 157.0.0](https://github.com/stasel/WebRTC/tree/157.0.0), a binary distribution of Google's BSD-licensed WebRTC. Pairing and message interoperability follow [Glasscast](https://github.com/handzlikchris/Glasscast); source comments identify the shared protocol vectors. The overlay does not include any owner credentials, hostnames, device identifiers or pairing material.
