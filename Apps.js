// Pure helpers for Oappy.
//
// Nothing here touches the system. The QML file runs the processes and passes
// their output to these functions, which build the rows the panel draws. The
// parsing and the grouping stay here so one file answers which apps have a row
// and which pids the X sends a signal to.

// How long a force quit waits for a polite exit before it sends SIGKILL. The
// wait leaves an app enough time to close its window and save.
var TERM_GRACE_SECONDS = 1.5

// One line of text that is safe to draw and short enough to fit.
//
// Titles and class names come from other programs, so control characters and
// line breaks are dropped rather than passed to a renderer. A line break
// becomes a space so a wrapped title reads as one line instead of two words
// glued together.
function clean(value, limit) {
  var source = String(value === undefined || value === null ? "" : value)
  var out = ""
  for (var index = 0; index < source.length && out.length < limit; index++) {
    var code = source.charCodeAt(index)
    if (code === 10 || code === 13 || code === 9) {
      if (out !== "" && !/\s$/.test(out)) out += " "
    } else if (code >= 32 && code !== 127) {
      out += source[index]
    }
  }
  return out.trim()
}

function capitalize(value) {
  var text = clean(value, 80)
  if (text === "") return ""
  return text.charAt(0).toUpperCase() + text.slice(1)
}

// The error lines hyprctl and kill print are already sentences. This joins
// their lines and ends the result with a full stop, so the panel can show a
// detail line without inventing punctuation.
function sentence(value) {
  var lines = String(value === undefined || value === null ? "" : value).split(/\r?\n/)
  var parts = []
  for (var index = 0; index < lines.length; index++) {
    var line = lines[index].trim()
    if (line !== "") parts.push(line)
  }
  if (parts.length === 0) return ""
  var text = parts.join(" ")
  return /[.!?]$/.test(text) ? text : text + "."
}

// -- reading hyprctl
//
// `hyprctl clients -j` is the list of windows Hyprland is showing. One window
// per entry, and every entry carries the pid of the process that owns it, which
// is the thing the X button needs.
//
// Returns null when the reply is not a list, so the caller can tell "nothing is
// running" (an empty array) apart from "hyprctl printed something else".
function parseClients(raw) {
  var parsed = null
  try {
    parsed = JSON.parse(String(raw === undefined || raw === null ? "" : raw).trim() || "[]")
  } catch (error) {
    return null
  }
  if (!Array.isArray(parsed)) return null

  var windows = []
  for (var index = 0; index < parsed.length; index++) {
    var client = parsed[index] || {}
    var pid = Number(client.pid)
    // A window without a usable pid cannot be quit from here, and pid 0 and 1
    // are not apps. Dropping the entry is what keeps a stray row from turning
    // its X into a kill of something that is not the row.
    if (!isFinite(pid) || pid <= 1) continue

    var workspace = ""
    if (client.workspace && client.workspace.name !== undefined && client.workspace.name !== null) {
      workspace = String(client.workspace.name)
    } else if (client.workspace && client.workspace.id !== undefined && client.workspace.id !== null) {
      workspace = String(client.workspace.id)
    }

    windows.push({
      address: clean(client.address, 40),
      pid: Math.round(pid),
      title: clean(client.title, 200),
      className: clean(client["class"] || client.initialClass, 120),
      workspace: clean(workspace, 40)
    })
  }
  return windows
}

// `ps -o pid=,comm=` answers with one "pid command" line per process. The
// command name is usually clearer than the window class. A Chromium app reports
// `brave-<hash>-Default` as its class and `brave` as its process.
function parseComms(raw) {
  var comms = {}
  var lines = String(raw === undefined || raw === null ? "" : raw).split(/\r?\n/)
  for (var index = 0; index < lines.length; index++) {
    var match = lines[index].match(/^\s*(\d+)\s+(.+?)\s*$/)
    if (!match) continue
    comms[Number(match[1])] = clean(match[2], 80)
  }
  return comms
}

