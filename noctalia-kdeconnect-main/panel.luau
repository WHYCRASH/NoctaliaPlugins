--!nonstrict
-- KDE Connect [[panel]] entry — the device panel.
--
-- Reads the service's "kdec" snapshot and renders one of:
--   * error cards   (busctl missing / daemon down / no devices)
--   * pairing card  (request pairing + verification key)
--   * offline card  (device unreachable + unpair)
--   * device card   (battery / network / signal / notifications + actions)
--
-- Actions run their own busctl calls (entries are isolated VMs); status data
-- always comes from the service so there is a single source of truth.
--
-- Share supports multiple files: the input is multiline, one path per line
-- (newline-only split — paths may contain spaces). Every listed path must
-- exist or nothing is sent; on success all files fire-and-forget via
-- shareUrl and the input is cleared by re-keying it (see shareGeneration).

local BUSCTL = "busctl --user"
local SERVICE = "org.kde.kdeconnect"

local snap = noctalia.state.get("kdec")
local isOpen = false
local sharePath = ""
local shareFeedback = "" -- one-line feedback under the share input
local shareGeneration = 0 -- bumped to re-key (and thus clear) the uncontrolled share input
local nonce = 0 -- monotonic counter for state-channel requests (os.clock() is CPU time and can collide)

-- ── translations with embedded English fallback ───────────────────────────────
-- noctalia.tr() resolves translations/<lang>.json on builds that ship the plugin
-- i18n catalog; on builds that don't, it returns the key verbatim. Fall back to
-- these English defaults so raw keys never reach the UI.

local DEFAULTS = {
  ["panel.title"] = "Connected Devices",
  ["panel.battery"] = "Battery",
  ["panel.network"] = "Network",
  ["panel.signal_strength"] = "Signal Strength",
  ["panel.notifications"] = "Notifications",
  ["panel.unknown"] = "Unknown",
  ["panel.signal.0"] = "Very Weak",
  ["panel.signal.1"] = "Weak",
  ["panel.signal.2"] = "Fair",
  ["panel.signal.3"] = "Good",
  ["panel.signal.4"] = "Excellent",
  ["panel.actions.ring"] = "Find device",
  ["panel.actions.ping"] = "Ping",
  ["panel.actions.clipboard"] = "Send clipboard",
  ["panel.actions.wake"] = "Wake up",
  ["panel.actions.browse"] = "Browse files",
  ["panel.actions.share"] = "Send a file",
  ["panel.share_placeholder"] = "~/path/to/file",
  ["panel.share_not_found"] = "File not found: {path}",
  ["panel.share_sent"] = "Sent {path}",
  ["panel.share_sent_multi"] = "Sent {count} files",
  ["panel.clipboard_empty"] = "Clipboard is empty",
  ["panel.clipboard_sent"] = "Clipboard sent to device",
  ["panel.clipboard_too_large"] = "Clipboard is too large to send",
  ["panel.browse_failed"] = "Could not mount the device over SFTP (is sshfs installed?)",
  ["panel.pair"] = "Pair with device",
  ["panel.pair_requested"] = "Confirm the pairing request on your device",
  ["panel.unpair"] = "Unpair",
  ["panel.device_unavailable"] = "Device is currently unavailable",
  ["errors.no_devices"] = "No device running KDE Connect found",
  ["errors.no_devices_hint"] = "Open the KDE Connect app on your phone and make sure both devices are on the same network, then press refresh.",
  ["errors.daemon_title"] = "kdeconnectd does not seem to be running!",
  ["errors.daemon_desc"] = "Make sure the KDE Connect application is installed and the kdeconnectd daemon has been started.",
  ["errors.busctl_title"] = "busctl cannot be found!",
  ["errors.busctl_desc"] = "Make sure busctl (part of systemd) is installed on your system.",
}

local function T(key, subst)
  local s = noctalia.tr(key, subst)
  if s == key then
    s = DEFAULTS[key] or key
  end
  -- Apply the {name} substitution unconditionally: noctalia.tr() may or may
  -- not have already substituted depending on the runtime/catalog, and the
  -- gsub is a no-op once the placeholder is already gone.
  if subst ~= nil then
    for name, value in pairs(subst) do
      s = s:gsub("{" .. name .. "}", function()
        return tostring(value)
      end)
    end
  end
  return s
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function sanitizeId(id): string
  return (tostring(id):gsub("[^%w_%-]", ""))
end

local function devicePath(id): string
  return "/modules/kdeconnect/devices/" .. sanitizeId(id)
end

