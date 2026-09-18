# dsh-notify-desktop

English | [中文](README.zh.md)

**A completion alert for DeepSeek Harness that you cannot miss.** When a session finishes, an **orange, always-on-top card** appears in the bottom-right corner and tells you **which session** finished. It stays until you deal with it. Click the card and the browser comes to the front and switches to that session; click the **✕** in its top-right corner and the card just closes, without jumping anywhere.

> Windows only. The host half runs inside DSH's Node process; the card itself is a zero-dependency PowerShell + WinForms script.

---

## Why not a system toast?

This is a deliberate trade-off, not an omission:

| Requirement | System toast / 40+ existing notification plugins | This plugin |
|---|---|---|
| **Orange** (or any custom colour) | ❌ Rendered by the OS; apps cannot change it | ✅ |
| **Stays until dismissed** | ❌ The OS collapses it into the Action Center | ✅ |
| Several sessions finishing at once | ❌ A new toast replaces the old one | ✅ Stacked vertically, one row each |
| **Click to jump to that session** | ⚠️ Can open the GUI, cannot select a specific session | ✅ See below |
| Non-ASCII session names | — | ✅ Passed as UTF-8 JSON, never through argv |

If all you want is a native system notification, something like `dsh-notify-windows` is less work. **This plugin exists for the case where you must see it at a glance, must know which session it was, and must be able to click back to it.**

---

## What it looks like

```
┌────────────────────────────────────────┐
│ Session finished                    ✕ │  ← ✕: closes the card, does NOT jump
│ Session: Fix login redirect · api-svc  │  ← which session just finished
│ The agent finished this turn. Cli…     │  ← click the card: browser to front + switch
└────────────────────────────────────────┘
```

Cards from concurrently finishing sessions **stack upwards** instead of covering each other, and the card carries `WS_EX_NOACTIVATE` so it **never steals focus while you are typing**.

---

## Install

```powershell
dsh plugin --profile web add dsh-notify-desktop
# then restart dsh web (plugin code changes require a restart;
# only the profile's own patch layer is hot-reloaded)
```

Before it is published to npm, install from a local path:

```powershell
dsh plugin --profile web add 'D:\path\to\dsh-notify-desktop'
```

Afterwards, check that `dsh-notify-desktop` shows up in the profile's bundles — `dsh.bundle.patch` declares it, and `dsh plugin add` appends it automatically.

---

## Configuration

Configuration goes in the profile's `cordis.patch.yml` (the defaults this package ships are in [`cordis.patch.yml`](./cordis.patch.yml)):

```yaml
- id: dsh-notify-desktop
  config:
    title: '会话完成'                # card headline — set any text you like
    accent: '#F7630C'
    persistUntilClick: true       # false = auto-close after 10s
    reasons: []                   # empty = notify for every end reason
    skipSubagents: true           # do not notify when a sub-agent finishes
    idleOnly: true                # wait until the agent is truly idle
    focusBrowser: true
    focusWindowTitle: 'Google Chrome'   # use 'Microsoft Edge' for Edge
```

| Field | Default | Meaning |
|---|---|---|
| `scriptPath` | `''` | Card script; empty = bundled `assets/dsh-notify.ps1` |
| `focusScriptPath` | `''` | Focus script; empty = bundled `assets/dsh-focus-window.ps1` |
| `title` / `message` | `会话完成` / per reason | Card text. **The shipped defaults are Chinese** — override them here if you want another language; e.g. `title: 'Session finished'` |
| `persistUntilClick` | `true` | Stay until clicked |
| `style` | `popup` | `popup` (custom card) / `toast` (system toast) / `auto` |
| `accent` | `#F7630C` | Accent colour |
| `reasons` | `[]` | Only notify for these end reasons (`completed` / `aborted` / `blocked` / `error` / `max-tokens` / `interrupted`) |
| `skipSubagents` | `true` | Skip sub-agent sessions |
| `idleOnly` / `idleTimeoutMs` | `true` / `300000` | Wait for `agent.whenIdle()` before notifying |
| `focusBrowser` | `true` | Bring the browser window to the front on click |
| `focusWindowTitle` / `focusWindowClass` | `Google Chrome` / `Chrome_WidgetWin` | How to find the browser: match the title substring first, fall back to the window class (Edge uses `Microsoft Edge`) |
| `pendingPath` / `clickPath` | `/dsh-notify/*` | The two internal routes |