// -- rows
//
// One row per app, not per window. Two Brave windows are one thing to quit, and
// a row per window would leave the app running after one click. Hyprland uses
// the window class to identify an app, so this groups by class.
function groupApps(windows, commByPid) {
  var list = asList(windows)
  var groups = []
  var byKey = {}

  for (var index = 0; index < list.length; index++) {
    var window = list[index]
    if (!window) continue
    var key = window.className !== "" ? window.className : "window:" + window.address
    var group = byKey[key]
    if (!group) {
      group = { key: key, className: window.className, windows: [], pids: [] }
      byKey[key] = group
      groups.push(group)
    }
    group.windows.push(window)
    if (group.pids.indexOf(window.pid) < 0) group.pids.push(window.pid)
  }

  for (var position = 0; position < groups.length; position++) {
    var entry = groups[position]
    entry.pids.sort(function(a, b) { return a - b })
    entry.pidText = entry.pids.join(" ")
    entry.windowCount = entry.windows.length
    entry.name = appName(entry, commByPid)
    entry.detail = appDetail(entry)
  }

  groups.sort(function(a, b) {
    var left = a.name.toLowerCase()
    var right = b.name.toLowerCase()
    if (left !== right) return left < right ? -1 : 1
    return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0)
  })

  return groups
}

function appName(group, commByPid) {
  var fromClass = prettyClass(group.className)
  var comm = usableComm(group.pids, commByPid)
  if (comm === "") return fromClass
  // An interpreter is not the app. Obsidian reports `electron` as its process,
  // and a row that says Electron matches no window.
  if (isGenericComm(comm)) return fromClass
  // A class that says the same thing with its own capitals wins. "T3Code" reads
  // better than the process name "T3code".
  if (fromClass.toLowerCase() === comm.toLowerCase()) return fromClass
  return capitalize(comm)
}

function usableComm(pids, commByPid) {
  if (!commByPid) return ""
  for (var index = 0; index < pids.length; index++) {
    var comm = commByPid[pids[index]]
    if (comm) return comm
  }
  return ""
}

// Process names that name a runtime rather than an app. When one of these is
// all `ps` has to offer, the window class is the better answer.
var GENERIC_COMMS = [
  "electron", "electron.exe", "node", "nodejs", "java", "javaw",
  "python", "python2", "python3", "ruby", "perl", "mono", "dotnet",
  "wine", "wine64", "wine-preloader", "sh", "bash", "zsh", "fish",
  "Xwayland"
]

function isGenericComm(comm) {
  var name = String(comm === undefined || comm === null ? "" : comm).toLowerCase()
  for (var index = 0; index < GENERIC_COMMS.length; index++) {
    if (GENERIC_COMMS[index].toLowerCase() === name) return true
  }
  return false
}

// The fallback when `ps` is unavailable: the class itself, tidied up.
function prettyClass(className) {
  var text = clean(className, 120)
  if (text === "") return "Unknown app"

  // A reverse-DNS class ("md.obsidian.Obsidian") ends with the name people use.
  var segments = text.split(".")
  var tail = segments.length > 1 ? segments[segments.length - 1] : text
  if (tail === "") tail = text

  // Chromium apps put the profile in the class: "brave-<hash>-Default".
  tail = tail.replace(/-(Default|Personal|Work|Profile \d+)$/i, "")
  tail = tail.replace(/-[a-z]{16,}$/i, "")

  return capitalize(tail)
}

// The rows the panel draws, in display order. An app row comes first, and its
// window rows follow while the app is open. The keyboard walks this list, so a
// window row is reachable with the arrow keys the same way an app row is.
function buildRows(groups, expandedKeys) {
  var list = asList(groups)
  var expanded = expandedKeys || {}
  var rows = []
  for (var index = 0; index < list.length; index++) {
    var app = list[index]
    var canExpand = app.windowCount > 1
    var isOpen = canExpand && expanded[app.key] === true
    rows.push({
      kind: "app",
      key: "app:" + app.key,
      appKey: app.key,
      app: app,
      window: null,
      address: "",
      canExpand: canExpand,
      expanded: isOpen,
      name: app.name,
      detail: app.detail,
      pidText: app.pidText
    })
    if (!isOpen) continue

    var windows = sortedWindows(app.windows)
    for (var position = 0; position < windows.length; position++) {
      var window = windows[position]
      rows.push({
        kind: "window",
        key: "window:" + app.key + "::" + window.address,
        appKey: app.key,
        app: app,
        window: window,
        canExpand: false,
        expanded: false,
        name: window.title === "" ? "Untitled window" : window.title,
        detail: windowDetail(window),
        // A window row closes its window through Hyprland, so it needs the
        // address, not the pid.
        address: window.address,
        pidText: ""
      })
    }
  }
  return rows
}