local function shellQuote(s): string
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function callCmd(objPath, itf, member, args): string
  local cmd = `{BUSCTL} call --json=short {SERVICE} {objPath} {itf} {member}`
  if args then
    cmd ..= " " .. args
  end
  return cmd
end

local function fireAndForget(objPath, itf, member, args)
  noctalia.runAsync(callCmd(objPath, itf, member, args) .. " >/dev/null 2>&1")
end

local function firstReturn(text)
  if text == nil or text == "" then
    return nil
  end
  local ok, parsed = pcall(noctalia.json.decode, text)
  if not ok then
    return nil
  end
  if type(parsed) ~= "table" or parsed.data == nil then
    return nil
  end
  if type(parsed.data) == "table" then
    return parsed.data[1]
  end
  return parsed.data
end

local function requestRefresh()
  nonce += 1
  noctalia.state.set("kdec.refresh", { nonce = nonce })
end

local function devices()
  if type(snap) == "table" and type(snap.devices) == "table" then
    return snap.devices
  end
  return {}
end

local function currentDevice()
  for _, d in ipairs(devices()) do
    if snap ~= nil and d.id == snap.mainId then
      return d
    end
  end
  return nil
end

-- ── glyph mapping (mirrors the legacy plugin) ─────────────────────────────────

local function batteryGlyph(pct, charging): string
  if pct < 0 then
    return "battery-exclamation"
  end
  if charging then
    return "battery-charging-2"
  end
  if pct < 5 then
    return "battery"
  elseif pct < 25 then
    return "battery-1"
  elseif pct < 50 then
    return "battery-2"
  elseif pct < 75 then
    return "battery-3"
  end
  return "battery-4"
end

local CELL_TYPE_GLYPHS = {
  ["5G"] = "signal-5g",
  ["LTE"] = "signal-4g",
  ["HSPA"] = "signal-h",
  ["UMTS"] = "signal-3g",
  ["EDGE"] = "signal-e",
  ["GPRS"] = "signal-g",
  ["GSM"] = "signal-2g",
  ["CDMA"] = "signal-3g",
  ["CDMA2000"] = "signal-3g",
  ["iDEN"] = "signal-2g",
}

local function cellTypeGlyph(cellType): string
  return CELL_TYPE_GLYPHS[cellType] or "wave-square"
end

local function cellStrengthGlyph(strength): string
  if strength >= 0 and strength <= 4 then
    return `antenna-bars-{strength + 1}`
  end
  return "antenna-bars-off"
end

local function cellStrengthText(strength): string
  if strength >= 0 and strength <= 4 then
    return T(`panel.signal.{strength}`)
  end
  return T("panel.unknown")
end

-- ── UI building blocks ────────────────────────────────────────────────────────

local function statRow(glyph, label, value)
  return ui.row({ gap = 12, align = "center" }, {
    ui.glyph({ name = glyph, size = 26, color = "on_surface" }),
    ui.column({ gap = 2 }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = value, fontSize = 14, fontWeight = "medium", color = "on_surface" }),
    }),
  })
end

local function messageCard(glyph, title, description)
  local children = {
    ui.glyph({ name = glyph, size = 48, color = "on_surface_variant" }),
    ui.label({ text = title, fontSize = 15, fontWeight = "medium", color = "on_surface_variant", textAlign = "center", maxLines = 3 }),
  }
  if description ~= nil and description ~= "" then
    table.insert(children, ui.label({ text = description, fontSize = 12, color = "on_surface_variant", textAlign = "center", maxLines = 5 }))
  end
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center", paddingH = 16 }, children)
end

local function actionButton(glyph, textKey, onClick)
  return ui.button({
    glyph = glyph,
    text = T(textKey),
    fontSize = 12,
    glyphSize = 15,
    variant = "secondary",
    contentAlign = "start",
    flexGrow = 1,
    onClick = onClick,
  })
end

-- ── cards ─────────────────────────────────────────────────────────────────────

local function pairingCard(dev)
  local children = {
    ui.label({ text = dev.name, fontSize = 18, fontWeight = "bold", color = "on_surface" }),
    ui.button({
      text = T("panel.pair"),
      variant = "primary",
      enabled = not dev.pairRequested,
      onClick = "onPair",
    }),
  }
  if dev.pairRequested then
    table.insert(children, ui.label({
      text = T("panel.pair_requested"),
      fontSize = 12,
      color = "on_surface_variant",
      textAlign = "center",
    }))
    if dev.verificationKey ~= "" then
      table.insert(children, ui.row({ gap = 8, align = "center", justify = "center" }, {
        ui.glyph({ name = "key", size = 16, color = "on_surface" }),
        ui.label({ text = dev.verificationKey, fontSize = 15, fontWeight = "bold", color = "primary" }),
      }))
    end
  end
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, children)
end

