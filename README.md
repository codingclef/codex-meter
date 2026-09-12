# Codex Meter

A tiny macOS menu bar app for watching your Codex 5-hour and weekly usage limits.

It reads `account/rateLimits/read` from the locally installed Codex app server. It does not send prompts or consume model tokens.

## Features

- Show the 5-hour limit, weekly limit, or both
- Refresh every 30 seconds and at conversation activity boundaries
- Show the 5-hour reset as remaining hours and the weekly reset as local date, weekday, and time (`9/19 토 18:32`); the menu shows the reset time to the second
- Remember the selected display mode

## Requirements

- macOS 13 or later
- ChatGPT desktop or Codex CLI installed and signed in
- Apple command-line developer tools (`xcode-select --install`)

## Build

```sh
make test
open "dist/Codex Meter.app"
```

## Install

```sh
make install
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.codingclef.codexmeter.plist"
```

Codex Meter is an unofficial utility and is not affiliated with or endorsed by OpenAI.

## License

MIT
