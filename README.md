# readflow

I wanted to *hear* what Claude Code and Codex tell me instead of reading walls of terminal text. So: select the text, press `Ctrl+Esc`, and it reads it out loud. Works in any app on macOS — terminal, browser, PDF. Press again to stop.

I didn't want another app bloating my Mac, so readflow is just one script (~300 lines of Lua) running on [Hammerspoon](https://www.hammerspoon.org/), a native macOS automation engine. No app bundle, no daemon, no telemetry. The only thing you'll see is a small waveform icon in the menu bar.

## Three voices, switching automatically

readflow always finds a voice — it degrades gracefully, even mid-sentence:

1. **Groq** — if you have a [free API key](https://console.groq.com/keys) and quota left, you get the Orpheus AI voices. Best quality. (Free tier is ~2–4 pages a day; paid is about a cent per page.)
2. **Local AI voice** — when Groq's quota runs out (or you never set a key), a small Kokoro model running on your own Mac takes over. Free, unlimited, offline. Sounds nearly as good.
3. **macOS built-in** — if the local voice isn't installed or somehow broken, the plain system voice steps in. Always works.

You never configure which one — it just switches and tells you when it does.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/michiosw/readflow/main/install.sh | bash
```

Takes about a minute: sets up Hammerspoon if needed, asks for the optional Groq key, offers the local voice (~400 MB, recommended), walks you through the one-time Accessibility permission, and says hello out loud when it's done. Requires macOS and [Homebrew](https://brew.sh/).

Settings live in the menu bar icon: paste a key, pick a voice, test it.

## Privacy

Only the Groq tier sends anything anywhere — the text you select, to Groq, when you press the hotkey, nothing else. The local and built-in voices never leave your Mac. There is no readflow server.

## Uninstall

Remove the `~/.hammerspoon/init.lua` symlink and `~/.readflow`. If you installed the local voice: `launchctl bootout gui/$UID/dev.readflow.kokoro`, then delete `~/Library/LaunchAgents/dev.readflow.kokoro.plist` and `~/.local/share/readflow`.

## Credits

Inspired by [freeflow](https://github.com/zachlatta/freeflow) — the same idea in the opposite direction (your voice → text).

MIT © 2026 Michel Osswald
