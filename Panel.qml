import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Thermal Grizzly WireView Pro II: GPU connector watts in the bar; per-pin
// current, temperatures and faults in the popup. Reads the hwmon device that
// the wireview_hwmon module registers (fed by wireviewd), so it needs no
// access to the serial port or the daemon's command socket.
Panel {
  id: root
  moduleName: "martinmose.wireview"
  ipcTarget: "martinmose.wireview"

  property var snap: null
  // Fault bits already notified, so a fault raises one notification when it
  // appears rather than one per poll. Cleared bits re-arm.
  property int notifiedFaults: 0

  readonly property bool online: snap !== null
  readonly property bool alarming: online && (snap.faultStatus !== 0 || snap.maxA > Model.PIN_RATED_A)
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!readProc.running) readProc.running = true
  }

  function openLiveView() {
    close()
    if (bar) bar.run("omarchy-launch-or-focus-tui wireviewctl top")
  }

  // A bar exists per monitor; only the first instance notifies.
  function isLeader() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return items.length === 0 || items[0] === root
  }

  function notifyFaults(mask) {
    var fresh = mask & ~notifiedFaults
    notifiedFaults = mask
    if (!fresh || !bar || !isLeader()) return
    bar.run("notify-send -u critical -a WireView "
      + bar.shellQuote("GPU power connector fault") + " "
      + bar.shellQuote(Model.faultNames(fresh).join(", ")))
  }

  // sysfs reads do not block, but a stuck child would leave refresh() a
  // no-op for the rest of the session.
  Timer {
    id: readWatchdog
    interval: 3000
    onTriggered: if (readProc.running) readProc.running = false
  }

  Process {
    id: readProc
    command: ["/usr/bin/bash", "-c", Model.READ_SCRIPT]
    onRunningChanged: {
      if (running) readWatchdog.restart()
      else readWatchdog.stop()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.snap = Model.snapshot(Model.parse(text))
        root.notifyFaults(root.snap ? root.snap.faultStatus : 0)
      }
    }
  }

  Timer {
    interval: root.opened ? 1000 : 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var icon = root.alarming ? Model.ICON_FAULT : Model.ICON
      if (!root.online || vertical) return icon
      return icon + " " + Math.round(root.snap.watts) + "W"
    }
    active: root.alarming
    dimmed: !root.online
    tooltipText: root.opened ? "" : Model.tooltip(root.snap)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.openLiveView()
      else root.toggle()
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      PanelHero {
        foreground: root.fg
        fontFamily: root.fontFamily
        title: "GPU power"
        meta: Model.status(root.snap)
        metaOpacity: 1
        iconComponent: Component {
          Text {
            textFormat: Text.PlainText
            text: root.alarming ? Model.ICON_FAULT : Model.ICON
            color: root.alarming ? Color.urgent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
        trailingControl: Component {
          Text {
            textFormat: Text.PlainText
            text: root.online ? root.snap.watts.toFixed(1) + " W" : "—"
            color: root.alarming ? Color.urgent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        visible: root.online
        text: root.online
          ? root.snap.amps.toFixed(2) + " A · " + root.snap.volts.toFixed(2) + " V avg"
            + (root.snap.capW > 0 ? " · PSU cap " + Math.round(root.snap.capW) + " W" : "")
          : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        visible: !root.online
        wrapMode: Text.Wrap
        text: "No fresh readings. Check that wireviewd is running:\nsystemctl status wireviewd"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      PanelSeparator { visible: root.online; foreground: root.fg }

      Column {
        width: parent.width
        visible: root.online
        spacing: Style.space(6)

        PanelSectionHeader { text: "Pins"; foreground: root.fg; fontFamily: root.fontFamily }

        Repeater {
          model: root.online ? root.snap.pins : []
          delegate: PinRow { width: column.width }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.online
            ? "Spread " + root.snap.spreadA.toFixed(2) + " A · highest " + root.snap.pins[root.snap.maxPin].label
            : ""
          color: root.online && (root.snap.faultStatus & Model.FAULT_CURRENT_IMBALANCE) ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator { visible: root.online && root.snap.temps.length > 0; foreground: root.fg }

      Column {
        width: parent.width
        visible: root.online && root.snap.temps.length > 0
        spacing: Style.space(6)

        PanelSectionHeader { text: "Temperatures"; foreground: root.fg; fontFamily: root.fontFamily }

        Grid {
          width: parent.width
          columns: 2
          rowSpacing: Style.space(4)

          Repeater {
            model: root.online ? root.snap.temps : []
            delegate: Item {
              required property var modelData
              width: column.width / 2
              height: tempLabel.implicitHeight

              Text {
                id: tempLabel
                textFormat: Text.PlainText
                text: modelData.label
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                textFormat: Text.PlainText
                text: modelData.celsius.toFixed(1) + "°C"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }
      }

      PanelSeparator { visible: root.online; foreground: root.fg }

      Item {
        width: parent.width
        visible: root.online
        implicitHeight: Math.max(footerText.implicitHeight, liveButton.height)

        Column {
          id: footerText
          anchors.left: parent.left
          anchors.right: liveButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.online && root.snap.faultLog !== 0
            wrapMode: Text.Wrap
            text: root.online && root.snap.faultLog
              ? "Logged: " + Model.faultNames(root.snap.faultLog).join(", ")
              : ""
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: {
              if (!root.online) return ""
              var parts = []
              if (root.snap.energyWh >= 0) parts.push(root.snap.energyWh.toFixed(2) + " Wh since wireviewd start")
              if (root.snap.fanPercent >= 0) parts.push("fan " + root.snap.fanPercent + "%")
              return parts.join(" · ")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        PanelActionButton {
          id: liveButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: ""  // nf-fa-window_maximize
          tooltipText: "Live view (wireviewctl top)"
          foreground: root.fg
          onClicked: root.openLiveView()
        }
      }
    }
  }

  component PinRow: Item {
    id: pinRow
    required property var modelData
    required property int index
    readonly property bool over: modelData.amps > Model.PIN_RATED_A
    readonly property bool highest: root.online && index === root.snap.maxPin

    implicitHeight: Math.max(pinLabel.implicitHeight, Style.space(16))

    Text {
      id: pinLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(44)
      textFormat: Text.PlainText
      text: pinRow.modelData.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Rectangle {
      id: track
      anchors.left: pinLabel.right
      anchors.right: ampsText.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(6)
      radius: height / 2
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: Math.max(parent.height, parent.width * Math.min(1, pinRow.modelData.amps / Model.PIN_RATED_A))
        color: pinRow.over ? Color.urgent : (pinRow.highest ? Color.accent : root.fg)
        opacity: pinRow.over || pinRow.highest ? 1 : 0.7

        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
      }
    }

    Text {
      id: ampsText
      anchors.right: wattsText.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: pinRow.modelData.amps.toFixed(2) + " A"
      color: pinRow.over ? Color.urgent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: pinRow.highest
    }

    Text {
      id: wattsText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: pinRow.modelData.watts.toFixed(1) + " W"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
