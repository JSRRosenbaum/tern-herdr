# tern-herdr

Herdr inside Tern, drawn by Tern itself. Herdr keeps the agents and terminals running; Tern shows them as native tabs, splits and a sidebar, and answers Herdr's prefix keys.

This fork extends [safzanpirani/tern-herdr](https://github.com/safzanpirani/tern-herdr) with saved Herdr profiles, persisted herds, repository/worktree grouping, and native TSP attachment.

## Two views

**Tabs mirror** (`cmd+shift+m`, "Herdr: Toggle Tabs Mirror"). Every Herdr tab becomes a Tern tab and every Herdr pane a Tern split in it. Tabs are named after their space (`api`, `web · 2`) and colored by agent state: red is blocked, yellow is working, green is done. Tabs and panes reconcile from Herdr's snapshots. Closing a Tern tab only hides it; Herdr keeps the pane. Turning the mirror off closes the Tern tabs and leaves Herdr running.

**Sidebar** (`cmd+shift+h`, "Herdr: Open Sidebar"). A `herdr` tab with a native rail on the left and one terminal on the right that follows what you click.

- Herd tabs contain their saved machine/session profiles. Repository headers group linked worktrees and their workspaces; click a header to collapse it. Workspace and pane actions retain Herdr's IDs rather than assuming row positions. Offline machines retain their inventory.
- The bar between the two sections has **new** (a new space), **▴ ▾** (move the agents section up or down; `[` and `]` do the same) and **menu** (new space, new tab, close space, integrations, machine, tabs mirror, refresh). Closing a space takes a second click.
- As in Herdr, a dot on **menu** means the machine has agent integrations to install or update: an agent's command is on PATH but its Herdr integration is missing or outdated. The menu lists them; click one to run `herdr integration install` on that machine. The check runs about once a minute.
- Under the space being shown, a row lists its Herdr tabs as `1 2 +`. Click a tab to show it, or `+` to create one. (It lives in the sidebar because a separate Tern block can't be shorter than three rows.)
- Keys in the rail: `↑`/`↓` select, `enter` shows, `n` new space, `m` menu, `r` refresh.

## Remote machines

The inventory comes from Herdr's saved machine profiles and persisted herd membership, not a second SSH-host list. A profile's opaque ID and saved session identify its endpoint. Two profiles on the same SSH host can therefore remain distinct, including the host's `default` session and a separately named production session.

Local `default` and named local sessions are explicit selectors too. The follower clears inherited Herdr socket/session overrides before using a selector, so launching Tern from another Herdr pane cannot silently change its target.

The local Unix CLI uses `--machine PROFILE_ID terminal native-attach TERMINAL_ID` for SSH profiles. Herdr resolves the SSH settings and remote session itself. Both the local client and running remote server need this fork's native-attach support; an unsupported or unavailable server fails instead of substituting an ANSI stream.

## Presentation

Choose **Use ANSI screen** or **Use Native TSP** from the sidebar menu or command palette. Changing the view replaces only the local attach client, not the backend application.

| View | Presentation contract |
|---|---|
| Native TSP (default) | Forwards new application output without reconstructing its earlier screen or native graph. A companion-enabled OMP can re-probe after the attachment is ready. No automatic ANSI fallback. |
| ANSI screen | Uses Herdr's classic `terminal attach` renderer, including the existing screen of an idle ANSI application. Classic keyboard, mouse, paste and detach behavior apply. |

The choice is saved by profile and server-owned terminal ID. A new terminal identity, including one allocated by a backend handoff, defaults to Native TSP. ANSI view follows classic attach's dormant-terminal activation rules; selecting Native TSP does not resume dormant terminals.


## Herdr keys

The plugin reads `[keys]` from Herdr's configuration and exports prefix sequences such as `ctrl+space>c`. They act only in Herdr panes; unrelated Tern panes retain their existing fallback actions. Pressing the prefix twice sends the prefix to the program.

Run **Herdr: Export Keybinding Proposal** to generate `keybinds-proposal.json` in the plugin's data directory, then merge its `keybinds` into Tern's settings without replacing unrelated user bindings. Tern's user layer is needed where native presets outrank plugin defaults.

For a Ctrl+Space Herdr prefix, remove Tern's exact-prefix action with an **empty array**, not the string `"unbind"`; the latter prevents the sequence from starting. Move SQLite completion to the tested Ctrl+Alt+period shortcut:

```json
{
  "keybinds": {
    "ctrl+space": [],
    "ctrl+space>c": ["plugin.herdr.key_new_tab"],
    "ctrl+alt+.": "sqlite.execute.complete"
  }
}
```

The proposal includes the remaining Herdr navigation bindings and existing outside-Herdr fallbacks. If the desktop intercepts Ctrl+Alt+Left/Right, use the visible herd tabs instead.

| Herdr action | Does |
|---|---|
| `new_tab`, `new_workspace` | `herdr tab create` / `herdr workspace create` in the current pane's space and directory, then focuses it |
| `split_vertical`, `split_horizontal` | `herdr pane split` right / down; the new pane appears as a Tern split on that side |
| `close_pane`, `close_tab`, `close_workspace` | closes it in Herdr; the mirror follows |
| `next_tab`, `previous_tab`, `switch_tab 1..9` | moves between the current space's tabs |
| `next_workspace`, `previous_workspace`, `switch_workspace 1..9` | moves between spaces |
| `next_herd`, `previous_herd` | moves through persisted herds, including empty herds |
| `next_agent`, `previous_agent` | cycles agents in space order |
| `focus_pane_left/down/up/right`, `cycle_pane_*`, `last_pane` | moves focus between Tern panes |
| `zoom`, `rename_tab` | Tern's zoom and rename |
| `workspace_picker`, `goto`, `toggle_sidebar` | opens the sidebar |
| `detach` | turns the tabs mirror off |

Herdr settings, help, resize mode, scrollback editing and worktree creation commands aren't mapped.

## Also

- A toast appears when an agent turns blocked, or goes from working to done.
- "Herdr: Jump to Agent Needing Attention" (`cmd+shift+j`) shows the most urgent blocked or done agent.
- With `status_bar` on, the status line shows counts such as `herdr 1 blocked · 2 working`.

## How it works

- Each terminal runs `follow.sh` against a private target triple (`SELECTOR TERMINAL_ID MODE`, where mode is `native` or `ansi`). Switching stops and waits for only its local attach client; no detach keystroke is injected into an agent.
- The matching `.on` marker is published after native approval and frontend isolation, or after the first approved classic terminal frame is written. Both input readers check the desired target before forwarding; a delayed observer cannot send new typing to the old application. Pending views keep sidebar focus and suppress premature backend actions.
- `window.luau` polls Herdr snapshots per saved profile. It mirrors tabs and panes, restores herd navigation, registers key sequences, and invokes the Herdr CLI for actions.
- `keymap.luau` turns Herdr's key specs into Tern sequences. For example, `prefix+shift+1..9` becomes `ctrl+x>shift+1` and `ctrl+x>!`, because terminals report shifted keys either way.
- `host.luau` holds the sidebar block, styled by `sidebar.css`. The `tabs` block is an older tab strip, kept so existing layouts still load.
- `common.luau` finds the binaries, parses Herdr's JSON and holds the link helpers.

Requires Tern with plugin/TSP support and a local Linux/macOS Herdr client advertising `scoped-terminal-attach-v2`. Older local clients expose inventory only; a follower also checks this capability before launch. Native remote servers need `native-terminal-attach-v1`, including Windows servers with the complete ConPTY package. Native input is opaque: `ctrl+b q` is not a native detach command.

## Install

```sh
tern plugin install github.com/JSRRosenbaum/tern-herdr
```

Or clone it and run `tern plugin link .` to use it in place. Run `tern plugin types .` to write `tern.d.luau` for luau-lsp.

When updating the local CLI and plugin, recreate the Herdr follower panes (close and reopen the Herdr tab). Running follower shells retain their old script and environment contract. Do not restart backend agents.

## OMP native renderer

From a checkout of this repository, install the companion for **future OMP processes**:

```sh
mkdir -p ~/.omp/agent/extensions
ln -s "$PWD/omp-native.ts" ~/.omp/agent/extensions/herdr-tern-native.ts
```

Select **Use Native TSP**, wait for the attachment to become ready, then run these commands in an idle companion-enabled OMP agent:

```text
/native on
/native status
/native off
```

`/native on` explicitly probes the real Tern frontend and also re-probes after reattachment. It stops/starts only the existing TUI transport, preserving the agent PID, session and in-memory transcript; it does not start a model turn. A missing native handshake is reported, not presented as success. Mode changes require the agent and its pending-message queue to be idle. OMP 18.10.4 was exercised with the actual companion.

View selection does not change OMP's renderer. To return a native-rendering OMP to an ANSI screen, run `/native off` before selecting **Use ANSI screen**.

Installing the file does not hot-load it into agents already running. Their existing ANSI renderer can remain in use without restarting them. OMP's session/plugin reload commands must not be treated as a way to load a new TypeScript extension.

## Background control

Use Tern's own background control API with an explicit window/pane target and fresh target verification. A Hyprland Cua driver can pass general-native qualification yet return `client_not_bound` when Tern has not bound its synthetic seat; admission alone is not proof that background input reaches the application. No foreground takeover is required for the Tern API route.