// Windows keep the same order across reads, so a row does not swap places under
// the cursor while the list re-reads.
function sortedWindows(windows) {
  var list = asList(windows).slice()
  list.sort(function(a, b) {
    var left = String(a.title || "").toLowerCase()
    var right = String(b.title || "").toLowerCase()
    if (left !== right) return left < right ? -1 : 1
    return String(a.address) < String(b.address) ? -1 : 1
  })
  return list
}

// The line under a window row. It says which workspace the window is on, so two
// windows of one app are told apart by something other than their order.
function windowDetail(window) {
  return window.workspace === "" ? "" : "workspace " + window.workspace
}

// The Hyprland call that closes one window, the same call SUPER + W makes. It
// asks the app to close that window and leaves the app running, so two windows
// of one process can be closed one at a time.
function closeWindowCommand(address) {
  var target = clean(address, 40)
  if (target === "") return ""
  return "hl.dsp.window.close({ window = \"address:" + target + "\" })"
}

// The line under the app name. One window says what it is; several say how many
// and then name the first, because "3 windows" alone does not say which app you
// are about to quit when two of them share a class.
function appDetail(group) {
  var title = ""
  for (var index = 0; index < group.windows.length; index++) {
    if (group.windows[index].title !== "") {
      title = group.windows[index].title
      break
    }
  }
  var count = group.windowCount === 1 ? "1 window" : group.windowCount + " windows"
  return title === "" ? count : count + " · " + title
}

// Every pid behind the rows, for one `ps` call rather than one per app.
function pidsOfWindows(windows) {
  var list = asList(windows)
  var seen = {}
  var pids = []
  for (var index = 0; index < list.length; index++) {
    var pid = Number(list[index] && list[index].pid)
    if (!isFinite(pid) || pid <= 1 || seen[pid]) continue
    seen[pid] = true
    pids.push(Math.round(pid))
  }
  pids.sort(function(a, b) { return a - b })
  return pids
}

// A list that came back out of a QML property is a QVariantList, and
// Array.isArray() says no to that. Reading .length and the indexes works for
// both, so a real list cannot be read as empty.
function asList(value) {
  if (value === undefined || value === null) return []
  if (typeof value === "string") return value.split(/[\s,]+/)
  var out = []
  var length = value.length === undefined ? 0 : Number(value.length)
  for (var index = 0; index < length; index++) out.push(value[index])
  return out
}

// -- quitting
//
// A force quit that starts with SIGKILL throws away whatever the app had open,
// which is why the mac window is a last resort and not the close button. So the
// panel asks first. It sends SIGTERM, waits a moment for the app to save and
// exit, then sends SIGKILL to what still runs. An app that answers SIGTERM quits
// cleanly. A wedged app is killed anyway.
//
// pid 0 and 1 are refused in the script itself as well as in the rows, so a
// bad list cannot take the machine down from here.
function killScript(pids) {
  var list = asList(pids)
  var safe = []
  for (var index = 0; index < list.length; index++) {
    var pid = Number(list[index])
    if (!isFinite(pid) || pid <= 1) continue
    safe.push(String(Math.round(pid)))
  }
  if (safe.length === 0) return ""

  var joined = safe.join(" ")
  return "for pid in " + joined + "; do kill -TERM \"$pid\" 2>/dev/null; done\n"
    + "sleep " + TERM_GRACE_SECONDS + "\n"
    + "for pid in " + joined + "; do kill -KILL \"$pid\" 2>/dev/null; done\n"
    + "exit 0\n"
}