local function offlineCard(dev)
  return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, {
    ui.glyph({ name = "device-mobile-off", size = 48, color = "on_surface_variant" }),
    ui.label({ text = dev.name, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = T("panel.device_unavailable"), fontSize = 13, color = "on_surface_variant", textAlign = "center" }),
    ui.button({ text = T("panel.unpair"), variant = "destructive", onClick = "onUnpair" }),
  })
end

local function deviceCard(dev)
  local notifValue = tostring(dev.notifications)
  local batteryValue = if dev.battery >= 0 then `{dev.battery}%` else T("panel.unknown")
  local networkValue = if dev.cellType ~= "" then dev.cellType else T("panel.unknown")

  -- Multi-file share: one path per line. In a multiline ui.input, Enter
  -- inserts a newline and onSubmit only fires on Ctrl+Enter — keep both
  -- onChange and onSubmit wired so the send button and Ctrl+Enter agree.
  local shareChildren = {
    ui.label({ text = T("panel.actions.share"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        -- ui.input is uncontrolled: giving it a new key forces recreation,
        -- which is how we clear it after a successful send (see shareFile).
        key = "share_path_" .. shareGeneration,
        placeholder = T("panel.share_placeholder"),
        fontSize = 12,
        flexGrow = 1,
        multiline = true,
        onChange = "onShareChanged",
        onSubmit = "onShareSubmit",
      }),
      ui.button({ glyph = "send", variant = "primary", onClick = "onShareClicked" }),
    }),
  }
  if shareFeedback ~= "" then
    table.insert(shareChildren, ui.label({ text = shareFeedback, fontSize = 11, color = "on_surface_variant", maxLines = 2 }))
  end

  return ui.scroll({ flexGrow = 1, gap = 16 }, {
    -- Device name
    ui.label({ text = dev.name, fontSize = 18, fontWeight = "bold", color = "on_surface" }),

    -- Stats
    ui.column({ gap = 12, fill = "surface_variant/0.5", radius = 12, padding = 14 }, {
      statRow(batteryGlyph(dev.battery, dev.charging), T("panel.battery"), batteryValue),
      statRow(cellTypeGlyph(dev.cellType), T("panel.network"), networkValue),
      statRow(cellStrengthGlyph(dev.cellStrength), T("panel.signal_strength"), cellStrengthText(dev.cellStrength)),
      statRow("bell", T("panel.notifications"), notifValue),
    }),

    -- Actions
    ui.column({ gap = 8 }, {
      ui.row({ gap = 8 }, {
        actionButton("radar", "panel.actions.ring", "onRing"),
        actionButton("send", "panel.actions.ping", "onPing"),
      }),
      ui.row({ gap = 8 }, {
        actionButton("clipboard-text", "panel.actions.clipboard", "onSendClipboard"),
        actionButton("power", "panel.actions.wake", "onWake"),
      }),
      ui.row({ gap = 8 }, {
        actionButton("folder-search", "panel.actions.browse", "onBrowse"),
      }),
    }),

    -- Share a file
    ui.column({ gap = 8 }, shareChildren),

    -- Unpair
    ui.row({ justify = "end" }, {
      ui.button({ text = T("panel.unpair"), glyph = "unlink", fontSize = 11, glyphSize = 13, variant = "ghost", onClick = "onUnpair" }),
    }),
  })
end

-- ── root render ───────────────────────────────────────────────────────────────

local function body()
  if snap == nil or not snap.busctl then
    return messageCard("exclamation-circle", T("errors.busctl_title"), T("errors.busctl_desc"))
  end
  if not snap.daemon then
    return messageCard("exclamation-circle", T("errors.daemon_title"), T("errors.daemon_desc"))
  end

  local dev = currentDevice()
  if dev == nil then
    return messageCard("device-mobile-off", T("errors.no_devices"), T("errors.no_devices_hint"))
  end
  if not dev.paired then
    if dev.reachable then
      return pairingCard(dev)
    end
    return offlineCard(dev)
  end
  if not dev.reachable then
    return offlineCard(dev)
  end
  return deviceCard(dev)
end

local function deviceSelector()
  local list = devices()
  if #list < 2 then
    return nil
  end
  local names = {}
  local selected = 0
  for i, d in ipairs(list) do
    names[i] = d.name
    if snap ~= nil and d.id == snap.mainId then
      selected = i - 1
    end
  end
  return ui.select({ options = names, selectedIndex = selected, onChange = "onDeviceSelected" })
end

