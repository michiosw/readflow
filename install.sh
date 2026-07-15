#!/usr/bin/env bash

set -euo pipefail

readonly REPO_URL="https://github.com/michiosw/readflow.git"
readonly BOLD=$'\033[1m'
readonly RESET=$'\033[0m'

step() {
  printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"
}

die() {
  printf 'readflow: %s\n' "$1" >&2
  exit 1
}

if { exec 3<>/dev/tty; } 2>/dev/null; then
  HAS_TTY=true
else
  HAS_TTY=false
fi

step "Check macOS"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS is required."
printf 'macOS found.\n'

step "Install Hammerspoon"
hammerspoon_app=""
for candidate in "/Applications/Hammerspoon.app" "$HOME/Applications/Hammerspoon.app"; do
  if [[ -d "$candidate" ]]; then
    hammerspoon_app="$candidate"
    break
  fi
done

if [[ -z "$hammerspoon_app" ]]; then
  command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh/"
  brew install --cask hammerspoon
  hammerspoon_app="/Applications/Hammerspoon.app"
else
  printf 'Hammerspoon is already installed.\n'
fi

step "Install readflow"
script_source="${BASH_SOURCE[0]:-}"
repo_dir=""
if [[ -n "$script_source" && -f "$script_source" ]]; then
  script_dir="$(cd "$(dirname "$script_source")" && pwd)"
  if [[ -f "$script_dir/init.lua" ]]; then
    repo_dir="$script_dir"
  fi
fi

if [[ -z "$repo_dir" ]]; then
  repo_dir="$HOME/.readflow"
  if [[ -d "$repo_dir/.git" && -f "$repo_dir/init.lua" ]]; then
    printf 'Using existing %s.\n' "$repo_dir"
  elif [[ -e "$repo_dir" ]]; then
    die "$repo_dir already exists but is not a readflow clone. Move it and run the installer again."
  else
    command -v git >/dev/null 2>&1 || die "Git is required to clone readflow."
    git clone --quiet "$REPO_URL" "$repo_dir"
    printf 'Cloned readflow to %s.\n' "$repo_dir"
  fi
else
  printf 'Using local checkout %s.\n' "$repo_dir"
fi

source_config="$repo_dir/init.lua"
target_dir="$HOME/.hammerspoon"
target_config="$target_dir/init.lua"
mkdir -p "$target_dir"

