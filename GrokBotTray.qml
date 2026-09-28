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
  // it reports the outcome via desktop notification.
  function runUpdate() {
    Quickshell.execDetached([updatePath, "run"])
  }

  Process {
    id: statusProc
    command: [root.ctlPath, "status"]

    stdout: StdioCollector {
      onStreamFinished: root.botState = text.trim()
    }
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
    contentWidth: menu.fittedContentWidth(Style.space(200))
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
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
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

      // Row: check & install update (external updater — app can't on Linux)
      Rectangle {
        id: updateRow
        width: menuColumn.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        color: "transparent"
        border.width: updateHover.hovered ? 1 : 0
        border.color: Color.popups.border

        Text {
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          text: "Check for updates"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        HoverHandler {
          id: updateHover
        }

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: {
            menu.open = false;
            root.runUpdate();
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
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
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
