--!nonstrict
-- KDE Connect [[service]] entry.
--
-- Polls kdeconnectd over the user D-Bus session (via busctl) and publishes one
-- atomic snapshot for the widget / shortcut / panel entries:
--
--   noctalia.state key "kdec" = {
--     busctl  = boolean,     -- busctl found on PATH
--     daemon  = boolean,     -- org.kde.kdeconnect owned on the user bus
--     devices = { Device },  -- sorted by name
--     mainId  = string,      -- id of the "main" device (persisted preference)
--   }
--
--   Device = {
--     id, name, reachable, paired, pairRequested, verificationKey,
--     battery (-1 unknown), charging, cellType, cellStrength (-1 unknown),
--     notifications (count),
--   }
--
-- Other entries request work through state keys (values are nonce-wrapped so
-- repeated identical requests still fire the watcher):
--   "kdec.refresh"  { nonce }                       -- force rediscovery + repoll
--   "kdec.setMain"  { id, nonce }                   -- change + persist main device
--   "kdec.action"   { op = "ring"|"ping"|"clipboard"|"refresh", nonce,
--                     id? = deviceId, text? = clipboardText }
--                   -- fire a device action; id defaults to the main device

local MAIN_ID_FILE = "main_device.txt"
local BUSCTL = "busctl --user"
local SERVICE = "org.kde.kdeconnect"
local CALL_TIMEOUT = 5 -- busctl method-call reply timeout (s)
local PROC_TIMEOUT = 8 -- hard subprocess bound; -k 2 = SIGKILL 2s after SIGTERM

local pollMs = math.max(2, tonumber(noctalia.getConfig("poll_interval")) or 5) * 1000
local hasBusctl = noctalia.commandExists("busctl")
local mainId = ""
local polling = false
local pollStartedAt = 0 -- os.time() when the current poll began (watchdog anchor)
local pollGen = 0 -- bumped every poll() call; stale async callbacks compare and no-op
local announced = false -- forceOnNetworkChange sent since the daemon came up
local emptyPolls = 0 -- consecutive polls with zero devices (drives re-announce)

do
  local saved = noctalia.readFile(MAIN_ID_FILE)
  if saved then
    mainId = noctalia.string.trim(saved)
  end
end

-- ── busctl helpers ────────────────────────────────────────────────────────────

local function sanitizeId(id: string): string
  -- kdeconnect device ids are [A-Za-z0-9_-]; strip anything else before the id
  -- ever touches a shell command or a D-Bus object path.
  return (tostring(id):gsub("[^%w_%-]", ""))
end

local function devicePath(id: string): string
  return "/modules/kdeconnect/devices/" .. sanitizeId(id)
end

local function shellQuote(s): string
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function callCmd(objPath: string, itf: string, member: string, args: string?): string
  local cmd = `timeout -k 2 {PROC_TIMEOUT} {BUSCTL} call --timeout={CALL_TIMEOUT} --json=short {SERVICE} {objPath} {itf} {member}`
  if args then
    cmd ..= " " .. args
  end
  return cmd
end

-- Runs a device action (ring / ping / clipboard) fire-and-forget. `id` must
-- pass through sanitizeId before it ever reaches a shell command or D-Bus
-- object path; empty ids are a no-op.
local function runDeviceAction(op: string, id: string, text: string?)
  local sid = sanitizeId(id)
  if sid == "" then
    return
  end
  if op == "ring" then
    noctalia.runAsync(callCmd(devicePath(sid) .. "/findmyphone", "org.kde.kdeconnect.device.findmyphone", "ring") .. " >/dev/null 2>&1")
  elseif op == "ping" then
    noctalia.runAsync(callCmd(devicePath(sid) .. "/ping", "org.kde.kdeconnect.device.ping", "sendPing") .. " >/dev/null 2>&1")
  elseif op == "clipboard" then
    if type(text) == "string" and text ~= "" then
      noctalia.runAsync(
        callCmd(devicePath(sid) .. "/share", "org.kde.kdeconnect.device.share", "shareText", "s " .. shellQuote(text)) .. " >/dev/null 2>&1"
      )
    end
  end
end