local function render()
  if not isOpen then
    return
  end
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "device-mobile", size = 20, color = "primary" }),
      ui.label({ text = T("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
      ui.button({ glyph = "x", variant = "ghost", onClick = "onCloseClicked" }),
    }),
  }
  local selector = deviceSelector()
  if selector ~= nil then
    table.insert(children, selector)
  end
  table.insert(children, body())
  panel.render(ui.column({ flexGrow = 1, gap = 14 }, children))
end

noctalia.state.watch("kdec", function(value)
  snap = value
  render()
end)

-- ── panel lifecycle ───────────────────────────────────────────────────────────

function onOpen(_context)
  isOpen = true
  shareFeedback = ""
  snap = noctalia.state.get("kdec")
  requestRefresh()
  render()
end

function onClose()
  isOpen = false
end

function onCloseClicked()
  panel.close()
end

function onRefresh()
  shareFeedback = ""
  render()
  requestRefresh()
end

function onDeviceSelected(index, _text)
  local list = devices()
  local i = (tonumber(index) or 0) + 1
  local dev = list[i]
  if dev ~= nil then
    shareFeedback = ""
    render()
    nonce += 1
    noctalia.state.set("kdec.setMain", { id = dev.id, nonce = nonce })
  end
end

-- ── device actions ────────────────────────────────────────────────────────────

local function withCurrentId(): string?
  local dev = currentDevice()
  if dev == nil then
    return nil
  end
  return sanitizeId(dev.id)
end

function onPing()
  local id = withCurrentId()
  if id then
    fireAndForget(devicePath(id) .. "/ping", "org.kde.kdeconnect.device.ping", "sendPing")
  end
end

function onRing()
  local id = withCurrentId()
  if id then
    fireAndForget(devicePath(id) .. "/findmyphone", "org.kde.kdeconnect.device.findmyphone", "ring")
  end
end

function onWake()
  local id = withCurrentId()
  if id then
    -- Same trick as the legacy plugin: a remote-control "singleclick" wakes the screen.
    fireAndForget(devicePath(id) .. "/remotecontrol", "org.kde.kdeconnect.device.remotecontrol",
      "sendCommand", 'a{sv} 1 singleclick b true')
  end
end

function onSendClipboard()
  local id = withCurrentId()
  if id == nil then
    return
  end
  local text = noctalia.clipboardText()
  if text == nil or text == "" then
    noctalia.notifyError(T("panel.title"), T("panel.clipboard_empty"))
    return
  end
  fireAndForget(devicePath(id) .. "/share", "org.kde.kdeconnect.device.share",
    "shareText", "s " .. shellQuote(text))
  noctalia.notify(T("panel.title"), T("panel.clipboard_sent"))
end

function onBrowse()
  local id = withCurrentId()
  if id == nil then
    return
  end
  local sftp = devicePath(id) .. "/sftp"
  -- Mount over SFTP (needs sshfs), then open the first exposed directory.
  noctalia.runAsync(callCmd(sftp, "org.kde.kdeconnect.device.sftp", "mountAndWait"), function(_res)
    noctalia.runAsync(callCmd(sftp, "org.kde.kdeconnect.device.sftp", "getDirectories"), function(res)
      local dirs = firstReturn(res.stdout)
      if type(dirs) == "table" then
        for path, _label in pairs(dirs) do
          noctalia.runAsync("xdg-open " .. shellQuote(path))
          return
        end
      end
      noctalia.notifyError(T("panel.title"), T("panel.browse_failed"))
    end)
  end)
end

function onShareChanged(value)
  sharePath = tostring(value or "")
end

local function shareFile()
  local id = withCurrentId()
  if id == nil then
    return
  end
  local path = noctalia.string.trim(sharePath)
  if path == "" then
    return
  end
  path = noctalia.expandPath(path)
  if not noctalia.fileExists(path) then
    shareFeedback = T("panel.share_not_found", { path = path })
    render()
    return
  end
  fireAndForget(devicePath(id) .. "/share", "org.kde.kdeconnect.device.share",
    "shareUrl", "s " .. shellQuote("file://" .. path))
  shareFeedback = T("panel.share_sent", { path = path })
  render()
end

function onShareClicked()
  shareFile()
end

function onShareSubmit(value)
  sharePath = tostring(value or "")
  shareFile()
end

function onPair()
  local id = withCurrentId()
  if id then
    fireAndForget(devicePath(id), "org.kde.kdeconnect.device", "requestPairing")
    requestRefresh()
  end
end

function onUnpair()
  local id = withCurrentId()
  if id then
    fireAndForget(devicePath(id), "org.kde.kdeconnect.device", "unpair")
    requestRefresh()
  end
end
