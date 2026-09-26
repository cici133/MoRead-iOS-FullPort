# Third-party notices — MoRead iOS port

This iOS port is a modified work based on `ovo066/MoRead` and is distributed under GNU GPL-3.0.
The original MoRead project in turn reuses or references GPL-compatible/open-source components as documented by its upstream `THIRD_PARTY_NOTICES.md`.

## Code/behavior ported from MoRead / Legado

- MoRead — GNU GPL-3.0. This iOS port preserves the application's functional boundaries and ports behavior to Apple platform APIs.
- Legado chapter-splitting rules and reader behavior references — GNU GPL-3.0. The TXT TOC rules are embedded in `TxtChapterSplitter.swift`.

## iOS target dependencies

- SwiftyOpenCC — MIT License, Copyright (c) 2017 DengXiang. Pinned to commit `1d8105a0f7199c90af722bff62728050c858e777`.
- ZIPFoundation — MIT License, Copyright (c) 2017-2026 Thomas Zoechling.
- SQLite — public domain; linked through the Apple platform SDK (`libsqlite3`).
- Apple system frameworks used by this port include SwiftUI, UIKit, WebKit, AVFoundation, MediaPlayer, BackgroundTasks, Network, Photos, UniformTypeIdentifiers and related iOS SDK frameworks.

No third-party dictionary data, books, API keys, Apple signing certificates, provisioning profiles, or user content are included in this repository.

For the full upstream dependency history and attribution of the Android project, see the original MoRead repository's `THIRD_PARTY_NOTICES.md`.