-- busctl --json=short wraps results as {"type":"...","data":[ret1, ret2, …]}.
-- Returns the first return value, or nil.
local function firstReturn(text: string?): any
  if text == nil or text == "" then
    return nil
  end
  local parsed = noctalia.json.decode(text)
  if type(parsed) ~= "table" or parsed.data == nil then
    return nil
  end
  if type(parsed.data) == "table" then
    return parsed.data[1]
  end
  return parsed.data
end

-- GetAll returns a{sv}: a map of property -> { type, data }. Unwrap the variants.
local function unwrapProps(map: any): { [string]: any }
  local out = {}
  if type(map) ~= "table" then
    return out
  end
  for k, v in pairs(map) do
    if type(v) == "table" and v.data ~= nil then
      out[k] = v.data
    else
      out[k] = v
    end
  end
  return out
end

-- ── snapshot publishing ───────────────────────────────────────────────────────

local function pickMain(devices): string
  local preferred, firstReachable = nil, nil
  for _, d in ipairs(devices) do
    if d.id == mainId then
      preferred = d
    end
    if firstReachable == nil and d.reachable then
      firstReachable = d
    end
  end
  -- Preferred device wins while reachable; otherwise fall back to any reachable
  -- device, then the (unreachable) preferred one, then the first device.
  if preferred and preferred.reachable then
    return preferred.id
  end
  if firstReachable then
    return firstReachable.id
  end
  if preferred then
    return preferred.id
  end
  if #devices > 0 then
    return devices[1].id
  end
  return ""
end

local function publish(daemon: boolean, devices)
  table.sort(devices, function(a, b)
    return tostring(a.name):lower() < tostring(b.name):lower()
  end)
  noctalia.state.set("kdec", {
    busctl = hasBusctl,
    daemon = daemon,
    devices = devices,
    mainId = pickMain(devices),
  })
end

-- ── device collection ─────────────────────────────────────────────────────────

-- One subprocess per device gathers everything as tagged JSON lines.
-- Command substitution output is not re-parsed by the shell, so the JSON's
-- quotes survive the surrounding echo "…" untouched.
local function collectorCmd(id: string): string
  local p = devicePath(id)
  local getAll = function(objPath, itf)
    return callCmd(objPath, "org.freedesktop.DBus.Properties", "GetAll", "s " .. itf)
  end
  return table.concat({
    `echo "DEVICE|$({getAll(p, "org.kde.kdeconnect.device")} 2>/dev/null)"`,
    `echo "BATTERY|$({getAll(p .. "/battery", "org.kde.kdeconnect.device.battery")} 2>/dev/null)"`,
    `echo "CONN|$({getAll(p .. "/connectivity_report", "org.kde.kdeconnect.device.connectivity_report")} 2>/dev/null)"`,
    `echo "NOTIF|$({callCmd(p .. "/notifications", "org.kde.kdeconnect.device.notifications", "activeNotifications")} 2>/dev/null)"`,
  }, "; ")
end

local function parseDevice(id: string, stdout: string)
  local d = {
    id = id,
    name = id,
    reachable = false,
    paired = false,
    pairRequested = false,
    verificationKey = "",
    battery = -1,
    charging = false,
    cellType = "",
    cellStrength = -1,
    notifications = 0,
  }
  for _, line in ipairs(string.split(stdout, "\n")) do
    local sep = string.find(line, "|", 1, true)
    if sep == nil then
      continue
    end
    local tag = string.sub(line, 1, sep - 1)
    local body = string.sub(line, sep + 1)
    if tag == "DEVICE" then
      local props = unwrapProps(firstReturn(body))
      if type(props.name) == "string" and props.name ~= "" then
        d.name = props.name
      end
      d.reachable = props.isReachable == true
      d.paired = props.isPaired == true
      d.pairRequested = props.isPairRequested == true
      d.verificationKey = tostring(props.verificationKey or "")
    elseif tag == "BATTERY" then
      local props = unwrapProps(firstReturn(body))
      if type(props.charge) == "number" and props.charge >= 0 then
        d.battery = math.floor(props.charge)
      end
      d.charging = props.isCharging == true
    elseif tag == "CONN" then
      local props = unwrapProps(firstReturn(body))
      d.cellType = tostring(props.cellularNetworkType or "")
      if type(props.cellularNetworkStrength) == "number" then
        d.cellStrength = math.floor(props.cellularNetworkStrength)
      end
    elseif tag == "NOTIF" then
      local ids = firstReturn(body)
      if type(ids) == "table" then
        d.notifications = #ids
      end
    end
  end
  return d
