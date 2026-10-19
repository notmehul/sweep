# Sweep

Sweep finds what's taking space on your Mac and explains it in plain language. Nothing leaves your Mac.

- **Rebuilds itself:** app caches, data left behind by deleted apps, and old developer clutter. Cleaned with one click.
- **Probably don't need:** apps you haven't opened in months, installers, duplicates, and old copies sitting next to new ones. These go to the Trash, so every removal can be undone.
- **Your call:** big files you haven't opened in a year. Sweep shows them and never touches them.

Explanations come from Apple's on-device model. There's no server, no account and no telemetry. Without Apple Intelligence, everything still works except the plain-language explanations.

> Status: early development. See [docs/status.md](docs/status.md).

## Build

Requires macOS 27+ on Apple Silicon and the Command Line Tools. Xcode isn't needed.

```sh
swift test          # engine tests
scripts/run.sh      # build, sign and open Sweep.app
```

Contributors start with [AGENTS.md](AGENTS.md). To add a cleanup rule, see [docs/rules.md](docs/rules.md).