---

## How it works

```
Host half (lib/index.js)
  ctx.on('session/event')  ──filter──▶ event.type === 'turn/end'
        │                              (turn/end is a session-log event, NOT a Cordis event)
        ├─ skip sub-agent sessions
        ├─ optional: wait for agent.whenIdle()
        ├─ read the title: ctx.get('sessionTitle').get(session).title
        └─ spawn the card (lib/card.js → cmd /c start → powershell + WinForms)

Card clicked  (clicking ✕ closes the card and skips everything below)
  └─ -OnClickUrl ──▶ GET /dsh-notify/click?session=<id>
                        ├─ host records the "session to select"
                        └─ host launches assets/dsh-focus-window.ps1 to bring the browser forward

Browser half (lib/client.js)
  polls GET /dsh-notify/pending once a second
        └─ pending session ▶ ctx.sessions.open(id)   ← switch to that session
```

**Why a browser half is mandatory.** "Currently selected session" is pure browser state (it lives in `localStorage`). The host has no notion of it, no RPC for it and no websocket event for it. The only place it can be changed is in the browser, via `ctx.sessions.open(id)`.

**Why the two routes are unauthenticated.** They are registered on `ctx.webServer` as exact routes, not on `ctx.connection.fetch` — the latter is hard-locked to `/api/**` and sits behind the browser-cookie auth fence, so a PowerShell request would get a 401.

---

## Known limitations

- **Windows only** (`os: ["win32"]`): the card is PowerShell + WinForms. "Click to jump to the session" additionally assumes the browser already has the GUI open.
- **"Bring to front" finds the browser by window title / class**, so the defaults are Chrome-shaped (`Google Chrome` / `Chrome_WidgetWin`). For Edge, change `focusWindowTitle` to `Microsoft Edge` (the class is the same).
- **`turn/end` is not "the whole tree settled".** DSH has no event for "every sub-agent has finished". For long tasks, `idleOnly` (wait until the agent is idle) is only an approximation.
- **Multiple browser tabs**: the pending session is single-consumer (read once, then cleared), so exactly one tab jumps. That is intentional.

---

## Verification on a real machine

All of the following were measured on Windows 10 Enterprise LTSC 2021 + `@deepseek-ai/dsh@0.1.5-rc.2` + Chrome:

| Item | Result |
|---|---|
| Card appears automatically when a session finishes | ✅ |
| Card shows the **session name** (correct non-ASCII text) | ✅ |
| **Stays until dismissed** | ✅ still there after 8+6 seconds |
| Top-right **✕ closes without jumping** | ✅ |
| **Click card → browser to front + GUI switches to that session** | ✅ |
| Clicking while already on the target session | ✅ works, and does **not** un-maximize/un-fullscreen the window |
| Clicking with the window normal / maximized / fullscreen | ✅ window state unaffected in all three |
| Several sessions finishing at once | ✅ stacked, one row each |
| Both internal routes reachable from PowerShell without auth | ✅ `/dsh-notify/pending` → 200 |

The host half also has an 18-assertion self-test: `node verify.mjs`.

---

## Development

```powershell
# Test the card script alone (outside DSH) — this will really pop a card
node -e "import('./lib/card.js').then(async (m) => { const s = m.resolveCardScript(''); console.log(m.showCard({ script: s, title: 'test', session: 'dev', message: 'hello', seconds: 8 })) })"

# Test the focus script alone (brings the browser window to the front)
powershell -NoProfile -ExecutionPolicy Bypass -File assets/dsh-focus-window.ps1

# Host-half self-test (stub ctx; does not pop a card)
node verify.mjs
```

Engineering notes — several traps that took a long time to pin down, worth reading before changing code — are in [`docs/engineering-notes.md`](./docs/engineering-notes.md).
First-hand research into the plugin API and a survey of existing notification plugins are in [`docs/research/`](./docs/research/).

## License

MIT
