# iPhone control compatibility build

Manual, unsigned device-build experiment based on [EliotAndres/iphone-use-app](https://github.com/EliotAndres/iphone-use-app), pinned to commit `20ac0665eea956f8fc3f96115f781b0ee9cdde9e`.

The upstream app and its source are licensed under [AGPL-3.0](https://github.com/EliotAndres/iphone-use-app/blob/20ac0665eea956f8fc3f96115f781b0ee9cdde9e/LICENSE). This repository contains the build recipe and a small AGPL-3.0 source patch that splits the upstream composer into smaller SwiftUI expressions for compiler compatibility. The workflow checks out that exact public source and applies the included patch, and builds without Apple credentials. It does not add a glasses bridge or establish device compatibility.

Run the workflow manually from Actions. It uses a standard public-repository macOS runner and refuses to run in private repositories. The resulting `iphone-control-unsigned.ipa` requires local signing before installation; `SHA256SUMS` records its checksum. Artifacts expire after three days.

This build uses `BUILTIN_VPN=NO` and removes bundled app extensions; it requires LocalDevVPN separately. Do not upload Apple credentials, certificates, pairing files, phone identifiers or personal data. Do not add secrets to this repository.

A successful compile is not proof of working on-device control. Screen capture, touch input, background operation and eventual glasses connectivity require separate physical-device testing.
