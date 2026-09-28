# Grok Bot Tray

Keep [Grok Bot](https://cursor.com/download/bot) resident in a system-tray-like
status widget: closing the window keeps the agent **online**, the bar icon
toggles its window, crashes respawn automatically, and it **auto-updates** on
Linux (the app itself reports "this platform does not support updates").

一个让 Grok Bot 常驻在线的 Omarchy 插件：关窗不掉线、bar 图标控制显隐、
崩溃自动拉起，并在 Linux 上补齐**自动更新**（应用自述"此平台不支持更新"）。

**English** · [中文](#中文)

---

## English

### What it does

- **Close the window, stay online** — the window is respawned and parked in a
  dedicated Hyprland special workspace (`special:grok-tray`), so the agent
  keeps running behind an icon in the status bar.
- **Bar widget** (Grok Bot logo + accent badge):
  - **Left click** — show the window / hide it into the tray workspace
  - **Right click** — menu: Show/Hide, Check for updates, Quit
- **Crash supervision** — a systemd user service restarts Grok Bot on crash or
  `kill -9`, and starts it hidden at login.
- **Daily auto-updater** — parses the official download page, downloads the
  latest `.deb`, unpacks it with `bsdtar`, swaps the install with rollback,
  verifies the new build boots, and notifies you of the result.
- **Zero patching** — the Grok Bot application itself is never modified.

### How it works

```
bar widget ──click/ctl──> hyprctl (Lua hl API) ──hide/show──> special:grok-tray
     │
     └── menu ──> systemctl --user  ──> grok-bot.service
                                            └─ grokbot-run.sh (supervisor)
                                                ├─ autohide.sh  (park on start)
                                                └─ grokbot-update.sh (daily timer)
```

### Requirements

- Omarchy with Hyprland **0.56+** (the scripts use the Lua `hl.dsp` dispatcher API)
- Grok Bot desktop app (Linux x64), typically at
  `~/.local/opt/Grok Bot` or `/opt/Grok Bot` (override with `GROKBOT_APP_DIR`)
- `curl`, `bsdtar`, `jq`, `notify-send`, systemd user session

### Install

```bash
omarchy plugin add https://github.com/sunny0826/omarchy-grok-bot-tray.git
bash ~/.config/omarchy/plugins/sunny0826.grok-bot-tray/install.sh
omarchy plugin enable sunny0826.grok-bot-tray --section right
```

`install.sh` renders the systemd units against this plugin's real path and
enables `grok-bot.service` (supervisor) + `grok-bot-update.timer` (daily).

Optional flags:

```bash
bash .../install.sh --with-launcher   # unify desktop-icon clicks with the tray
bash .../install.sh --uninstall       # remove the systemd units
```

### Usage & behavior

| Action | Result |
|---|---|
| Close the window (X) | Process exits → supervisor relaunches in ~2 s → window parks in the tray (≈ minimize to tray) |
| Left click on bar icon | In tray → show + focus; visible → hide; not running → start |
| Right click → Check for updates | Update now, result via desktop notification |
| Right click → Quit Grok Bot | Real exit (service stopped, no respawn) |
| Crash / `kill -9` | Automatic restart + hide |
| Daily timer (early morning, randomized) | Check for updates, install silently, notify |

State lives in `~/.local/state/grok-bot-tray/` (`update.log`, `last-ws`).

### Configuration

```bash
export GROKBOT_APP_DIR=/custom/path/Grok Bot   # app install location
export GROKBOT_WIN_CLASS=grok-bot              # window class to match
```

### CLI

```bash
CTL=~/.config/omarchy/plugins/sunny0826.grok-bot-tray/scripts/grokbot-ctl.sh
$CTL status      # starting | stopped | running-visible | running-hidden
$CTL toggle      # show/hide/start as appropriate
bash "$(dirname $CTL)/grokbot-update.sh" check   # version comparison only
```

### Removal

```bash
bash ~/.config/omarchy/plugins/sunny0826.grok-bot-tray/install.sh --uninstall
omarchy plugin remove sunny0826.grok-bot-tray
rm -rf ~/.local/state/grok-bot-tray
```

### Known limitations

- "Close = minimize" is implemented as **fast respawn + auto-hide**: expect a
  ~1–3 s offline window, and in-app UI state resets (session data on the
  server is unaffected). Make the supervisor single-shot if you prefer
  close = quit.
- Grok Bot is single-instance: avoid launching the raw binary manually while
  the service runs (`grokbot-ctl.sh quit && start` restores order).
- System-wide installs under `/opt` are not auto-updated (root-owned) — the
  updater logs and skips; use your package manager there.
- Window matching relies on class `grok-bot`; set `GROKBOT_WIN_CLASS` if a
  future release renames it.

### Compliance & security

- The Grok Bot application is **never modified or reverse-engineered** —
  hiding uses Hyprland special workspaces and process supervision only.
- The updater fetches only from official endpoints
  (`cursor.com/download/bot` → `downloads.cursor.com`) and validates the
  archive with `bsdtar`. **Release integrity is fail-closed**: before
  unpacking, the package's SHA-256 must match the pin in this repository's
  [`checksums.txt`](checksums.txt) — a git-managed trust root that is
  independent of the mutable download URL (same-origin companion digests are
  deliberately not trusted). Unpinned releases are recorded to
  `observed-digests.txt` and **refused by default**; after reviewing the
  recorded digest, promote it with
  `scripts/grokbot-update.sh pin <version>` and publish the file, or set
  `GROKBOT_UPDATE_VERIFY=unpinned-ok` to opt into installing it directly.
  Rollback backups use unique paths (timestamp + pid), never clobbering a
  pre-existing directory.
- `install.sh` **refuses to overwrite, stop, disable, or remove systemd
  units it does not own**: every generated unit carries a `# Managed-by:`
  marker, existing units without it abort the install before anything is
  written, and `--uninstall` only stops/disables/removes units that carry
  the marker — a same-named service belonging to someone else keeps
  running, untouched.
- No `sudo`, no `curl | sh`, no network access other than the official
  download. `omarchy plugin add` never executes plugin code; `install.sh`
  is run explicitly by you.

### License & asset attribution

- Code: [MIT](LICENSE).
- `assets/grok-bot.png` is the Grok Bot application icon taken from the
  app's own hicolor installation, © xAI / Cursor. It is used here solely to
  identify the Grok Bot application this plugin manages; all rights remain
  with their owners.

---

## 中文

### 功能

- **关窗不掉线** — 窗口关闭后被守护进程重新拉起并停放进专用的 Hyprland
  特殊 workspace（`special:grok-tray`），agent 在 bar 图标后持续在线。
- **bar 插件**（Grok Bot logo + accent 角标）：
  - **左键** — 显示窗口 / 藏入托盘 workspace
  - **右键** — 菜单：显示/隐藏、检查更新、退出
- **崩溃守护** — systemd 用户服务在崩溃或 `kill -9` 后自动重启 Grok Bot，
  并在登录时自启隐藏。
- **每日自动更新** — 解析官方下载页，下载最新 `.deb`，`bsdtar` 解包，
  带回滚的换位安装，验证新版本能启动，结果桌面通知。
- **零侵入** — 从不修改 Grok Bot 应用本体。

### 工作原理

```
bar 插件 ──点击/ctl──> hyprctl（Lua hl API）──隐藏/显示──> special:grok-tray
     │
     └── 菜单 ──> systemctl --user ──> grok-bot.service
                                          └─ grokbot-run.sh（守护 wrapper）
                                              ├─ autohide.sh（启动即入托盘）
                                              └─ grokbot-update.sh（每日 timer）
```

### 环境要求

- Omarchy，Hyprland **0.56+**（脚本使用 Lua `hl.dsp` dispatcher API）
- Grok Bot 桌面应用（Linux x64），通常位于 `~/.local/opt/Grok Bot`
  或 `/opt/Grok Bot`（用 `GROKBOT_APP_DIR` 覆盖）
- `curl`、`bsdtar`、`jq`、`notify-send`、systemd 用户会话

### 安装

```bash
omarchy plugin add https://github.com/sunny0826/omarchy-grok-bot-tray.git
bash ~/.config/omarchy/plugins/sunny0826.grok-bot-tray/install.sh
omarchy plugin enable sunny0826.grok-bot-tray --section right
```

`install.sh` 会按插件实际路径渲染 systemd 单元并启用
`grok-bot.service`（守护）与 `grok-bot-update.timer`（每日更新检查）。

可选参数：

```bash
bash .../install.sh --with-launcher   # 让桌面图标点击也走托盘逻辑
bash .../install.sh --uninstall       # 卸载 systemd 单元
```

### 使用与行为

| 动作 | 结果 |
|---|---|
| 点窗口 X | 进程退出 → 约 2s 被守护拉起 → 窗口自动入托盘（≈ 最小化到托盘） |
| bar 左键 | 在托盘→显示并聚焦；可见→隐藏；未运行→启动 |
| bar 右键 → 检查更新 | 立即检查安装，结果桌面通知 |
| bar 右键 → 退出 Grok Bot | 真退出（服务停止，不复活） |
| 崩溃 / `kill -9` | 自动重启并隐藏 |
| 每日 timer（凌晨随机时段） | 检查更新、静默安装、发通知 |

状态文件位于 `~/.local/state/grok-bot-tray/`（`update.log`、`last-ws`）。

### 配置

```bash
export GROKBOT_APP_DIR=/自定义/路径/Grok Bot   # 应用安装位置
export GROKBOT_WIN_CLASS=grok-bot              # 要匹配的窗口 class
```

### 命令行

```bash
CTL=~/.config/omarchy/plugins/sunny0826.grok-bot-tray/scripts/grokbot-ctl.sh
$CTL status      # starting | stopped | running-visible | running-hidden
$CTL toggle      # 智能显示/隐藏/启动
bash "$(dirname $CTL)/grokbot-update.sh" check   # 仅版本对比
```

### 卸载

```bash
bash ~/.config/omarchy/plugins/sunny0826.grok-bot-tray/install.sh --uninstall
omarchy plugin remove sunny0826.grok-bot-tray
rm -rf ~/.local/state/grok-bot-tray
```

### 已知限制

- "关窗 = 最小化"本质是**快速重启 + 自动隐藏**：约 1-3 秒离线窗口，
  应用内未保存的 UI 状态会重置（服务端会话数据不受影响）。若更想要
  "关窗即真退出"，把守护脚本改为单次执行即可。
- Grok Bot 是单实例应用：服务运行期间避免直接启动原生二进制
  （`grokbot-ctl.sh quit && start` 可一键归位）。
- 系统级 `/opt` 安装（root 属主）不参与自动更新——更新器记录并跳过，
  请用包管理器升级。
- 窗口匹配依赖 class `grok-bot`，若未来版本更名请设置 `GROKBOT_WIN_CLASS`。

### 合规与安全

- **从不修改、不逆向** Grok Bot 应用本体——隐藏仅通过 Hyprland 特殊
  workspace 与进程守护实现（不触碰应用的使用条款限制）。
- 更新器仅访问官方源（`cursor.com/download/bot` → `downloads.cursor.com`），
  用 `bsdtar` 校验归档。**发布完整性为 fail-closed**：解包前包的 SHA-256
  必须与本仓库 [`checksums.txt`](checksums.txt) 中的 pin 一致——该文件由
  git 管理、独立于可变下载 URL（同源的伴随校验文件被有意不信任）。
  未 pin 的新版本记录到 `observed-digests.txt` 并**默认拒绝安装**；
  人工审查记录的摘要后，用 `scripts/grokbot-update.sh pin <version>`
  提升为 pin 并发布该文件，或显式设置
  `GROKBOT_UPDATE_VERIFY=unpinned-ok` 直接放行。回滚备份使用唯一路径
  （时间戳 + 进程号），绝不覆盖或删除既有目录。
- `install.sh` **拒绝覆盖、停止、禁用或删除不属于本插件的 systemd 单元**：
  每个生成的单元都带 `# Managed-by:` 标记；已存在的无标记单元会在写入
  任何内容前中止安装，`--uninstall` 也只对带标记的单元执行
  停止/禁用/删除——他人同名服务保持运行、绝不触碰。
- 全程无 `sudo`、无 `curl | sh`、除官方下载外无任何网络访问。
  `omarchy plugin add` 不会执行任何插件代码；`install.sh` 由你显式运行。

### 许可与素材归属

- 代码：[MIT](LICENSE)。
- `assets/grok-bot.png` 取自 Grok Bot 应用自身的 hicolor 图标安装，
  © xAI / Cursor，仅用于标识本插件所管理的 Grok Bot 应用，
  权利归原所有者所有。
