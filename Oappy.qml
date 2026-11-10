import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Apps.js" as Apps

/*
 * Oappy lists the apps that have a window open and puts an X on each row.
 * Clicking the X quits that app.
 *
 * This is the mac "Force Quit Applications" window, as a panel.
 *
 * The list comes from Hyprland instead of the process table. An app is on the
 * list because it has a window on screen, which is what the mac window means by
 * "running". Apps.js groups the windows into apps and holds the parsing and the
 * kill script, so this file reads the list and draws it.
 *
 * The panel is an overlay rather than a bar popup, because it has to appear on
 * the focused monitor whether it was opened by the shortcut or by the bar icon.
 * OappyBar.qml is that icon, and it opens the panel through the same IPC call.
 */
Item {
  id: root

  // -- the shell's contract
  //
  // The shell calls open(payloadJson) on summon, close() on hide, and reads
  // `opened` to decide which way toggle() goes. Nothing here needs the payload.
  property bool opened: false

  // -- state
  property var apps: []
  property bool loadedOnce: false
  property string loadError: ""

  // The row the keyboard is on. A click is the ordinary way to use this, but
  // the panel is opened by a shortcut, so the list has to be walkable from the
  // keyboard as well. selectedKey is kept across refreshes so the list updating
  // under the cursor does not move the cursor to a different app.
  property int selectedIndex: 0
  property string selectedKey: ""
  property bool cursorActive: false

  // The apps whose windows are listed. A map keyed by app class, so opening one
  // app does not close another.
  property var expandedKeys: ({})

  // What the list draws: an app row per app, and a window row per window of an
  // app that is open. Apps.js builds it, so the keyboard and the drawing walk
  // the same list.
  readonly property var rows: Apps.buildRows(root.apps, root.expandedKeys)

  // Set while a kill is in flight, so a second click cannot start another one
  // and every X on the list shows the same busy state.
  property string busyKey: ""
  property string busyName: ""

  property string statusText: ""
  property bool statusIsError: false

  // Which monitor the panel opened on. Captured at open time so a later focus
  // change does not move a panel that is already in front of the user.
  property string targetScreenName: ""

  // A refresh asked for while a read was already in flight runs after it
  // instead of being dropped or started on top of it.
  property bool refreshPending: false
  property var pendingWindows: []

  // Live while the panel is open: an app started or closed behind the panel
  // shows up without reopening it.
  property int refreshIntervalMs: 2000

  // An oversized reply is cut off rather than collected whole. The list is a
  // few hundred bytes per window, so this limit only stops a runaway reply.
  property int outputLimit: 65536

  // -- the theme
  // The [menu] color tokens, the same ones the clipboard overlay uses. A theme
  // that styles the menu styles this panel too.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  property color danger: Commons.Color.urgent

  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md

  // -- geometry
  property int headerHeight: Style.space(46)
  property int footerHeight: Style.space(20)
  property int rowHeight: Math.max(Style.space(54), Style.font.title + Style.font.caption + Style.space(14))
  property int windowRowHeight: Math.max(Style.space(46), Style.font.body + Style.font.caption + Style.space(12))
  property int rowSpacing: Style.space(4)
  property int listMaxHeight: Style.space(400)
  property int emptyHeight: Style.space(110)
  property int cardWidth: Style.space(520)

  function rowHeightOf(row) {
    return row && row.kind === "window" ? root.windowRowHeight : root.rowHeight
  }

  readonly property int listHeight: {
    if (root.rows.length === 0) return root.emptyHeight
    var total = (root.rows.length - 1) * root.rowSpacing
    for (var index = 0; index < root.rows.length; index++) total += root.rowHeightOf(root.rows[index])
    return Math.min(total, root.listMaxHeight)
  }

  // The line under the title. A status outranks the count, because after a
  // click what happened matters more than how many rows there are.
  readonly property bool hasError: root.statusIsError || root.loadError !== ""

  readonly property string metaText: {
    if (root.statusText !== "") return root.statusText
    if (root.loadError !== "") return root.loadError
    if (!root.loadedOnce) return "Reading the open windows..."
    if (root.apps.length === 0) return "No app has a window open"
    return root.apps.length === 1 ? "1 app running" : root.apps.length + " apps running"
  }

  // Whether the monitor captured at open time still exists. When it does not,
  // every window matches rather than none, so the panel cannot open invisibly
  // on a screen that was just unplugged.
  readonly property bool targetScreenKnown: {
    if (root.targetScreenName === "") return false
    var screens = Quickshell.screens
    for (var index = 0; index < screens.length; index++) {
      var name = screens[index] && screens[index].name ? String(screens[index].name) : ""
      if (name === root.targetScreenName) return true
    }
    return false
  }

  // -- reading the list
  function refresh() {
    if (!root.opened) return
    if (root.busyKey !== "" || killProcess.running || closeProcess.running) return
    if (clientsProcess.running || commProcess.running) {
      root.refreshPending = true
      return
    }
    clientsProcess.buffer = ""
    clientsProcess.failure = ""
    clientsProcess.command = ["hyprctl", "clients", "-j"]
    clientsProcess.running = true
    clientsTimeout.restart()
  }

  function readComms(windows) {
    root.pendingWindows = windows
    var pids = Apps.pidsOfWindows(windows)
    if (pids.length === 0) {
      root.applyWindows(windows, ({}))
      return
    }
    commProcess.output = ""
    commProcess.command = ["ps", "-o", "pid=,comm=", "-p", pids.join(",")]
    commProcess.running = true
    commTimeout.restart()
  }

  function applyWindows(windows, commByPid) {
    root.pendingWindows = []
    root.apps = Apps.groupApps(windows, commByPid)
    root.loadedOnce = true
    root.loadError = ""
    root.pruneExpanded()
    root.syncSelection()
    // A successful read clears the result line, so the panel stops claiming
    // that something failed. An error stays until the next action or the next
    // open, because the failure is what the user needs to see.
    if (!root.statusIsError) root.statusText = ""
    if (root.refreshPending) {
      root.refreshPending = false
      root.refresh()
    }
  }

  function failRead(message) {
    root.loadedOnce = true
    root.loadError = Apps.sentence(message)
    if (root.refreshPending) {
      root.refreshPending = false
      root.refresh()
    }
  }

  function currentRow() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.rows.length) return null
    return root.rows[root.selectedIndex]
  }

  function syncSelection() {
    if (root.rows.length === 0) {
      root.selectedIndex = 0
      root.selectedKey = ""
      return
    }
    var index = -1
    if (root.selectedKey !== "") {
      for (var position = 0; position < root.rows.length; position++) {
        if (root.rows[position].key === root.selectedKey) {
          index = position
          break
        }
      }
    }
    if (index < 0) index = Math.min(root.selectedIndex, root.rows.length - 1)
    root.selectedIndex = Math.max(0, index)
    root.selectedKey = root.rows[root.selectedIndex].key
  }

  // Programmatic moves clamp, so collapsing a row cannot leave the cursor past
  // the end of the list. Arrow keys wrap, which is what select() is for.
  function selectRow(index) {
    if (root.rows.length === 0) return
    var clamped = Math.max(0, Math.min(index, root.rows.length - 1))
    root.selectedIndex = clamped
    root.selectedKey = root.rows[clamped].key
    root.cursorActive = true
  }

  function select(index) {
    if (root.rows.length === 0) return
    var wrapped = ((index % root.rows.length) + root.rows.length) % root.rows.length
    root.selectRow(wrapped)
  }

  function move(delta) {
    if (root.rows.length === 0) return
    root.select(root.selectedIndex + delta)
  }

  // -- one app open into its windows
  function isExpanded(appKey) {
    return root.expandedKeys[appKey] === true
  }

  function setExpanded(appKey, open) {
    var next = {}
    for (var key in root.expandedKeys) if (key !== appKey) next[key] = root.expandedKeys[key]
    if (open) next[appKey] = true
    root.expandedKeys = next
  }

  function toggleExpanded(appKey) {
    root.setExpanded(appKey, !root.isExpanded(appKey))
  }

  // An app that closed its windows, or went away, keeps no open state.
  function pruneExpanded() {
    var allowed = {}
    for (var index = 0; index < root.apps.length; index++) {
      if (root.apps[index].windowCount > 1) allowed[root.apps[index].key] = true
    }
    var next = {}
    for (var key in root.expandedKeys) if (allowed[key]) next[key] = true
    root.expandedKeys = next
  }

  function expandSelected() {
    var row = root.currentRow()
    if (!row || row.kind !== "app" || !row.canExpand) return
    if (!root.isExpanded(row.appKey)) {
      root.setExpanded(row.appKey, true)
      return
    }
    // Already open, so the next Right steps into the first window.
    root.selectRow(root.selectedIndex + 1)
  }

  function collapseSelected() {
    var row = root.currentRow()
    if (!row) return
    if (row.kind === "window") {
      var appIndex = -1
      for (var position = 0; position < root.rows.length; position++) {
        if (root.rows[position].kind === "app" && root.rows[position].appKey === row.appKey) {
          appIndex = position
          break
        }
      }
      root.setExpanded(row.appKey, false)
      if (appIndex >= 0) root.selectRow(appIndex)
      return
    }
    if (root.isExpanded(row.appKey)) root.setExpanded(row.appKey, false)
  }

  // -- quitting
  //
  // A window row and an app row do different things, on purpose.
  //
  // A window row closes its window through Hyprland, which is the same call
  // SUPER + W makes. The app decides what that means: it can save, prompt, or
  // close one window and keep the rest. Two windows of one process can be
  // closed one at a time this way.
  //
  // An app row is the last resort. It sends SIGTERM to every process behind the
  // app and SIGKILL to whatever is left, which is what the mac Force Quit button
  // does.
  function quitRow(row) {
    if (!row) return
    if (row.kind === "window") root.closeWindow(row)
    else root.forceQuitApp(row)
  }

  function closeWindow(row) {
    if (killProcess.running || closeProcess.running) return
    var command = Apps.closeWindowCommand(row.address)
    if (command === "") {
      root.statusIsError = true
      root.statusText = "This window has no address to close"
      return
    }
    root.busyKey = row.key
    root.busyName = row.name
    root.statusIsError = false
    root.statusText = "Closing " + row.name + "..."
    closeProcess.failure = ""
    closeProcess.command = ["hyprctl", "dispatch", command]
    closeProcess.running = true
    closeTimeout.restart()
  }

  function forceQuitApp(row) {
    if (killProcess.running || closeProcess.running) return
    // pidText is a plain string, so it crosses into the shell process without
    // being turned into a QVariantList. The list still works if a row was built
    // before pidText existed.
    var pids = row.pidText !== undefined && row.pidText !== "" ? row.pidText : row.app.pids
    var script = Apps.killScript(pids)
    if (script === "") {
      root.statusIsError = true
      root.statusText = "This app has no process to quit"
      return
    }
    root.busyKey = row.key
    root.busyName = row.app.name
    root.statusIsError = false
    root.statusText = "Force quitting " + row.app.name + "..."
    killProcess.command = ["/bin/sh", "-c", script]
    killProcess.running = true
    killTimeout.restart()
  }

  function quitSelected() {
    root.quitRow(root.currentRow())
  }

  // -- the shell's open/close
  function open(payloadJson) {
    var monitor = Hyprland.focusedMonitor
    root.targetScreenName = monitor ? String(monitor.name || "") : ""
    root.opened = true
    // A shortcut opens the panel, so the first row starts selected and the
    // arrow keys work without a click first.
    root.cursorActive = true
    root.selectedIndex = 0
    root.selectedKey = ""
    root.statusText = ""
    root.statusIsError = false
    root.loadError = ""
    root.refresh()
  }

  function close() {
    root.opened = false
    root.refreshPending = false
    root.statusText = ""
    root.statusIsError = false
    root.busyKey = ""
    root.busyName = ""
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // -- the windows Hyprland is showing
  Process {
    id: clientsProcess
    running: false
    property string buffer: ""
    property string failure: ""
    property bool timedOut: false

    // An empty split marker hands over raw chunks, so an oversized reply can be
    // cut off instead of being held whole by a line-buffered parser.
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (clientsProcess.buffer.length <= root.outputLimit) clientsProcess.buffer += chunk
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (clientsProcess.failure.length <= 4096) clientsProcess.failure += chunk
      }
    }

    onExited: function(code) {
      clientsTimeout.stop()
      var text = clientsProcess.buffer
      var failure = clientsProcess.failure
      var timedOut = clientsProcess.timedOut
      clientsProcess.buffer = ""
      clientsProcess.failure = ""
      clientsProcess.timedOut = false

      if (timedOut) {
        root.failRead("hyprctl did not answer in time.")
        return
      }
      if (code !== 0) {
        root.failRead(failure !== "" ? failure : "hyprctl exited with code " + code + ".")
        return
      }
      var windows = Apps.parseClients(text)
      if (windows === null) {
        root.failRead("hyprctl printed something this panel does not understand.")
        return
      }
      root.readComms(windows)
    }
  }

  Timer {
    id: clientsTimeout
    interval: 4000
    repeat: false
    onTriggered: {
      if (!clientsProcess.running) return
      clientsProcess.timedOut = true
      clientsProcess.signal(15)
    }
  }

  // The process names. A failed `ps` is not fatal. The rows fall back to the
  // window class, which is uglier but still names the app.
  Process {
    id: commProcess
    running: false
    property string output: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (commProcess.output.length <= 16384) commProcess.output += chunk
      }
    }
    onExited: function(code) {
      commTimeout.stop()
      var text = commProcess.output
      commProcess.output = ""
      root.applyWindows(root.pendingWindows, Apps.parseComms(text))
    }
  }

  Timer {
    id: commTimeout
    interval: 3000
    repeat: false
    onTriggered: {
      if (!commProcess.running) return
      commProcess.signal(15)
    }
  }

  // -- closing one window
  //
  // hyprctl answers "ok" or prints why it did not, so the reply is worth
  // reading rather than assuming the window went away.
  Process {
    id: closeProcess
    running: false
    property string failure: ""
    property bool timedOut: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (chunk.trim() !== "ok") closeProcess.failure = Apps.sentence(chunk)
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        closeProcess.failure = Apps.sentence(chunk)
      }
    }
    onExited: function(code) {
      closeTimeout.stop()
      var name = root.busyName
      var failure = closeProcess.failure
      var timedOut = closeProcess.timedOut
      closeProcess.failure = ""
      closeProcess.timedOut = false
      root.busyKey = ""
      root.busyName = ""

      if (timedOut) {
        root.statusIsError = true
        root.statusText = "Could not close " + name
        root.loadError = "hyprctl did not answer in time."
        return
      }
      if (code !== 0 || failure !== "") {
        root.statusIsError = true
        root.statusText = "Could not close " + name
        root.loadError = failure !== "" ? failure : "hyprctl exited with code " + code + "."
        return
      }
      root.statusIsError = false
      root.statusText = "Closed " + name
      settleTimer.restart()
    }
  }

  Timer {
    id: closeTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      if (!closeProcess.running) return
      closeProcess.timedOut = true
      closeProcess.signal(15)
    }
  }

  // -- the kill
  //
  // The script is in Apps.js so the signals and the grace period are readable
  // in one place. This only runs it and reports what happened.
  Process {
    id: killProcess
    running: false
    property bool timedOut: false
    onExited: function(code) {
      killTimeout.stop()
      var timedOut = killProcess.timedOut
      var name = root.busyName
      killProcess.timedOut = false
      root.busyKey = ""
      root.busyName = ""

      if (timedOut) {
        root.statusIsError = true
        root.statusText = "Could not quit " + name
        root.loadError = "The kill did not finish in time."
        return
      }
      root.statusIsError = false
      root.statusText = "Quit " + name
      // Hyprland needs a moment to drop the window, so the refresh that shows
      // the row gone waits for it rather than reading the list mid-quit and
      // leaving the row on screen.
      settleTimer.restart()
    }
  }

  Timer {
    id: killTimeout
    interval: 10000
    repeat: false
    onTriggered: {
      if (!killProcess.running) return
      killProcess.timedOut = true
      killProcess.signal(15)
    }
  }

  Timer {
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalMs
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  // One overlay per monitor, drawn on the one the shortcut was pressed on.
  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: panelWindow
      required property var modelData

      readonly property string screenName: panelWindow.modelData && panelWindow.modelData.name
        ? String(panelWindow.modelData.name) : ""
      readonly property bool onTarget: root.targetScreenKnown
        ? panelWindow.screenName === root.targetScreenName
        : true

      screen: panelWindow.modelData
      visible: root.opened && panelWindow.onTarget
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      WlrLayershell.namespace: "omarchy-oappy"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: panelWindow.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // Focus follows visibility. The shortcut opens the panel, so the keys
      // have to land in it without a click. The first call can arrive before
      // the layer surface is mapped, which drops it silently, so the timer asks
      // again once the window exists.
      onVisibleChanged: {
        if (!visible) return
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        focusRetry.restart()
      }

      Timer {
        id: focusRetry
        interval: 120
        repeat: false
        onTriggered: {
          if (panelWindow.visible) keyCatcher.forceActiveFocus()
        }
      }

      Rectangle {
        anchors.fill: parent
        color: root.scrim
      }

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }

      BorderSurface {
        id: card
        width: Math.min(root.cardWidth, panelWindow.width - Style.gapsOut * 2)
        height: Math.min(contentColumn.implicitHeight + card.contentTopInset + card.contentBottomInset,
          panelWindow.height - Style.gapsOut * 2)
        radius: root.cornerRadius
        anchors.centerIn: parent
        color: root.background
        borderSpec: root.borderSpec
        padding: root.contentMargin
        clip: true

        MouseArea { anchors.fill: parent; onClicked: {} }

        Item {
          id: keyCatcher
          anchors.fill: parent
          focus: true

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              root.move(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              root.move(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Right) {
              root.expandSelected()
              event.accepted = true
            } else if (event.key === Qt.Key_Left) {
              root.collapseSelected()
              event.accepted = true
            } else if (event.key === Qt.Key_Home) {
              root.selectRow(0)
              event.accepted = true
            } else if (event.key === Qt.Key_End) {
              root.selectRow(root.rows.length - 1)
              event.accepted = true
            } else if (event.key === Qt.Key_PageUp) {
              root.move(-5)
              event.accepted = true
            } else if (event.key === Qt.Key_PageDown) {
              root.move(5)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Delete) {
              root.quitSelected()
              event.accepted = true
            } else if (event.key === Qt.Key_R && event.modifiers === Qt.NoModifier) {
              root.refresh()
              event.accepted = true
            }
          }
        }

        Column {
          id: contentColumn
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: root.contentSpacing

          // -- header
          Item {
            width: parent.width
            height: root.headerHeight

            Column {
              anchors.left: parent.left
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Oappy"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.metaText
                color: root.hasError ? root.danger : root.foreground
                opacity: root.hasError ? 1.0 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Button {
              id: refreshButton
              // Same right margin and size as the X buttons on the rows, so the
              // two sit in one column instead of two nearly equal ones.
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(34)
              height: Style.space(30)
              bordered: true
              text: "\uf021"
              tooltipText: "Read the list again"
              onClicked: root.refresh()
            }
          }

          // -- the list
          Item {
            width: parent.width
            height: root.listHeight
            clip: true

            Flickable {
              id: list
              anchors.fill: parent
              contentWidth: width
              contentHeight: rowsColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: rowsColumn
                width: list.width
                spacing: root.rowSpacing

                Repeater {
                  model: root.rows

                  delegate: Item {
                    id: rowItem
                    required property var modelData
                    required property int index

                    readonly property var row: rowItem.modelData
                    readonly property bool isApp: rowItem.row.kind === "app"
                    readonly property bool isCursor: root.cursorActive && rowItem.index === root.selectedIndex
                    readonly property bool isBusy: root.busyKey !== "" && root.busyKey === rowItem.row.key
                    readonly property bool isOpen: rowItem.isApp && rowItem.row.expanded

                    width: rowsColumn.width
                    height: root.rowHeightOf(rowItem.row)

                    Rectangle {
                      anchors.fill: parent
                      radius: root.cornerRadius
                      color: rowItem.isCursor
                        ? root.selectedBackground
                        : (rowMouse.containsMouse ? Util.alpha(root.foreground, 0.06) : "transparent")
                    }

                    MouseArea {
                      id: rowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectRow(rowItem.index)
                    }

                    // The arrow that opens an app into its windows. An app with
                    // one window has nothing to list, so it gets no arrow.
                    Item {
                      id: chevron
                      visible: rowItem.isApp && rowItem.row.canExpand
                      width: Style.space(16)
                      height: parent.height
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(6)

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "\uf054"
                        rotation: rowItem.isOpen ? 90 : 0
                        color: rowItem.isCursor ? root.selectedText : root.foreground
                        opacity: 0.7
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleExpanded(rowItem.row.appKey)
                      }
                    }

                    Column {
                      anchors.left: rowItem.isApp ? chevron.right : parent.left
                      anchors.leftMargin: rowItem.isApp ? Style.space(4) : Style.space(30)
                      anchors.right: quitButton.left
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: rowItem.row.name
                        color: rowItem.isCursor ? root.selectedText : root.foreground
                        opacity: rowItem.isApp ? 1.0 : 0.9
                        font.family: root.fontFamily
                        font.pixelSize: rowItem.isApp ? Style.font.title : Style.font.body
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: rowItem.row.detail
                        color: rowItem.isCursor ? root.selectedText : root.foreground
                        opacity: 0.7
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    // The X quits what the row names. On an app row that is the
                    // whole app, on a window row that is the one process behind
                    // that window.
                    Button {
                      id: quitButton
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(34)
                      height: Style.space(30)
                      bordered: true
                      enabled: root.busyKey === ""
                      text: rowItem.isBusy ? "..." : "\uf00d"
                      tooltipText: rowItem.isApp
                        ? "Force quit " + rowItem.row.name + ", and every process behind it"
                        : "Close this window, the way SUPER + W does"
                      onClicked: root.quitRow(rowItem.row)
                    }
                  }
                }
              }
            }

            // The list is empty because no window is open, or because the last
            // read failed. Either way the reason goes where the rows would be.
            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              spacing: Style.space(8)
              visible: root.rows.length === 0

              Text {
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                text: root.loadError !== "" ? "󰅚" : "󰒄"
                color: root.loadError !== "" ? root.danger : root.foreground
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: root.loadError !== ""
                  ? root.loadError
                  : (root.loadedOnce ? "No app has a window open" : "Reading the open windows...")
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

          }

          // -- footer
          Text {
            width: parent.width
            height: root.footerHeight
            textFormat: Text.PlainText
            text: "Esc closes · ↑ ↓ select · ← → windows · Enter quits"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
          }
        }
      }
    }
  }
}
