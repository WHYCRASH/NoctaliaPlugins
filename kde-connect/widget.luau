--!nonstrict
-- KDE Connect [[widget]] entry — bar pill.
--
-- Shows a state glyph plus the main device's battery percentage.
--   left click:   toggle the device panel
--   right click:  configurable action (setting "right_click_action")
--   middle click: configurable action (setting "middle_click_action")
--
-- The configurable actions are: none, open panel, ring, ping, send
-- clipboard, refresh devices. "panel" is handled directly in this VM (so it
-- will pick up the click anchor for open_near_click once Noctalia forwards
-- it for plugin widgets — see docs/upstream-issue-open-near-click.md); every
-- other action is dispatched to the service via the nonce-wrapped
-- "kdec.action" state key, since busctl calls for actions belong in the
-- service/panel, not the widget.
--
-- All status data comes from the service's "kdec" state snapshot; this
-- script never polls D-Bus for status itself.

local PANEL_ID = "antik/kde-connect:panel"

local hideIfNoDevice = noctalia.getConfig("hide_if_no_device") == true
local snap = noctalia.state.get("kdec")

-- Translation helpers with embedded English fallback (raw keys never render,
-- even on Noctalia builds without the plugin i18n catalog).
local DEFAULTS = {
  ["bar.tooltip"] = "Connected Devices",
  ["bar.notifications.one"] = "{count} notification",
  ["bar.notifications.other"] = "{count} notifications",
  ["state.connected"] = "Connected",
  ["state.disconnected"] = "Disconnected",
  ["state.unavailable"] = "Unavailable",
  ["state.no_device"] = "No device",
  ["state.not_paired"] = "Not paired",
}

local function T(key)
  local s = noctalia.tr(key)
  if s == key then
    s = DEFAULTS[key] or key
  end
  return s
end

local function TP(key, count)
  local s = noctalia.trp(key, count)
  if s == key then
    s = DEFAULTS[key .. (if count == 1 then ".one" else ".other")] or key
    s = s:gsub("{count}", tostring(count))
  end
  return s
end

local function mainDevice()
  if type(snap) ~= "table" or type(snap.devices) ~= "table" then
    return nil, false
  end
  local main, anyReachable = nil, false
  for _, d in ipairs(snap.devices) do
    if d.id == snap.mainId then
      main = d
    end
    if d.reachable then
      anyReachable = true
    end
  end
  return main, anyReachable
end

local function glyphFor(main): string
  if snap == nil or not snap.busctl or not snap.daemon then
    return "exclamation-circle"
  end
  if main == nil or not main.reachable then
    return "device-mobile-off"
  end
  if main.battery >= 0 and main.battery < 10 then
    return "device-mobile-exclamation"
  end
  if main.notifications > 0 then
    return "device-mobile-message"
  end
  if main.charging then
    return "device-mobile-bolt"
  end
  return "device-mobile"
end

local function stateText(main): string
  if snap == nil or not snap.busctl or not snap.daemon then
    return T("state.unavailable")
  end
  if main == nil then
    return T("state.no_device")
  end
  if not main.reachable then
    return T("state.disconnected")
  end
  if not main.paired then
    return T("state.not_paired")
  end
  return T("state.connected")
end

local function render()
  local main, anyReachable = mainDevice()

  if hideIfNoDevice and not anyReachable then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  barWidget.setGlyph(glyphFor(main))

  local text = ""
  if main ~= nil and main.reachable and main.battery >= 0 then
    text = `{main.battery}%`
  end
  barWidget.setText(text)

  local tooltip = T("bar.tooltip")
  if main ~= nil then
    tooltip = `{main.name} — {stateText(main)}`
    if main.reachable and main.battery >= 0 then
      tooltip ..= ` · {main.battery}%`
    end
    if main.notifications > 0 then
      tooltip ..= ` · {TP("bar.notifications", main.notifications)}`
    end
  end
  barWidget.setTooltip(tooltip)
end

noctalia.state.watch("kdec", function(value)
  snap = value
  render()
end)

render()

function update()
  -- Rendering is state-driven; the tick only exists as a safety refresh.
  noctalia.setUpdateInterval(10000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

local nonce = 0

local function runAction(action)
  if action == "" or action == "none" then
    return
  end
  if action == "panel" then
    -- Kept in this VM so the toggle can pick up the click anchor once
    -- Noctalia forwards it for plugin widgets (upstream limitation today).
    noctalia.togglePanel(PANEL_ID)
    return
  end
  nonce += 1
  local req = { op = action, nonce = nonce }
  if action == "clipboard" then
    local text = noctalia.clipboardText()
    if text == nil or text == "" then
      return
    end
    req.text = text
  end
  noctalia.state.set("kdec.action", req)
end

function onRightClick()
  runAction(tostring(noctalia.getConfig("right_click_action") or "none"))
end

function onMiddleClick()
  runAction(tostring(noctalia.getConfig("middle_click_action") or "none"))
end
