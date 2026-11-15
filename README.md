# portcall for Zeron

A [Zeron](https://zeron.sh) plugin for [portcall](https://github.com/joris-gallot/portcall): the dev servers portcall runs, beside the chat.

- **In a chat's panel**, under its branch: "Dev servers 2/5 running" for the project of the session's folder. A click opens its services in a tab.
- **In the sidebar**, a Dev servers page: every project portcall knows.

Each service shows its state, its port and what portcall adds (an exit code, who holds the port, where it listens instead), with Start, Stop, Restart and its error lines. Ports a project listens on without declaring them are listed under it.

The plugin only runs the portcall CLI (`portcall status --json`, `up`, `down`, `restart`, `logs --errors`), as an agent would.

## Install

1. Install portcall: `npm i -g portcall` (Node 20.19+).
2. In Zeron, Settings → Plugins → Install…, from `joris-gallot/portcall-zeron`.

It asks to run `portcall` as you (`commands`), and to read your sessions and their folders (`sessions.read`, `files.read`) to find each chat's project.

### portcall must be on your login shell's PATH

Zeron finds programs on the PATH of your login shell, which reads `~/.zprofile` but not `~/.zshrc`. If Node comes from fnm, nvm or pnpm set up in `~/.zshrc`, Zeron won't find `portcall` ("isn't installed on this device"). Either move that setup to `~/.zprofile`, or link portcall into a folder that is on it:

```sh
ln -s "$(which portcall)" /opt/homebrew/bin/portcall
```

## Develop

Zeron loads the plugin from `~/.zeron/plugins/portcall`, re-signs it and reloads it on every save. `init.luau` places it, `portcall.luau` runs the CLI and keeps its answers, `services.luau` draws a project's services. `zeron.luau` is Zeron's SDK. The guide: `~/.zeron/docs/plugins.md`.

## License

MIT
