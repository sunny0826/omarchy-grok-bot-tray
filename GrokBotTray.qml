import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "guo.grok-bot-tray"

  readonly property string ctlPath: Qt.resolvedUrl("scripts/grokbot-ctl.sh").toString().replace("file://", "")
  readonly property string updatePath: Qt.resolvedUrl("scripts/grokbot-update.sh").toString().replace("file://", "")
  // starting | stopped | running-visible | running-hidden (from grokbot-ctl.sh)
  property string botState: "stopped"
  // on | off — the daily auto-update switch (grokbot-update.timer enable state)
  property string autoUpdateState: "on"
  // idle | checking | up-to-date | available | updating | failed — the
  // "Check for updates" flow: check first, install only on confirmation
  property string updateCheckState: "idle"
  property string updateCurrentVersion: ""
  property string updateLatestVersion: ""

  readonly property bool running: botState === "running-visible" || botState === "running-hidden"

  clip: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function run(arg) {
    Quickshell.execDetached([ctlPath, arg])
    refreshTimer.restart()
  }

  // The app itself can't update on Linux ("此平台不支持更新") — the external
  // updater checks the official download page, downloads, swaps and verifies;
  // it reports the outcome via desktop notification. Checking and installing
  // are separate steps: "Check for updates" only checks and shows the result
  // in the menu — nothing is installed before the user confirms.
  function runUpdateCheck() {
    root.updateCheckState = "checking"
    updateCheckProc.running = true
  }

  function runUpdate() {
    root.updateCheckState = "updating"
    Quickshell.execDetached([updatePath, "run"])
    updateResetTimer.restart()
  }

  function dismissUpdate() {
    root.updateCheckState = "idle"
  }

  // The auto-update choice persists as grok-bot-update.timer's enable state
  // (see grokbot-ctl.sh); re-read it after the detached toggle has landed.
  function runAutoupdateToggle() {
    Quickshell.execDetached([ctlPath, "autoupdate-toggle"])
    autoRefreshTimer.restart()
  }

  Process {
    id: statusProc
    command: [root.ctlPath, "status"]

    stdout: StdioCollector {
      onStreamFinished: root.botState = text.trim()
    }
  }

  Process {
    id: autoupdateProc
    command: [root.ctlPath, "autoupdate-status"]

    stdout: StdioCollector {
      onStreamFinished: root.autoUpdateState = text.trim()
    }
  }

  // Parses grokbot-update.sh check: "up-to-date <v>",
  // "update-available <v> -> <new>" or "check-failed (feed unreachable)".
  Process {
    id: updateCheckProc
    command: [root.updatePath, "check"]

    stdout: StdioCollector {
      onStreamFinished: {
        const out = text.trim();
        const arrow = out.indexOf("->");
        if (out.indexOf("update-available") === 0 && arrow >= 0) {
          root.updateCurrentVersion = out.slice(17, arrow).trim();
          root.updateLatestVersion = out.slice(arrow + 2).trim();
          root.updateCheckState = "available";
        } else if (out.indexOf("up-to-date") === 0) {
          root.updateCurrentVersion = out.slice(10).trim();
          root.updateCheckState = "up-to-date";
        } else {
          root.updateCheckState = "failed";
        }
      }
    }
  }

  // Safety: never leave the row stuck on "Updating…" if the updater's
  // completion notification is missed — back to idle after a while.
  Timer {
    id: updateResetTimer
    interval: 60000
    repeat: false
    onTriggered: if (root.updateCheckState === "updating") root.updateCheckState = "idle"
  }

  Timer {
    id: autoRefreshTimer
    interval: 700
    repeat: false
    onTriggered: autoupdateProc.running = true
  }

  Timer {
    id: refreshTimer
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: statusProc.running = true
  }

  // Grok Bot logo, rendered inside BarIconButton's optical canvas. The accent
  // badge marks "window on screen" so the three states stay readable:
  // badge = visible, plain = online hidden, dimmed = starting/stopped.
  Component {
    id: grokLogo

    Item {
      Image {
        anchors.fill: parent
        source: Qt.resolvedUrl("assets/grok-bot.png")
        sourceSize.width: 128
        sourceSize.height: 128
        fillMode: Image.PreserveAspectFit
      }

      Rectangle {
        visible: root.botState === "running-visible"
        anchors.right: parent.right
        anchors.top: parent.top
        width: Math.round(parent.width * 0.3)
        height: width
        radius: width / 2
        color: Color.accent
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: grokLogo
    dimmed: root.botState === "stopped" || root.botState === "starting"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: {
      switch (root.botState) {
      case "running-visible":
        return "Grok Bot — window visible (click to hide)";
      case "running-hidden":
        return "Grok Bot — online, hidden (click to show)";
      case "starting":
        return "Grok Bot — starting…";
      default:
        return "Grok Bot — not running (click to start)";
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        menu.open = !menu.open;
        if (menu.open) {
          autoupdateProc.running = true;
        }
      } else {
        root.run("toggle");
      }
    }
  }

  PopupCard {
    id: menu
    anchorItem: root
    bar: root.bar
    owner: root
    // Grow with the widest row text so status lines like
    // "No update available (current 0.61.0)" are never clipped; the
    // screen-fitted cap still protects very narrow displays.
    contentWidth: menu.fittedContentWidth(Math.max(Style.space(200), menu.padding * 2 + Math.max(toggleText.implicitWidth + Style.space(16), updateText.implicitWidth + Style.space(16), autoText.implicitWidth + Style.space(50), quitText.implicitWidth + Style.space(16))))
    contentHeight: menu.fittedContentHeight(menuColumn.implicitHeight)

    Column {
      id: menuColumn
      width: menu.contentWidth - menu.padding * 2
      spacing: Style.space(4)

      // Row 1: show/hide toggle
      Rectangle {
        id: toggleRow
        width: menuColumn.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        color: "transparent"
        border.width: toggleHover.hovered ? 1 : 0
        border.color: Color.popups.border

        Text {
          id: toggleText
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          width: parent.width - Style.space(16)
          elide: Text.ElideRight
          text: root.botState === "running-hidden" ? "Show window" : "Hide window"
          color: Color.popups.text
          opacity: root.running ? 1.0 : 0.4
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        HoverHandler {
          id: toggleHover
        }

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: {
            menu.open = false;
            root.run("toggle");
          }
        }
      }

      // Row: check for updates (external updater — the app can't update on
      // Linux). Checks only; the row shows the result and nothing is
      // installed before the user confirms below.
      Rectangle {
        id: updateRow
        width: menuColumn.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        color: "transparent"
        border.width: updateHover.hovered ? 1 : 0
        border.color: Color.popups.border

        Text {
          id: updateText
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          width: parent.width - Style.space(16)
          elide: Text.ElideRight
          text: {
            switch (root.updateCheckState) {
            case "checking":
              return "Checking for updates…";
            case "up-to-date":
              return "No update available" + (root.updateCurrentVersion ? " (current " + root.updateCurrentVersion + ")" : "");
            case "available":
              return "Update available: " + (root.updateLatestVersion || "new version");
            case "updating":
              return "Updating…";
            case "failed":
              return "Check failed (network) — tap to retry";
            default:
              return "Check for updates";
            }
          }
          color: root.updateCheckState === "available" ? Color.accent : Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        HoverHandler {
          id: updateHover
        }

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: {
            if (root.updateCheckState === "checking" || root.updateCheckState === "updating") {
              return;
            }
            root.runUpdateCheck();
          }
        }
      }

      // Row: confirm or dismiss the available update
      Row {
        visible: root.updateCheckState === "available"
        width: menuColumn.width
        height: Style.spacing.controlHeight
        spacing: Style.space(8)

        Rectangle {
          width: (menuColumn.width - Style.space(8)) / 2
          height: parent.height
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: Color.accent
          opacity: updateNowHover.hovered ? 0.75 : 1.0

          Text {
            anchors.centerIn: parent
            text: "Update now"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          HoverHandler {
            id: updateNowHover
          }

          TapHandler {
            acceptedButtons: Qt.LeftButton
            onTapped: {
              root.runUpdate();
            }
          }
        }

        Rectangle {
          width: (menuColumn.width - Style.space(8)) / 2
          height: parent.height
          radius: Style.cornerRadius
          color: "transparent"
          border.width: updateLaterHover.hovered ? 1 : 0
          border.color: Color.popups.border

          Text {
            anchors.centerIn: parent
            text: "Not now"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          HoverHandler {
            id: updateLaterHover
          }

          TapHandler {
            acceptedButtons: Qt.LeftButton
            onTapped: {
              root.dismissUpdate();
            }
          }
        }
      }

      // Row: daily auto-update switch (controls grok-bot-update.timer; the
      // choice is persistent and defaults to on)
      Rectangle {
        id: autoupdateRow
        width: menuColumn.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        color: "transparent"
        border.width: autoupdateHover.hovered ? 1 : 0
        border.color: Color.popups.border

        Text {
          id: autoText
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          width: parent.width - Style.space(50)
          elide: Text.ElideRight
          text: "Auto update"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // Switch: accent-filled track with the knob right = on,
        // dimmed track with the knob left = off.
        Rectangle {
          id: autoupdateTrack
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          width: Style.space(34)
          height: Style.space(18)
          radius: height / 2
          color: root.autoUpdateState === "on" ? Color.accent : Color.popups.border

          Rectangle {
            width: parent.height - 4
            height: width
            radius: width / 2
            color: Color.popups.text
            anchors.verticalCenter: parent.verticalCenter
            x: root.autoUpdateState === "on" ? parent.width - width - 2 : 2

            Behavior on x {
              NumberAnimation {
                duration: 120
              }
            }
          }
        }

        HoverHandler {
          id: autoupdateHover
        }

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: {
            root.runAutoupdateToggle();
          }
        }
      }

      // Row 2: real quit (systemctl stop — stays stopped)
      Rectangle {
        id: quitRow
        width: menuColumn.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        color: "transparent"
        border.width: quitHover.hovered ? 1 : 0
        border.color: Color.popups.border
        opacity: root.running ? 1 : 0.4

        Text {
          id: quitText
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          width: parent.width - Style.space(16)
          elide: Text.ElideRight
          text: "Quit Grok Bot"
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        HoverHandler {
          id: quitHover
        }

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: {
            if (!root.running) {
              return;
            }
            menu.open = false;
            root.run("quit");
          }
        }
      }
    }
  }
}
