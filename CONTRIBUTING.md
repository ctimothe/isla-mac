# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a problem

Open an [issue](https://github.com/ctimothe/isla-mac/issues/new/choose). The
most useful thing to include is **Settings → About → Copy Diagnostics**:
it lists versions, settings and Isla's own log, and nothing you played, copied
or translated. Say which Mac you have and which macOS it runs.

## Building

You need macOS 15 or later and Xcode 26 or later. There is no Xcode project:
SwiftPM builds the app and `Scripts/bundle.sh` packages it.

```bash
swift test                       # unit tests
./scripts/check                  # everything CI runs
bash Scripts/bundle.sh release   # build/app.noindex/Isla.app
bash Scripts/install.sh          # install to /Applications and open it
```

Always install with `Scripts/install.sh` rather than opening the copy in
`build/`, or macOS ends up with two Isla apps registered.

## Making a change

- Branch from `main` as `feat/<name>` or `fix/<name>`.
- Run `./scripts/check` before you open a pull request. CI runs the same steps.
- Write commit subjects as a short sentence about what changes for the person
  using the Mac: `fix: the island stays at the notch while locked`.
- Every string a person sees goes in both `Resources/en.lproj` and
  `Resources/ru.lproj`. The English text is the key.
- Anything that sends data off the Mac, touches an account or changes a
  system-wide setting must be off by default and listed in the README's
  Privacy table.
- Don't add entitlements or new surfaces without opening an issue first.
- When behaviour changes, update
  [docs/development/spec.md](docs/development/spec.md) in the same change.

[AGENTS.md](AGENTS.md) describes the architecture in more depth. What Isla does
is in [docs/development/spec.md](docs/development/spec.md), and the checks
still owed on real hardware in
[docs/development/open-checks.md](docs/development/open-checks.md).

## License

By contributing you agree that your work is released under the
[MIT License](LICENSE).
