import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The paired phone on this network, left of the clock: its battery in the bar and a
// popup with ring, clipboard, files and send. Hidden while no paired phone is nearby
// or linksyd isn't running. Nearby, not connected: Linksy only connects on demand and
// closes a link after 60 s idle, so "connected" comes and goes; actions dial as needed.
//
// Reads linksyd's local socket (newline-delimited JSON, see linksy-ipc): the
// `devices` reply, refreshed whenever an event arrives. That reply's shape is
// Linksy's internal interface, so on every Linksy version it hasn't seen yet the
// widget runs check.sh; when Linksy changed something it relies on, it shows "!"
// and what changed instead of guessing. Actions go through the documented `linksy` CLI.
Panel {
  id: root
  moduleName: "io.github.shinobix9x.linksy"
  ipcTarget: "io.github.shinobix9x.linksy"

  readonly property string actions: String(Qt.resolvedUrl("actions.sh")).replace(/^file:\/\//, "")
  readonly property string socketPath: (Quickshell.env("LINKSY_SOCKET") || "")
    || Quickshell.env("XDG_RUNTIME_DIR") + "/linksyd.sock"

  readonly property string checkScript: String(Qt.resolvedUrl("check.sh")).replace(/^file:\/\//, "")

  property var devices: []
  property int nextId: 1
  property int devicesRequest: 0
  property int statusRequest: 0

  // check.sh's verdict on the running Linksy: {version, fits, unknown, problems}
  property string linksyVersion: ""
  property string checkedVersion: ""
  property var compat: null
  readonly property bool broken: compat !== null && compat.fits === false && compat.unknown !== true
  readonly property string updateCommand: "omarchy plugin update " + moduleName
  property bool ringing: false
  // An outgoing or incoming transfer in progress: 0..1, or -1
  property real transfer: -1

  // The first nearby (or connected), paired phone; any such device when no phone is
  readonly property var livePhone: {
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (!d || (d.nearby !== true && d.connected !== true) || d.trusted !== true || !d.device) continue
      if (d.device.kind === "phone") return d
      if (!fallback) fallback = d
    }
    return fallback
  }
  // Android stops announcing itself now and then, so "nearby" drops out for a minute at
  // a time: keep showing the last phone until it has been gone for leaveGrace
  property string heldId: ""
  readonly property var phone: {
    if (livePhone) return livePhone
    if (!heldId) return null
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].device && devices[i].device.id === heldId) return devices[i]
    return null
  }
  onLivePhoneChanged: {
    if (livePhone) {
      heldId = String(livePhone.device.id)
      leaveGrace.stop()
    } else if (heldId) {
      leaveGrace.restart()
    }
  }
  Timer { id: leaveGrace; interval: 180000; onTriggered: root.heldId = "" }
  readonly property string phoneId: phone ? String(phone.device.id) : ""
  readonly property string phoneName: phone ? String(phone.device.name || "Phone") : ""
  readonly property var battery: phone && phone.battery ? phone.battery : null
  readonly property bool lowBattery: battery !== null && battery.level <= 15 && !battery.charging

  readonly property string batteryText: battery ? battery.level + "%" + (battery.charging ? " 󱐋" : "") : ""
  readonly property string barText: {
    var parts = ["󰄜"]
    if (broken) parts.push("!")
    if (batteryText) parts.push(batteryText)
    if (transfer >= 0) parts.push("󰓢 " + Math.round(transfer * 100) + "%")
    return parts.join(" ")
  }

  function request(cmd) {
    if (!sock.connected) return 0
    var id = nextId++
    sock.write(JSON.stringify({ id: id, cmd: cmd }) + "\n")
    sock.flush()
    return id
  }

  function refresh() {
    devicesRequest = request("devices")
  }

  // force: test again instead of reusing this version's earlier result
  function runCheck(force) {
    if (checkProc.running) return
    checkProc.command = ["bash", checkScript, "--json", "--notify"].concat(force ? [] : ["--cached"])
    checkProc.running = true
  }

  function handle(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }

    if (msg.id !== undefined && msg.id === statusRequest) {
      var v = msg.ok && msg.ok.version ? String(msg.ok.version) : ""
      // A version not checked yet (first start, or linksyd restarted after an update)
      if (v !== checkedVersion) {
        linksyVersion = v
        runCheck(false)
      }
      return
    }

    if (msg.id !== undefined && msg.id === devicesRequest) {
      // Anything but a list means Linksy's reply changed: show nothing rather than guess
      devices = Array.isArray(msg.ok) ? msg.ok : []
      return
    }

    var ev = msg.event
    if (!ev) return
    if (ev.type === "transfer_progress" && ev.total > 0) {
      transfer = Math.min(1, ev.bytes / ev.total)
      return
    }
    if (ev.type === "transfer_complete" || ev.type === "transfer_failed") transfer = -1
    if (ev.type === "ring" && ev.on === false) ringing = false
    debounce.restart()
  }

  function act(command) {
    root.close()
    root.bar.run(command)
  }

  Socket {
    id: sock
    path: root.socketPath
    connected: true
    parser: SplitParser { onRead: function(line) { root.handle(line) } }
    onConnectedChanged: {
      if (connected) {
        root.statusRequest = root.request("status")
        root.refresh()
      } else {
        root.devices = []
        root.transfer = -1
        reconnect.start()
      }
    }
  }

  // linksyd restarted or not started yet: try again
  Timer { id: reconnect; interval: 5000; onTriggered: { sock.connected = false; sock.connected = true } }
  Timer { id: debounce; interval: 300; onTriggered: root.refresh() }
  // Battery reports between events, and a missed event, catch up here
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: sock.connected ? root.refresh() : reconnect.start()
  }

  // On a hot reload the socket can connect before onConnectedChanged is wired up
  Component.onCompleted: Qt.callLater(function() {
    if (sock.connected) {
      root.statusRequest = root.request("status")
      root.refresh()
    } else {
      reconnect.start()
    }
  })

  Process {
    id: checkProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result
        try { result = JSON.parse(String(text).trim()) } catch (e) { return }
        root.compat = result
        // "Can't tell" (linksyd still starting): ask again on the next connection
        if (result.unknown !== true) root.checkedVersion = String(result.version || root.linksyVersion)
      }
    }
  }

  onPhoneChanged: if (!phone) { ringing = false; if (opened && !broken) close() }

  // Shown while a phone is around, and while Linksy changed what the widget relies on
  visible: phone !== null || broken
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? (root.broken ? "󰄜!" : "󰄜") : root.barText
    // Urgent color while the battery is low or the widget doesn't fit Linksy anymore
    active: root.lowBattery || root.broken
    tooltipText: root.broken
      ? "Linksy " + root.compat.version + " changed what this widget relies on. Update: " + root.updateCommand
      : ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.act("uwsm-app -- linksy-open")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Linksy changed what this widget relies on ----------
        Column {
          visible: root.broken
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "LINKSY " + (root.compat ? root.compat.version : "") + " CHANGED"
            foreground: root.bar.urgent
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.compat ? root.compat.problems : []
            Text {
              required property var modelData
              width: parent.width
              textFormat: Text.PlainText
              text: "• " + modelData
              wrapMode: Text.Wrap
              color: root.bar.foreground
              opacity: 0.8
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "This widget may show wrong or no data until it's updated:\n" + root.updateCommand
            wrapMode: Text.Wrap
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ActionButton {
            visible: true
            iconText: "󰑐"
            text: checkProc.running ? "Checking…" : "Check again"
            enabled: !checkProc.running
            onClicked: root.runCheck(true)
          }
        }

        PanelSeparator { visible: root.broken && root.phone !== null; foreground: root.bar.foreground }

        // ---------- Hero: phone ----------
        Item {
          visible: root.phone !== null
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroBattery.implicitHeight)

          Text {
            id: heroIcon
            text: "󰄜"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroBattery.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.phoneName
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: {
                var p = root.phone
                var parts = [p && p.connected ? "CONNECTED" : p && p.nearby ? "NEARBY" : "JUST SEEN"]
                if (root.battery) parts.push(root.battery.charging ? "CHARGING" : "ON BATTERY")
                return parts.join(" · ")
              }
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }

          Text {
            id: heroBattery
            text: root.battery ? root.battery.level + "%" : ""
            color: root.lowBattery ? root.bar.urgent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSeparator { visible: root.phone !== null; foreground: root.bar.foreground }

        ActionButton {
          iconText: root.ringing ? "󰂛" : "󰂞"
          text: root.ringing ? "Stop ringing" : "Ring phone"
          onClicked: {
            root.bar.run("linksy ring '" + root.phoneId + "'" + (root.ringing ? " --stop" : ""))
            root.ringing = !root.ringing
          }
        }
        ActionButton {
          iconText: "󰅍"
          text: "Send clipboard"
          onClicked: root.act("'" + root.actions + "' clip '" + root.phoneId + "'")
        }
        ActionButton {
          iconText: "󰈔"
          text: "Send files…"
          onClicked: root.act("'" + root.actions + "' send '" + root.phoneId + "'")
        }
        ActionButton {
          iconText: "󰉋"
          text: "Browse phone files"
          onClicked: root.act("linksy files '" + root.phoneId + "'")
        }
        ActionButton {
          visible: true
          iconText: "󰏌"
          text: "Open Linksy"
          onClicked: root.act("uwsm-app -- linksy-open")
        }
      }
    }
  }

  // Phone actions need a phone; buttons that don't, set visible: true
  component ActionButton: Button {
    visible: root.phone !== null
    width: parent.width
    fontSize: Style.font.bodySmall
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
  }
}