end

-- ── polling ───────────────────────────────────────────────────────────────────

local function poll()
  local now = os.time()
  if polling then
    if now - pollStartedAt < math.max(15, 3 * pollMs / 1000) then
      return
    end
    noctalia.log(`kde-connect: poll stuck for {now - pollStartedAt}s; abandoning it`)
  end

  if not hasBusctl then
    hasBusctl = noctalia.commandExists("busctl")
    if not hasBusctl then
      publish(false, {})
      return
    end
  end

  polling = true
  pollStartedAt = now
  pollGen += 1
  local gen = pollGen

  noctalia.runAsync(`timeout -k 2 {PROC_TIMEOUT} {BUSCTL} status {SERVICE} >/dev/null 2>&1`, function(status)
    if gen ~= pollGen then
      return
    end
    if status.exitCode ~= 0 then
      polling = false
      announced = false
      publish(false, {})
      return
    end

    -- Nudge discovery on daemon-up, and keep nudging every ~6th poll while no
    -- devices have been found yet (UDP announcements can be missed).
    if not announced or (emptyPolls > 0 and emptyPolls % 6 == 0) then
      announced = true
      noctalia.runAsync(callCmd("/modules/kdeconnect", "org.kde.kdeconnect.daemon", "forceOnNetworkChange") .. " >/dev/null 2>&1")
    end

    noctalia.runAsync(callCmd("/modules/kdeconnect", "org.kde.kdeconnect.daemon", "devices"), function(listRes)
      if gen ~= pollGen then
        return
      end
      local ids = firstReturn(listRes.stdout)
      if type(ids) ~= "table" or #ids == 0 then
        if listRes.exitCode ~= 0 then
          noctalia.log(`kde-connect: devices call failed (exit {listRes.exitCode}): {noctalia.string.trim(listRes.stderr or "")}`)
        end
        emptyPolls += 1
        polling = false
        publish(true, {})
        return
      end
      emptyPolls = 0

      local devices = {}
      local pending = #ids
      for _, rawId in ipairs(ids) do
        local id = sanitizeId(rawId)
        noctalia.runAsync(collectorCmd(id), function(devRes)
          if gen ~= pollGen then
            return
          end
          table.insert(devices, parseDevice(id, devRes.stdout or ""))
          pending -= 1
          if pending == 0 then
            polling = false
            publish(true, devices)
          end
        end)
      end
    end)
  end)
end

-- ── requests from other entries ───────────────────────────────────────────────

noctalia.state.watch("kdec.refresh", function(_req)
  announced = false -- re-announce on the next poll (forces device rediscovery)
  poll()
end)

noctalia.state.watch("kdec.setMain", function(req)
  if type(req) == "table" and type(req.id) == "string" and req.id ~= "" then
    mainId = sanitizeId(req.id)
    noctalia.writeFile(MAIN_ID_FILE, mainId)
    poll()
  end
end)

noctalia.state.watch("kdec.action", function(req)
  if type(req) ~= "table" or type(req.op) ~= "string" then
    return
  end
  if req.op == "refresh" then
    announced = false
    poll()
    return
  end
  local snap = noctalia.state.get("kdec")
  local id = if type(req.id) == "string" and req.id ~= "" then req.id else (type(snap) == "table" and tostring(snap.mainId or "")) or ""
  runDeviceAction(req.op, id, req.text)
end)

-- ── IPC: `noctalia msg plugin antik/kde-connect:monitor all <event>` ─────────

function onIpc(event, _payload)
  local snap = noctalia.state.get("kdec")
  local id = (type(snap) == "table" and snap.mainId) or ""
  if id == "" then
    return
  end
  if event == "ring" or event == "ping" then
    runDeviceAction(event, id)
  elseif event == "refresh" then
    announced = false
    poll()
  end
end

function onConfigChanged()
  pollMs = math.max(2, tonumber(noctalia.getConfig("poll_interval")) or 5) * 1000
  noctalia.setUpdateInterval(pollMs)
end

-- ── ticks ─────────────────────────────────────────────────────────────────────

noctalia.setUpdateInterval(pollMs)

function update()
  poll()
end

poll()
