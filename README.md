# readflow

Select text anywhere on macOS. Press `Ctrl+Esc`. Hear it read aloud. Press again to stop.

readflow is a single Hammerspoon config — no app bundle, no background daemon of its own, no telemetry. It reads with fast AI voices and degrades gracefully: if one voice tier is unavailable, the next takes over mid-sentence.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/michiosw/readflow/main/install.sh | bash
```

The guided installer sets up [Hammerspoon](https://www.hammerspoon.org/) if needed, asks for an optional Groq API key, offers the free local voice, walks you through the one-time Accessibility permission, and says hello when it's done. Requires macOS and [Homebrew](https://brew.sh/).

## Voices

readflow picks the best available tier and switches automatically — even mid-read:

| Tier | Voice | Cost | Notes |
| --- | --- | --- | --- |
| 1 | Orpheus via [Groq](https://console.groq.com/keys) | Free tier: 3,600 tokens/day (~2–4 pages), then $22/1M chars | Six voices, best quality. Accept the model terms [once](https://console.groq.com/playground?model=canopylabs%2Forpheus-v1-english). |
| 2 | Kokoro, local | Free, unlimited | Runs on your Mac (Apple Silicon, ~400 MB). Private and offline. |
| 3 | macOS built-in | Free | Always available. |

Text is split at sentence boundaries and streamed chunk by chunk; the first audio typically starts in one to two seconds.

## Settings

Everyday settings live in the menu bar (the small waveform icon): API key, voice, a test button. The hotkey and providers are plain values at the top of [init.lua](init.lua) — the endpoints are OpenAI-compatible, so any `/v1/audio/speech` server works.

## Notes

**Hammerspoon?** An open-source macOS automation engine — readflow runs inside it the way a script runs inside Node. It provides the global hotkey, the simulated `Cmd+C` that grabs your selection, and audio playback. Its own icon is hidden; you only see readflow's.

**Privacy.** With a Groq key, the text you select is sent to Groq when you press the hotkey — nowhere else. The local and built-in tiers never leave your Mac.

**Uninstall.** Remove the `~/.hammerspoon/init.lua` symlink and `~/.readflow`. If you installed the local voice: `launchctl bootout gui/$UID/dev.readflow.kokoro`, then remove `~/Library/LaunchAgents/dev.readflow.kokoro.plist` and `~/.local/share/readflow`.

## Credits

Inspired by [freeflow](https://github.com/zachlatta/freeflow) — the same idea in the opposite direction.

MIT © 2026 Michel Osswald