if [[ -e "$target_config" && ! -L "$target_config" ]]; then
  lua_path=${source_config//\\/\\\\}
  lua_path=${lua_path//\"/\\\"}
  printf 'Your existing %s was left untouched. Add this line to it:\n\n' "$target_config"
  printf 'dofile("%s")\n\n' "$lua_path"
  if [[ "$HAS_TTY" == true ]]; then
    printf 'Save the file, then press Enter to continue. ' >&3
    IFS= read -r _ <&3
  else
    printf 'Add the line before reloading Hammerspoon.\n'
  fi
else
  ln -sfn "$source_config" "$target_config"
  printf 'Linked %s.\n' "$target_config"
fi

step "Configure speech"
api_key=""
if [[ "$HAS_TTY" == true ]]; then
  printf 'Groq API key (Enter to skip and use the built-in macOS voice): ' >&3
  IFS= read -r -s api_key <&3 || true
  printf '\n' >&3
else
  printf 'No terminal available; skipping the optional Groq API key.\n'
fi

if [[ -n "$api_key" ]]; then
  zshenv="$HOME/.zshenv"
  zshenv_comment="# readflow: Hammerspoon spawns non-interactive shells, which do not read ~/.zshrc."
  zshenv_tmp="$(mktemp "${TMPDIR:-/tmp}/readflow-zshenv.XXXXXX")"
  trap 'rm -f "${zshenv_tmp:-}"' EXIT
  if [[ -f "$zshenv" ]]; then
    awk -v comment="$zshenv_comment" '
      $0 == comment { next }
      $0 ~ /^[[:space:]]*(export[[:space:]]+)?GROQ_API_KEY[[:space:]]*=/ { next }
      { print }
    ' "$zshenv" > "$zshenv_tmp"
  fi
  printf '%s\n' "$zshenv_comment" >> "$zshenv_tmp"
  printf 'export GROQ_API_KEY=%q\n' "$api_key" >> "$zshenv_tmp"
  chmod 600 "$zshenv_tmp"
  mv "$zshenv_tmp" "$zshenv"
  trap - EXIT
  printf 'Saved the key to ~/.zshenv.\n'
else
  printf 'Using the built-in macOS voice.\n'
fi

printf 'Accept the Orpheus model terms once: %s\n' \
  'https://console.groq.com/playground?model=canopylabs%2Forpheus-v1-english'

step "Free local AI voice"
kokoro_url="http://127.0.0.1:8930/v1/models"
if curl --silent --show-error --fail --max-time 2 "$kokoro_url" >/dev/null 2>&1; then
  printf 'The free local AI voice is already installed.\n'
elif [[ "$HAS_TTY" == true ]]; then
  printf 'Install the free local AI voice? Unlimited, private, ~400 MB download [y/N] ' >&3
  install_local=""
  IFS= read -r install_local <&3 || true
  if [[ "$install_local" == "y" || "$install_local" == "Y" ]]; then
    if ! command -v uv >/dev/null 2>&1; then
      if command -v brew >/dev/null 2>&1; then
        brew install uv
      else
        printf 'uv is required. Install it from https://docs.astral.sh/uv/ and re-run install.sh.\n'
        install_local=""
      fi
    fi
    if [[ -n "$install_local" ]]; then
      kokoro_dir="$HOME/.local/share/readflow"
      kokoro_venv="$kokoro_dir/venv"
      kokoro_plist="$HOME/Library/LaunchAgents/dev.readflow.kokoro.plist"
      mkdir -p "$kokoro_dir" "$(dirname "$kokoro_plist")"
      if [[ ! -x "$kokoro_venv/bin/python" ]]; then
        uv venv "$kokoro_venv"
      fi
      VIRTUAL_ENV="$kokoro_venv" uv pip install \
        mlx-audio uvicorn fastapi webrtcvad python-multipart 'setuptools<81' 'misaki[en]'
      cat > "$kokoro_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.readflow.kokoro</string>
  <key>ProgramArguments</key>
  <array>
    <string>$kokoro_venv/bin/mlx_audio.server</string>
    <string>--host</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>8930</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>$kokoro_dir</string>
  <key>StandardOutPath</key>
  <string>/tmp/readflow-kokoro.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/readflow-kokoro.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VIRTUAL_ENV</key>
    <string>$kokoro_venv</string>
  </dict>
</dict>
</plist>
PLIST
      if launchctl print "gui/$UID/dev.readflow.kokoro" >/dev/null 2>&1; then
        launchctl bootout "gui/$UID" "$kokoro_plist" >/dev/null 2>&1 || true
      fi
      launchctl bootstrap "gui/$UID" "$kokoro_plist"
      kokoro_deadline=$((SECONDS + 30))
      until curl --silent --show-error --fail --max-time 1 "$kokoro_url" >/dev/null 2>&1; do
        if (( SECONDS >= kokoro_deadline )); then
          die "the local voice did not start. Check /tmp/readflow-kokoro.log."
        fi
        sleep 1
      done
      printf 'Installed the free local AI voice.\n'
    fi
  else
    printf 'Skipping the free local AI voice.\n'
  fi
else
  printf 'The free local AI voice can be added later by re-running install.sh.\n'
fi

step "Grant Accessibility access"
open -a Hammerspoon

hs_cli="$(command -v hs 2>/dev/null || true)"
if [[ -z "$hs_cli" && -x "$hammerspoon_app/Contents/Frameworks/hs/hs" ]]; then
  hs_cli="$hammerspoon_app/Contents/Frameworks/hs/hs"
fi

ipc_ready=false
if [[ -n "$hs_cli" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if "$hs_cli" -t 1 -c 'return true' >/dev/null 2>&1; then
      ipc_ready=true
      break
    fi
    sleep 1
  done
fi

if [[ "$ipc_ready" == true ]]; then
  "$hs_cli" -t 2 -c 'hs.accessibilityState(true)' >/dev/null 2>&1 || true
else
  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
fi

if [[ "$HAS_TTY" == true ]]; then
  printf 'Allow Hammerspoon under Accessibility, then press Enter. ' >&3
  IFS= read -r _ <&3
else
  printf 'Allow Hammerspoon under System Settings → Privacy & Security → Accessibility.\n'
fi

step "Reload and test"
if [[ -z "$hs_cli" ]]; then
  die "the Hammerspoon CLI was not found. Reload from its menu, then run: hs -c 'speak(\"Readflow is ready.\")'"
fi

"$hs_cli" -t 2 -c 'hs.reload()' >/dev/null 2>&1 || true
ipc_ready=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if "$hs_cli" -t 1 -c 'return true' >/dev/null 2>&1; then
    ipc_ready=true
    break
  fi
  sleep 1
done

if [[ "$ipc_ready" == true ]] && \
  "$hs_cli" -t 4 -c 'speak("Readflow is ready.")' >/dev/null 2>&1; then
  printf 'Done. Select text and press Ctrl+Escape.\n'
else
  die "the smoke test could not reach Hammerspoon. Reload its config and run: hs -c 'speak(\"Readflow is ready.\")'"
fi
