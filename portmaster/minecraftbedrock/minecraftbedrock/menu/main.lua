-- Minecraft Bedrock port — launcher menu (LOVE 11.x).
-- Original launcher UI for this port: procedural pixel-art chrome (no image
-- assets), Monocraft pixel font, dithered gradient sky, drifting ember pixels
-- and a chunky 3D widget set — extruded buttons (hard outline + lit top edge
-- + darker bottom side), toggle switches with I/O marks, sliders, pixel
-- icons and keycap footer hints. Dark mode throughout.
--
-- Screens:
--   * Play (with remembered version selection)
--   * Versions: pick the active version, delete installed versions
--   * Download: optional Google Play sign-in/download on supported devices
--   * Install: extract new versions from APKs dropped in apk/
--   * Settings: FPS cap, render distance (below the in-game minimum),
--     client ABI, UI scale, vsync, performance toggles
--
-- Protocol with "Minecraft Bedrock.sh" (all under $MCPE_GAMEDIR/config/):
--   settings.cfg        key=value, persisted here, parsed by the shell
--   menu_action.txt     line 1 = action (play/download_apk/install/delete/exit),
--                       line 2 = argument (version name / apk file name)
--   install_request.txt apk file names (one per line) for action=install
--   menu_error.txt      lua traceback if the menu itself crashed
-- The shell treats an empty/missing action file as a visible menu failure and
-- does not launch Minecraft with hidden defaults.
--
-- Buttons: which SDL button means "confirm" depends on the pad's mapping
-- style. PortMaster's H700-family mappings are POSITIONAL (SDL "a" = SOUTH =
-- the button printed B on Nintendo-style labels) -> confirm on SDL "b".
-- Some pads (RG DS retrogame_joypad) map by LABEL instead -> confirm on SDL
-- "a". Picked per pad GUID at startup; override with MCPE_MENU_CONFIRM=a|b.
-- Delete is SDL "y"/"x" (printed X either way).

local GAMEDIR = os.getenv("MCPE_GAMEDIR") or "."
local CONFDIR = GAMEDIR .. "/config"
local VERDIR  = GAMEDIR .. "/versions"
local APKDIR  = GAMEDIR .. "/apk"
local STATUS  = os.getenv("MCPE_MENU_STATUS") or ""
local DOWNLOADER_SUPPORTED = os.getenv("MCPE_DOWNLOADER_SUPPORTED") == "1"
local DOWNLOADER_SESSION = os.getenv("MCPE_DOWNLOADER_SESSION") == "1"
local DOWNLOADER_RUNTIME = os.getenv("MCPE_DOWNLOADER_RUNTIME") == "1"
local EXIT_ON_PLAY = os.getenv("MCPE_MENU_EXIT_ON_PLAY") == "1"
-- Test hook: exit cleanly (as if the user chose Exit) after N seconds. Used
-- by remote display tests so the GL context is never hard-killed mid-frame,
-- which corrupts the display state on fbdev-mali devices. Unset in normal use.
local AUTOQUIT = tonumber(os.getenv("MCPE_MENU_AUTOQUIT") or "")
-- Test hook: write a PNG of the Nth drawn frame to this absolute path. LOVE
-- renders through DRM on fbdev-mali devices, where framebuffer grabbers only
-- ever see the frontend's last frame, so the UI can only be inspected from
-- inside the process. Unset in normal use.
local SHOT_PATH = os.getenv("MCPE_MENU_SHOT")
local SHOT_AT = tonumber(os.getenv("MCPE_MENU_SHOT_FRAME") or "") or 45
local shotFrames, shotDone = 0, false
local firstFrameReported = false

-- ---------------------------------------------------------------- palette --
local COL = {
  sky_top    = {0.043, 0.051, 0.078},
  sky_bottom = {0.075, 0.102, 0.086},
  panel      = {0.086, 0.106, 0.118},
  panel_hi   = {0.118, 0.145, 0.157},
  bevel_lt   = {0.239, 0.290, 0.302},
  bevel_dk   = {0.016, 0.024, 0.031},
  accent     = {0.353, 0.820, 0.290},
  accent_hi  = {0.620, 0.950, 0.450},
  accent_dk  = {0.157, 0.400, 0.145},
  fg         = {0.920, 0.930, 0.880},
  dim        = {0.520, 0.550, 0.520},
  faint      = {0.310, 0.330, 0.330},
  danger     = {0.900, 0.310, 0.250},
  danger_dk  = {0.420, 0.130, 0.110},
  warn       = {0.950, 0.720, 0.200},
  outline    = {0.008, 0.012, 0.020},
}

-- 3D button styles: face, lit top/left edge, darker extruded bottom side,
-- hard outline color.
local BTN = {
  normal = {
    face = {0.129, 0.157, 0.173}, hi = {0.243, 0.290, 0.306},
    side = {0.039, 0.051, 0.063}, edge = COL.outline,
  },
  selected = {
    face = {0.157, 0.224, 0.176}, hi = {0.333, 0.463, 0.310},
    side = {0.075, 0.153, 0.075}, edge = COL.accent,
  },
  dangerSel = {
    face = {0.235, 0.110, 0.098}, hi = {0.427, 0.192, 0.165},
    side = {0.114, 0.047, 0.039}, edge = COL.danger,
  },
}

-- ------------------------------------------------------------- file utils --
local function readAll(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeAll(path, content)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function fileSize(path)
  local f = io.open(path, "r")
  if not f then return 0 end
  local n = f:seek("end") or 0
  f:close()
  return n
end

local function listDirs(path)
  local out = {}
  local p = io.popen("ls -d '" .. path .. "'/*/ 2>/dev/null")
  if p then
    for line in p:lines() do
      local name = line:match(".+/(.-)/$")
      if name then out[#out + 1] = name end
    end
    p:close()
  end
  table.sort(out)
  return out
end

local function listFiles(path, suffix)
  local out = {}
  local p = io.popen("ls -p '" .. path .. "' 2>/dev/null")
  if p then
    for line in p:lines() do
      if not line:match("/$") and line:lower():match(suffix .. "$") then
        out[#out + 1] = line
      end
    end
    p:close()
  end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------- settings --
-- Every setting: ordered value list, display labels, and a one-line help
-- string shown while the row is focused. The shell only consumes the keys it
-- whitelists, so adding rows here is safe.
local fpsValues, fpsNames = {"0"}, {"Off"}
for f = 10, 120, 5 do
  fpsValues[#fpsValues + 1] = tostring(f)
  fpsNames[#fpsNames + 1] = f .. " fps"
end

local SCHEMA = {
  {
    key = "fps_cap", label = "FPS cap", widget = "slider",
    values = fpsValues,
    names  = fpsNames,
    help   = "Auto uses 10 on low-memory R36S; 30-40 suits H700.",
  },
  {
    key = "render_distance", label = "Render distance", widget = "slider",
    values = {"0", "2", "3", "4", "5", "6", "8", "10", "12", "16"},
    names  = {"Auto", "2 chunks", "3 chunks", "4 chunks", "5 chunks",
              "6 chunks", "8 chunks", "10 chunks", "12 chunks", "16 chunks"},
    help   = "Auto requests 2 chunks on R36S; game versions may clamp it.",
  },
  {
    key = "abi", label = "Client",
    values = {"auto", "arm64", "armhf"},
    names  = {"Auto", "64-bit", "32-bit"},
    help   = "Auto picks per device. 32-bit needs /dev/dri (R36S-class).",
  },
  {
    key = "ui_scale", label = "UI scale",
    values = {"auto", "1", "2", "3"},
    names  = {"Auto", "Small (1)", "Normal (2)", "Large (3)"},
    help   = "Game interface density. Lower = smaller UI elements.",
  },
  {
    key = "vsync", label = "VSync",
    values = {"auto", "0", "1"},
    names  = {"Auto", "Off", "On"},
    help   = "Off + FPS cap usually feels smoothest on handhelds.",
  },
  {
    key = "perf_mode", label = "Performance governor", widget = "toggle",
    values = {"1", "0"},
    names  = {"On", "Off"},
    help   = "Locks CPU/GPU governors to performance while playing.",
  },
  {
    key = "options_tuning", label = "Auto-tune options", widget = "toggle",
    values = {"1", "0"},
    names  = {"On", "Off"},
    help   = "Keeps known-good renderer flags and disables dev logging.",
  },
  {
    key = "measure_fps", label = "FPS logging", widget = "toggle",
    values = {"0", "1"},
    names  = {"Off", "On"},
    help   = "Records a frame-time trace and prints a summary on exit.",
  },
  {
    key = "update_channel", label = "Update channel",
    values = {"stable", "testing"},
    names  = {"Stable", "Testing"},
    help   = "Testing receives compatibility candidates before stable promotion.",
  },
}

local settings = {}          -- key -> value (strings)
local settingsVersion = ""   -- remembered "play this" version

local function loadSettings()
  for _, row in ipairs(SCHEMA) do settings[row.key] = row.values[1] end
  local body = readAll(CONFDIR .. "/settings.cfg") or ""
  for line in body:gmatch("[^\r\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k == "version" then
      settingsVersion = v
    elseif k then
      for _, row in ipairs(SCHEMA) do
        if row.key == k then
          for _, allowed in ipairs(row.values) do
            if v == allowed then settings[k] = v end
          end
        end
      end
    end
  end
end

local function saveSettings()
  local lines = {"# Written by the launcher menu. Parsed by Minecraft Bedrock.sh."}
  if settingsVersion ~= "" then
    lines[#lines + 1] = "version=" .. settingsVersion
  end
  for _, row in ipairs(SCHEMA) do
    lines[#lines + 1] = row.key .. "=" .. settings[row.key]
  end
  writeAll(CONFDIR .. "/settings.cfg", table.concat(lines, "\n") .. "\n")
end

local function settingIndex(row)
  for i, v in ipairs(row.values) do
    if settings[row.key] == v then return i end
  end
  return 1
end

local function settingName(row)
  return row.names[settingIndex(row)]
end

-- ------------------------------------------------------------------- help --
-- Short troubleshooting; each entry is one list row (title + one-liner).
local HELP = {
  {t = "Install the game",
   d = "Use optional Google Play download, or copy your own APK into apk/."},
  {t = "Google Play downloader",
   d = "RG34XXSP/Knulli prototype. Optional; session and APKs stay on device."},
  {t = "Which APK",
   d = "arm64-v8a for most devices; armeabi-v7a for R36S-class."},
  {t = "Game will not start",
   d = "Check log.txt in ports/minecraftbedrock. 1.26+ Play APKs cannot work."},
  {t = "Stutters or low FPS",
   d = "Set FPS cap 30-40 and render distance 3-4 chunks in Settings."},
  {t = "No sound",
   d = "Raise the device volume, then relaunch the port once."},
  {t = "Wrong buttons in game",
   d = "Pad mappings live in minecraftbedrock/controls/ - see its README."},
  {t = "Worlds are safe",
   d = "Worlds live in profiles/ and survive version installs and deletes."},
  {t = "Backups",
   d = "Use the Backup menu; archives land in minecraftbedrock-data/backups/."},
  {t = "Updating the port",
   d = "Use 'Update port' in this menu (needs WiFi)."},
  {t = "More help",
   d = "github.com/DankMiimer/minecraft-bedrock-handheld-port"},
  {t = "Legal",
   d = "Unofficial port. Not approved by or associated with Mojang or Microsoft."},
  {t = "No game files included",
   d = "You must supply your own legally obtained copy of the game."},
}

-- ------------------------------------------------------------ model state --
local versions = {}   -- {name, tag}
local apks = {}       -- {name, size}
local apkGroups = {}  -- {id, title, desc, ready, files}
local backups = {}    -- {name, size}
local portVersion = ""
local DOWNLOADS = {
  {code = "971622101", abi = "arm64", title = "Minecraft 1.16.221.01 [ARM64]",
   desc = "RECOMMENDED | Best small-screen UI and smoothest RG34XXSP build.",
   warning = "Recommended everyday build for this ARM64 device."},
  {code = "972105101", abi = "arm64", title = "Minecraft 1.21.51.01 [ARM64]",
   desc = "TESTED ORIGINAL | Newest verified no-RenderDragon artifact; smaller UI.",
   warning = "A later Play reupload may use RenderDragon and stutter badly."},
}

-- Every build Google Play still serves, except 1.26+ which the launcher cannot
-- open, comes from downloader/version_catalog.tsv. That file carries the
-- edition, named update, renderer and warnings for each row, generated by
-- scripts/update_gplay_version_catalog.py from the same classification the
-- Windows helper uses -- so this menu describes a build exactly as the desktop
-- downloader does, and neither can drift. Nothing here is auto-selected; the
-- two tiles above remain the proven shortcuts.
local OTHER_DOWNLOADS = {
  arm64 = {release = {}, preview = {}},
  armhf = {release = {}, preview = {}},
}

-- The tile shortcuts above also appear somewhere in this list. Carry their
-- label across so the recommendation is not lost among a hundred rows that
-- nobody has tested.
local CURATED_LABEL = {}
for _, d in ipairs(DOWNLOADS) do
  CURATED_LABEL[d.code .. ":" .. d.abi] = d.desc:match("^%s*(.-)%s*|")
end

local function loadDownloadCatalog()
  local f = io.open(GAMEDIR .. "/downloader/version_catalog.tsv", "r")
  if not f then return end
  for line in f:lines() do
    local code, abi, channel, version, edition, update, renderer, ui, notes =
      line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if code and OTHER_DOWNLOADS[abi] and OTHER_DOWNLOADS[abi][channel] then
      local architecture = abi == "armhf" and "ARM32" or "ARM64"
      local isPreview = channel == "preview"
      local avoid = renderer == "RenderDragon"
      -- The same markings the desktop helper puts in its columns, in the same
      -- order: what it is, then what is wrong with it. Renderer is stated both
      -- ways round -- "No RenderDragon" is the reason to pick a build, not the
      -- absence of a reason to avoid one. The Play code is not repeated here;
      -- it is on the confirmation screen, and the space buys these labels.
      local summary = {}
      summary[#summary + 1] = CURATED_LABEL[code .. ":" .. abi]
      summary[#summary + 1] = avoid and "AVOID: RenderDragon" or renderer
      summary[#summary + 1] = edition == "Pocket Edition"
        and "Pocket Edition (touch only)" or edition
      if update ~= "" then summary[#summary + 1] = update end
      if ui ~= "" then summary[#summary + 1] = ui end
      table.insert(OTHER_DOWNLOADS[abi][channel], {
        code = code,
        abi = abi,
        avoid = avoid,
        title = version .. (isPreview and " PREVIEW" or "") .. " [" .. architecture .. "]",
        desc = table.concat(summary, " | "),
        warning = (notes ~= "" and notes) or
          (isPreview
            and "Untested preview/beta build. It may fail, and worlds may not safely downgrade."
            or "Untested Google Play release. It may crash, stutter or fail to install."),
      })
    end
  end
  f:close()
end

loadDownloadCatalog()
local downloadOtherAbi = "arm64"
local downloadOtherChannel = "release"

local function currentOtherDownloads()
  return OTHER_DOWNLOADS[downloadOtherAbi][downloadOtherChannel]
end

local DOWNLOAD_INFO = {
  {t = "Google handles credentials",
   d = "Password and phone approval stay on Google's own page."},
  {t = "What the port saves",
   d = "Private Play session + APKs stay in minecraftbedrock-data."},
  {t = "First-use storage",
   d = "Optional browser uses about 700 MB once, then is reused."},
  {t = "Sign out",
   d = "Clears the Google session; keeps APKs and installed games."},
  {t = "Remove downloader",
   d = "Frees about 700 MB; keeps APKs, versions and worlds."},
  {t = "Experimental versions",
    d = "Every build Play still serves for this device; never auto-selected."},
}

local function abiTag(name)
  local has64 = fileExists(VERDIR .. "/" .. name .. "/lib/arm64-v8a/libminecraftpe.so")
  local has32 = fileExists(VERDIR .. "/" .. name .. "/lib/armeabi-v7a/libminecraftpe.so")
  if has64 and has32 then return "32/64-bit" end
  if has64 then return "64-bit" end
  if has32 then return "32-bit" end
  return "?"
end

local function prettySize(bytes)
  if bytes >= 1024 * 1024 * 1024 then
    return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
  end
  return string.format("%.0f MB", bytes / (1024 * 1024))
end

local function metadataField(name, key)
  local raw = readAll(VERDIR .. "/" .. name .. "/version.json")
  if not raw then return nil end
  return raw:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function rescan()
  versions = {}
  for _, name in ipairs(listDirs(VERDIR)) do
    local trusted = fileExists(VERDIR .. "/" .. name .. "/version.json")
    local tag = abiTag(name)
    local recommendation = trusted and metadataField(name, "recommendation") or nil
    local renderer = trusted and metadataField(name, "renderer_profile") or nil
    if recommendation == "recommended" then
      tag = tag .. ", recommended"
    elseif recommendation == "newest_tested_no_renderdragon" then
      tag = tag .. ", newest tested no-RenderDragon"
    elseif recommendation == "not_recommended" then
      tag = tag .. ", not recommended"
    elseif not trusted then
      tag = tag .. ", unverified legacy"
    end
    versions[#versions + 1] = {name = name, tag = tag, trusted = trusted,
                              recommendation = recommendation, renderer = renderer}
  end
  apks = {}
  for _, name in ipairs(listFiles(APKDIR, ".*")) do
    local lower = name:lower()
    if lower:match("%.apk$") or lower:match("%.apks$") or
       lower:match("%.apkm$") or lower:match("%.xapk$") or
       lower:match("%.zip$") then
      apks[#apks + 1] = {name = name, size = fileSize(APKDIR .. "/" .. name)}
    end
  end
  apkGroups = {}
  local groupIndex = readAll(CONFDIR .. "/apk-groups/index.tsv") or ""
  for line in groupIndex:gmatch("[^\r\n]+") do
    local id, title, desc, ready, untested =
      line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([01])\t?(.*)$")
    if id then
      local files = readAll(CONFDIR .. "/apk-groups/" .. id .. ".txt") or ""
      apkGroups[#apkGroups + 1] = {id=id, title=title, desc=desc,
                                  ready=(ready == "1"), files=files,
                                  untested=(untested ~= "" and untested or nil)}
    end
  end
  backups = {}
  for _, name in ipairs(listFiles(GAMEDIR .. "/backups", "%.tar%.gz")) do
    backups[#backups + 1] = {name = name, size = fileSize(GAMEDIR .. "/backups/" .. name)}
  end
end

-- "backup-20260709-213045.tar.gz" -> "2026-07-09 21:30"
local function backupLabel(name)
  local y, mo, d, h, mi = name:match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)")
  if y then
    return string.format("%s-%s-%s %s:%s", y, mo, d, h, mi)
  end
  return name
end

local function defaultVersion()
  -- Keep the usability-tested 1.16 build as the default even when newer
  -- diagnostic builds are installed. A remembered user selection still wins.
  for _, version in ipairs(versions) do
    if version.recommendation == "recommended" then return version end
  end
  for i = #versions, 1, -1 do
    if versions[i].trusted then return versions[i] end
  end
  return versions[#versions]
end

local function currentVersion()
  for _, v in ipairs(versions) do
    if v.name == settingsVersion then return v end
  end
  return defaultVersion()
end

-- --------------------------------------------------------------- actions --
local function quitWith(action, arg)
  saveSettings()
  writeAll(CONFDIR .. "/menu_action.txt", action .. "\n" .. (arg or "") .. "\n")
  love.event.quit(0)
end

-- Play keeps the fullscreen LAUNCHING screen alive while the shell prepares
-- the selected version and boots the client.  The shell closes this process
-- only after Minecraft's window exists, preventing the desktop/menu bar from
-- being exposed during the handoff. Input is ignored meanwhile.
local launching = nil   -- {name=, t=, frames=, signaled=}

local function beginLaunch(name)
  if not launching then
    launching = {name = name, t = 0, frames = 0}
  end
end

-- ------------------------------------------------------------- UI state --
local screen = "main"  -- main|versions|download|download_other|download_info|install|settings|backup|help|confirm
local sel = {main = 1, versions = 1, download = 1, download_other = 1,
             download_info = 1, install = 1, settings = 1, backup = 1,
             help = 1, confirm = 2}
local confirm = nil          -- {title, lines, danger, onYes, back, yesLabel}
local W, H, S                -- S = pixel scale unit
local fonts = {}
local ditherTile             -- tiny 8x8 checker, wrap=repeat (power-of-two)
local backdrop               -- dot grid + scanlines, one static SpriteBatch
local ditherQuad
local skyBands = {}          -- precomputed gradient band rects
local clock = 0
local embers = {}

local function mainItems()
  local cur = currentVersion()
  local items = {}
  items[#items + 1] = {
    id = "play", title = "Play", icon = "play",
    desc = cur and (cur.name .. "  [" .. cur.tag .. "]") or "no version installed",
    disabled = (cur == nil),
  }
  items[#items + 1] = {
    id = "versions", title = "Versions", icon = "versions",
    desc = #versions .. " installed",
    disabled = (#versions == 0),
  }
  items[#items + 1] = {
    id = "download", title = "Get APK from Google Play", icon = "download",
    desc = DOWNLOADER_SUPPORTED
      and ((DOWNLOADER_SESSION and "saved session | " or "Google sign-in required | ") ..
           (DOWNLOADER_RUNTIME and "browser ready | " or "one-time browser setup | ") ..
           "tested + experimental ARM builds")
      or "RG34XXSP/H700 + Knulli prototype only",
    disabled = not DOWNLOADER_SUPPORTED,
  }
  items[#items + 1] = {
    id = "install", title = "Install APK", icon = "install",
    desc = #apkGroups > 0 and (#apkGroups .. " metadata-matched set(s)") or "put APKs in ports/minecraftbedrock-data/apk",
    disabled = (#apkGroups == 0),
  }
  items[#items + 1] = {id = "settings", title = "Settings", icon = "settings",
                       desc = "FPS cap, render distance, client..."}
  items[#items + 1] = {
    id = "backup", title = "Backup", icon = "backup",
    desc = #backups > 0 and (#backups .. " backup(s) - worlds & settings")
                         or "back up worlds & settings",
  }
  items[#items + 1] = {id = "update", title = "Update port", icon = "update",
                       desc = "get the newest port version (WiFi)"}
  items[#items + 1] = {id = "support_bundle", title = "Support bundle", icon = "help",
                       desc = "save redacted device diagnostics locally"}
  items[#items + 1] = {id = "controller_test", title = "Controller test", icon = "settings",
                       desc = "sample buttons and stick axes locally"}
  items[#items + 1] = {id = "help", title = "Help", icon = "help",
                       desc = "quick troubleshooting"}
  items[#items + 1] = {id = "exit", title = "Exit", icon = "exit",
                       desc = "back to the games list", danger = true}
  return items
end

local function clampSel(which, count)
  if sel[which] > count then sel[which] = count end
  if sel[which] < 1 then sel[which] = 1 end
end

-- ------------------------------------------------------ pixel-art drawing --
local floor = math.floor

local function px(color, x, y, w, h)
  love.graphics.setColor(color)
  love.graphics.rectangle("fill", floor(x), floor(y), floor(w), floor(h))
end

-- Chunky beveled box. raised=true lights the top/left edge (button sticking
-- out); raised=false is the pressed/inset look.
local function bevelBox(x, y, w, h, base, raised, b)
  b = b or S
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  local lt = raised and COL.bevel_lt or COL.bevel_dk
  local dk = raised and COL.bevel_dk or COL.bevel_lt
  px(base, x, y, w, h)
  px(lt, x, y, w, b)          -- top
  px(lt, x, y, b, h)          -- left
  px(dk, x, y + h - b, w, b)  -- bottom
  px(dk, x + w - b, y, b, h)  -- right
end

-- Extruded 3D button: one hard outline wraps face + side as a solid slab,
-- lit top/left edge, and a darker bottom "side" strip `depth` units tall
-- that makes the button read as physically raised off the panel.
local function button3d(x, y, w, h, st, depth)
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  local d = floor((depth or 2) * S)
  px(st.edge, x - S, y - S, w + 2 * S, h + d + 2 * S)
  px(st.face, x, y, w, h)
  px(st.hi, x, y, w, S)                 -- top light
  px(st.hi, x, y, S, h)                 -- left light
  px(st.side, x + w - S, y + S, S, h - S)  -- right shade
  px(st.side, x, y + h, w, d)           -- extruded bottom side
end

-- 8x8 pixel icons for the main menu, drawn as rectangles ('X' = pixel on).
local ICONS = {
  play = {
    "X.......",
    "XXX.....",
    "XXXXX...",
    "XXXXXXX.",
    "XXXXXXX.",
    "XXXXX...",
    "XXX.....",
    "X.......",
  },
  versions = {   -- two stacked cards
    "..XXXXXX",
    "..X....X",
    "XXXXXX.X",
    "X....X.X",
    "X....XXX",
    "X....X..",
    "X....X..",
    "XXXXXX..",
  },
  install = {    -- arrow dropping into a tray
    "...XX...",
    "...XX...",
    ".XXXXXX.",
    "..XXXX..",
    "...XX...",
    "X......X",
    "X......X",
    "XXXXXXXX",
  },
  download = {   -- cloud and downward arrow
    ".XXXXXX.",
    "XX....XX",
    "X......X",
    "XXXXXXXX",
    "...XX...",
    ".XXXXXX.",
    "..XXXX..",
    "...XX...",
  },
  settings = {   -- gear
    "..X..X..",
    ".XXXXXX.",
    "XXX..XXX",
    ".X....X.",
    ".X....X.",
    "XXX..XXX",
    ".XXXXXX.",
    "..X..X..",
  },
  backup = {     -- save disk
    "XXXXXXX.",
    "X..XX.XX",
    "X..XX.XX",
    "X......X",
    "X.XXXX.X",
    "X.XXXX.X",
    "X.XXXX.X",
    "XXXXXXXX",
  },
  update = {     -- circular arrow
    "..XXXXX.",
    ".X....XX",
    "X....XXX",
    "X.......",
    "X.......",
    "X......X",
    ".X....X.",
    "..XXXX..",
  },
  help = {       -- question mark
    ".XXXXX..",
    "XX...XX.",
    ".....XX.",
    "....XX..",
    "...XX...",
    "...XX...",
    "........",
    "...XX...",
  },
  exit = {       -- power symbol
    "...XX...",
    ".X.XX.X.",
    "XX.XX.XX",
    "X..XX..X",
    "X......X",
    "XX....XX",
    ".XXXXXX.",
    "........",
  },
}

local function drawIcon(name, x, y, cell, color)
  local grid = ICONS[name]
  if not grid then return end
  love.graphics.setColor(color)
  for r = 1, #grid do
    local row = grid[r]
    for c = 1, #row do
      if row:sub(c, c) == "X" then
        love.graphics.rectangle("fill",
          floor(x + (c - 1) * cell), floor(y + (r - 1) * cell), cell, cell)
      end
    end
  end
end

-- Chamfered rectangle: a rect with its corners cut `c` deep. The octagonal
-- silhouette (plus grip lines and groove notches below) is what sets these
-- controls apart from strictly square chrome.
local function chamferBox(x, y, w, h, c, color)
  x, y, w, h, c = floor(x), floor(y), floor(w), floor(h), floor(c)
  px(color, x + c, y, w - 2 * c, h)
  px(color, x, y + c, w, h - 2 * c)
end

-- Toggle switch: chamfered track (44x20 units) with big I (on) / O (off)
-- marks and a tall chamfered knob with grip lines overhanging the track.
local function drawToggle(x, y, on, active)
  local w, h = 44 * S, 20 * S
  chamferBox(x - S, y - S, w + 2 * S, h + 2 * S, 3 * S, COL.outline)
  chamferBox(x, y, w, h, 3 * S, on and COL.accent_dk or COL.bevel_dk)
  if on then
    px(active and COL.accent_hi or COL.accent, x + 9 * S, y + 6 * S, 3 * S, 8 * S)  -- I
  else
    local oc = active and COL.dim or COL.faint
    local ox = x + w - 17 * S
    px(oc, ox, y + 6 * S, 8 * S, 8 * S)                                             -- O
    px(COL.bevel_dk, ox + 2 * S, y + 8 * S, 4 * S, 4 * S)
  end
  local kw, kh = 18 * S, 26 * S
  local kx = on and (x + w - kw) or x
  local ky = y + floor(h / 2) - floor(kh / 2)
  chamferBox(kx - S, ky - S, kw + 2 * S, kh + 2 * S, 2 * S, COL.outline)
  chamferBox(kx, ky, kw, kh, 2 * S, on and COL.accent or BTN.normal.hi)
  px(on and COL.accent_hi or COL.bevel_lt, kx + 2 * S, ky, kw - 4 * S, S)
  px(on and COL.accent_dk or BTN.normal.side, kx + 2 * S, ky + kh - 2 * S, kw - 4 * S, 2 * S)
  local gc = on and COL.accent_dk or COL.bevel_dk
  px(gc, kx + 6 * S, ky + 8 * S, 2 * S, 10 * S)    -- grip lines
  px(gc, kx + 10 * S, ky + 8 * S, 2 * S, 10 * S)
end

-- Slider: deep notched groove (8 units) with a two-tone striped accent fill
-- and a tall chamfered knob with grip lines riding on it.
local function drawSlider(x, y, w, pos, active)
  local gh = 8 * S
  px(COL.outline, x - S, y - S, w + 2 * S, gh + 2 * S)
  px(COL.bevel_dk, x, y, w, gh)
  local fw = floor(w * pos)
  if fw > 0 then
    local c1 = active and COL.accent_dk or {0.110, 0.240, 0.100}
    local c2 = active and {0.110, 0.300, 0.100} or {0.078, 0.176, 0.078}
    local band = 3 * S
    local i = 0
    for bx = 0, fw - 1, band do
      px(i % 2 == 0 and c1 or c2, x + bx, y, math.min(band, fw - bx), gh)
      i = i + 1
    end
  end
  for i = 1, 7 do    -- value notches along the groove
    px(COL.faint, x + floor(w * i / 8), y + gh - 2 * S, S, 2 * S)
  end
  local kw, kh = 14 * S, 26 * S
  local kx = x + floor((w - kw) * pos)
  local ky = y + floor(gh / 2) - floor(kh / 2)
  chamferBox(kx - S, ky - S, kw + 2 * S, kh + 2 * S, 3 * S, COL.outline)
  chamferBox(kx, ky, kw, kh, 3 * S, active and COL.accent or BTN.normal.hi)
  px(active and COL.accent_hi or COL.bevel_lt, kx + 3 * S, ky, kw - 6 * S, S)
  px(active and COL.accent_dk or BTN.normal.side, kx + 3 * S, ky + kh - 2 * S, kw - 6 * S, 2 * S)
  local gc = active and COL.accent_dk or COL.bevel_dk
  px(gc, kx + 4 * S, ky + 8 * S, 2 * S, 10 * S)    -- grip lines
  px(gc, kx + 8 * S, ky + 8 * S, 2 * S, 10 * S)
end

local function text(font, color, str, x, y, limit, align)
  love.graphics.setFont(font)
  love.graphics.setColor(color)
  love.graphics.printf(str, floor(x), floor(y), floor(limit or (W - x - 4 * S)), align or "left")
end

-- Pixel drop shadow: dark copy offset one unit down-right.
local function shadowText(font, color, str, x, y, limit, align)
  text(font, COL.bevel_dk, str, x + S, y + S, limit, align)
  text(font, color, str, x, y, limit, align)
end

-- Trim a string until it fits on one line. Header text that wraps drops its
-- tail onto the accent rule below, where it is unreadable; a shortened line
-- is always better than a second one. Narrow panels need this even when the
-- 720px screens have room.
local function fitText(font, str, maxw)
  if font:getWidth(str) <= maxw then return str end
  local s = str
  while #s > 1 and font:getWidth(s .. "...") > maxw do s = s:sub(1, #s - 1) end
  return s .. "..."
end

local function lerp(a, b, t) return a + (b - a) * t end

-- Posterized gradient sky drawn as plain batched rectangles every frame —
-- the only render path proven safe on this fbdev-mali GLES stack (Canvas/FBO
-- corrupts, full-res ImageData generation is too slow without JIT). The band
-- seams are softened with a tiny 8x8 power-of-two checker tile drawn with
-- wrap=repeat (one quad per seam).
local function buildBackground()
  local bands = 10
  skyBands = {}
  local bandH = math.ceil(H / bands)
  for i = 0, bands - 1 do
    local t = i / (bands - 1)
    skyBands[#skyBands + 1] = {
      y = i * bandH, h = bandH,
      c = {lerp(COL.sky_top[1], COL.sky_bottom[1], t),
           lerp(COL.sky_top[2], COL.sky_bottom[2], t),
           lerp(COL.sky_top[3], COL.sky_bottom[3], t)},
    }
  end
  local cell = 2
  local data = love.image.newImageData(8, 8)
  data:mapPixel(function(x, y)
    local on = ((floor(x / cell) + floor(y / cell)) % 2 == 0)
    return 1, 1, 1, on and 1 or 0
  end)
  ditherTile = love.graphics.newImage(data)
  ditherTile:setWrap("repeat", "repeat")
  ditherTile:setFilter("nearest", "nearest")
  ditherQuad = love.graphics.newQuad(0, 0, W, 4, 8, 8)
  -- The dot grid and scanlines never change for the life of the window, but
  -- drawing them as individual rectangles cost about 1500 draw calls every
  -- frame. Baked into one static SpriteBatch they cost one. A SpriteBatch is
  -- a vertex buffer, not a Canvas, so this stays off the FBO path that
  -- corrupts on this GLES stack.
  local dot = love.image.newImageData(1, 1)
  dot:setPixel(0, 0, 1, 1, 1, 1)
  local step = 16 * S
  local dots = math.floor(H / step) * math.floor(W / step)
  local lines = math.floor(H / 3) + 1
  backdrop = love.graphics.newSpriteBatch(love.graphics.newImage(dot),
                                          dots + lines + 8, "static")
  backdrop:setColor(1, 1, 1, 0.03)
  for y = step, H, step do
    for x = step, W, step do backdrop:add(x, y, 0, S, S) end
  end
  backdrop:setColor(0, 0, 0, 0.10)
  for y = 0, H, 3 do backdrop:add(0, y, 0, W, 1) end
end

local function drawBackground()
  -- gradient bands
  for _, band in ipairs(skyBands) do
    px(band.c, 0, band.y, W, band.h)
  end
  -- dithered seams: next band's color checkered over the band edge
  for i = 2, #skyBands do
    local band = skyBands[i]
    love.graphics.setColor(band.c[1], band.c[2], band.c[3], 1)
    love.graphics.draw(ditherTile, ditherQuad, 0, floor(band.y - 4))
  end
  -- dot grid and scanlines, baked at load into a single batch
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(backdrop)
end

local function initEmbers()
  embers = {}
  -- deterministic scatter (no RNG needed): golden-ratio spread
  for i = 1, 24 do
    local fx = (i * 0.6180339887) % 1
    local fy = (i * 0.7548776662) % 1
    embers[#embers + 1] = {
      x = fx * W,
      y = fy * H,
      spd = 4 + (i % 5) * 3,
      size = S + (i % 3),
      phase = i * 1.7,
    }
  end
end

local function drawEmbers()
  for _, e in ipairs(embers) do
    local tw = 0.5 + 0.5 * math.sin(clock * 1.3 + e.phase)
    love.graphics.setColor(COL.accent[1], COL.accent[2], COL.accent[3], 0.06 + 0.16 * tw)
    love.graphics.rectangle("fill", floor(e.x), floor(e.y), e.size, e.size)
  end
end

local blinkOn = true          -- chunky two-state blink, no smooth fades

-- ------------------------------------------------------ confirm/back keys --
-- Default = positional mapping (H700 family): SDL "b" is the button printed
-- A. Pads listed here have label-semantic mappings where SDL "a" IS the
-- printed A (user-verified per device).
local confirmBtn, backBtn = "b", "a"
local LABEL_SEMANTIC_GUIDS = {
  ["19000000010000000100000000010000"] = true,  -- RG34XXSP Scarab SDL override
  ["19009b4d4b4800000111000000010000"] = true,  -- RG DS retrogame_joypad
}

local function detectButtons()
  local override = os.getenv("MCPE_MENU_CONFIRM")
  if override == "a" or override == "b" then
    confirmBtn = override
    backBtn = (override == "a") and "b" or "a"
    return
  end
  local ok, js = pcall(function() return love.joystick.getJoysticks() end)
  if ok and js then
    for _, j in ipairs(js) do
      local gok, guid = pcall(function() return j:getGUID() end)
      if gok and LABEL_SEMANTIC_GUIDS[guid] then
        confirmBtn, backBtn = "a", "b"
        return
      end
    end
  end
end

-- ---------------------------------------------------------------- love.* --
function love.load()
  love.mouse.setVisible(false)
  W, H = love.graphics.getDimensions()
  S = math.max(1, floor(math.min(W / 640, H / 480) + 0.5))  -- pixel unit
  love.graphics.setBackgroundColor(COL.sky_top)  -- stale-fb safety net
  local fscale = math.min(W / 640, H / 480)
  fonts.title = love.graphics.newFont("font_titolo.ttf", floor(30 * fscale))
  fonts.item  = love.graphics.newFont("font_testo.ttf", floor(20 * fscale))
  fonts.small = love.graphics.newFont("font_testo.ttf", floor(14 * fscale))
  portVersion = (readAll(GAMEDIR .. "/PORT_VERSION") or ""):match("%S+") or ""
  detectButtons()
  buildBackground()
  initEmbers()
  loadSettings()
  rescan()
  if #versions > 0 then
    local remembered = nil
    for _, v in ipairs(versions) do
      if v.name == settingsVersion then remembered = v; break end
    end
    local fallback = defaultVersion()
    if not remembered or (not remembered.trusted and fallback.trusted) then
      settingsVersion = fallback.name
    end
  end
  -- Test hook (like MCPE_MENU_AUTOQUIT): open a given screen at startup so
  -- display tests can capture more than the main menu. Unset in normal use.
  local s = os.getenv("MCPE_MENU_SCREEN")
  if s and sel[s] and s ~= "confirm" then screen = s end
  if os.getenv("MCPE_REDIRECT_RGDS") == "1" then
    confirm = {
      title = "RGDS edition required", back = "main",
      yesLabel = "Install RGDS edition",
      lines = {"This device has the RGDS dual display.",
               "The lightweight standard build does not",
               "include its dual-screen runtime.",
               "Download the separate RGDS edition now?"},
      onYes = function() quitWith("install_rgds") end,
    }
    sel.confirm = 2
    screen = "confirm"
  end
end

-- Held D-pad repeat; defined with the input handlers further down, where
-- moveDirectional is in scope.
local tickRepeat

function love.update(dt)
  clock = clock + dt
  blinkOn = (clock % 0.8) < 0.5
  for _, e in ipairs(embers) do
    e.y = e.y - e.spd * dt
    if e.y < -4 then
      e.y = H + 4
      e.x = (e.x + 37 * S) % W
    end
  end
  if not launching then tickRepeat(dt) end
  if launching then
    launching.t = launching.t + dt
    launching.frames = launching.frames + 1
    -- Signal the background shell only after the overlay reached the front
    -- buffer, then continue drawing it until the game window is ready.
    if not launching.signaled and launching.frames >= 4 and launching.t >= 0.25 then
      saveSettings()
      writeAll(CONFDIR .. "/menu_action.txt", "play\n" .. launching.name .. "\n")
      launching.signaled = true
      if EXIT_ON_PLAY then love.event.quit(0) end
    end
  elseif AUTOQUIT and clock >= AUTOQUIT then
    quitWith("exit")
  end
end

-- chrome: background, header bar, accent rule. Returns content top.
local function drawChrome(subtitle)
  drawBackground()
  drawEmbers()

  -- header as an extruded slab: lit top edge, accent bottom side
  local hh = floor(H * 0.135)
  px(COL.panel, 0, 0, W, hh)
  px(COL.bevel_lt, 0, 0, W, S)
  shadowText(fonts.title, COL.accent_hi, "MINECRAFT BEDROCK", 8 * S, hh * 0.14)
  -- Version tag: always one line. Wrapped, its tail lands on the accent rule
  -- below and is unreadable, so shed the "PORT " prefix before the version
  -- itself and reserve its width from the subtitle beside it.
  local fsm, vw, vlabel = fonts.small, 0, nil
  if portVersion ~= "" then
    vlabel = "PORT " .. portVersion:upper()
    if fsm:getWidth(vlabel) > W * 0.42 then vlabel = portVersion:upper() end
    vlabel = fitText(fsm, vlabel, W * 0.42)
    vw = fsm:getWidth(vlabel)
  end
  text(fsm, COL.dim, fitText(fsm, subtitle, W - 26 * S - vw),
       9 * S, hh * 0.62, W - 26 * S - vw)
  if vlabel then
    text(fsm, COL.faint, vlabel, W - 8 * S - vw,
         math.min(hh * 0.62, hh - fsm:getHeight() - 2 * S), vw + 2 * S)
  end
  px(COL.accent, 0, hh, W, 2 * S)
  px(COL.accent_dk, 0, hh + 2 * S, W, S)
  px(COL.outline, 0, hh + 3 * S, W, S)
  return hh + 4 * S
end

-- footer: beveled bar with 3D keycaps + status
local function drawHints(hints)
  local fh = floor(H * 0.08)
  local y0 = H - fh
  bevelBox(0, y0, W, fh, COL.panel, true)
  local fsm = fonts.small
  love.graphics.setFont(fsm)
  local ty = y0 + floor((fh - fsm:getHeight()) / 2)
  local x = 8 * S
  for _, hint in ipairs(hints) do
    local key, label = hint[1], hint[2]
    local kw = fsm:getWidth(key) + 6 * S
    local kh = fsm:getHeight() + S
    -- mini 3D keycap
    px(COL.outline, x - S, ty - 2 * S, kw + 2 * S, kh + 5 * S)
    px(COL.accent, x, ty - S, kw, kh)
    px(COL.accent_hi, x, ty - S, kw, S)
    px(COL.accent_dk, x, ty - S + kh, kw, 2 * S)
    love.graphics.setColor(COL.outline)
    love.graphics.print(key, floor(x + 3 * S), floor(ty))
    x = x + kw + 4 * S
    love.graphics.setColor(COL.dim)
    love.graphics.print(label, floor(x), floor(ty))
    x = x + fsm:getWidth(label) + 10 * S
  end
  if STATUS ~= "" then
    text(fsm, COL.warn, STATUS, W * 0.5, ty, W * 0.5 - 6 * S, "right")
  end
end

-- generic row list drawn as chunky 3D buttons.
-- items = {title=, desc=, value=, disabled=, danger=, icon=,
--          slider={pos=0..1, label=}, toggle=true/false}
local function drawList(top, items, selected, opts)
  opts = opts or {}
  local ih, sh = fonts.item:getHeight(), fonts.small:getHeight()
  local hasDesc = false
  for _, it in ipairs(items) do
    if it.desc and it.desc ~= "" then hasDesc = true break end
  end
  -- A row is never shorter than the text it holds. Fractions of the screen
  -- height alone gave 33px rows for two lines needing 37, so the second line
  -- ran through the row's own border and under the first one.
  local minRow = (hasDesc and (ih + sh) or ih) + 8 * S
  local rowH = math.max(floor(H * (opts.rowH or 0.115)), minRow)
  local x, w = floor(W * 0.05), floor(W * 0.90)
  -- Strip above the list for the position counter, always reserved so the
  -- row geometry does not shift when a list grows past one screen.
  local gap = math.max(floor(H * 0.022), sh + 3 * S)
  local listH = H - top - gap - floor(H * 0.08)
  local visible = math.max(1, floor(listH / rowH))
  local first = math.max(1, math.min(selected - floor(visible / 2),
                                     #items - visible + 1))
  local y = top + gap
  for i = first, math.min(#items, first + visible - 1) do
    local it = items[i]
    local isSel = (i == selected)
    local bh = rowH - 6 * S
    local by = isSel and (y - S) or y   -- the selected button lifts slightly
    local st = isSel and (it.danger and BTN.dangerSel or BTN.selected)
                      or BTN.normal
    -- Title and description are stacked by font metrics and centred as one
    -- block, so neither line can overlap the other or cross the row border.
    local blockH = (it.desc and it.desc ~= "") and (ih + sh) or ih
    local ty0 = by + floor((bh - blockH) / 2)
    button3d(x, by, w, bh, st, isSel and 3 or 2)
    local tx = x + 18 * S
    if it.icon then
      local cell = 2 * S
      local icol = it.disabled and COL.faint
          or (isSel and (it.danger and COL.danger or COL.accent_hi) or COL.dim)
      drawIcon(it.icon, x + 8 * S, by + floor(bh / 2) - 4 * cell, cell, icol)
      tx = x + 31 * S
    elseif isSel and blinkOn then
      text(fonts.item, it.danger and COL.danger or COL.accent,
           ">", x + 5 * S, ty0)
    end
    -- right-hand widget first, so the row's text can stop short of it
    local wleft = x + w - 12 * S
    if it.slider then
      local sw = floor(w * 0.30)
      local sx = x + w - sw - 12 * S
      drawSlider(sx, by + floor(bh / 2) - 4 * S, sw, it.slider.pos, isSel)
      text(fonts.small, isSel and COL.accent_hi or COL.dim, it.slider.label,
           tx, ty0 + floor((ih - sh) / 2), sx - tx - 14 * S, "right")
      wleft = sx - 14 * S
    elseif it.toggle ~= nil then
      local wx = x + w - 56 * S
      drawToggle(wx, by + floor(bh / 2) - 10 * S, it.toggle, isSel)
      wleft = wx - 12 * S
    elseif it.value then
      local vcol = isSel and COL.accent_hi or COL.dim
      text(fonts.item, vcol, "< " .. it.value .. " >",
           tx, ty0, x + w - tx - 12 * S, "right")
    end
    local mainCol = it.disabled and COL.faint
        or (it.danger and (isSel and COL.danger or COL.danger_dk)
        or (isSel and COL.fg or COL.dim))
    -- One line each: the row is sized for exactly two, so anything that
    -- wrapped would push out through the border. Trim instead -- a build's
    -- warnings are shown in full on the confirmation screen.
    text(fonts.item, mainCol, fitText(fonts.item, it.title, wleft - tx),
         tx, ty0, wleft - tx)
    if it.desc and it.desc ~= "" then
      text(fonts.small, isSel and COL.dim or COL.faint,
           fitText(fonts.small, it.desc, wleft - tx), tx, ty0 + ih, wleft - tx)
    end
    y = y + rowH
  end
  if #items > visible then
    -- Right-aligned to the list frame, not the screen edge, and lifted clear
    -- of the first row: it used to be drawn straight through the border.
    text(fonts.small, COL.faint,
         string.format("%d/%d", selected, #items),
         x + w - 80 * S, top + S, 80 * S, "right")
  end
end

-- Downloader actions are intentionally a fixed two-column tile surface. On a
-- handheld this makes focus location obvious and gives every action a large
-- target; the Google web view uses the same D-pad/A focus model afterward.
local function drawTileGrid(top, items, selected)
  local cols, perPage = 2, 4
  local page = floor((selected - 1) / perPage)
  local first = page * perPage + 1
  local last = math.min(#items, first + perPage - 1)
  local gap = 12 * S
  local x0 = floor(W * 0.05)
  local gridW = floor(W * 0.90)
  local tileW = floor((gridW - gap) / cols)
  local y0 = top + 12 * S
  local bottom = H - floor(H * 0.08) - 8 * S
  -- Keep tile geometry stable across pages; a two-item final page should not
  -- suddenly turn into two full-height slabs.
  local rows = 2
  local tileH = floor((bottom - y0 - gap * (rows - 1)) / rows)

  for i = first, last do
    local it = items[i]
    local slot = i - first
    local col = slot % cols
    local row = floor(slot / cols)
    local x = x0 + col * (tileW + gap)
    local y = y0 + row * (tileH + gap)
    local isSel = (i == selected)
    local st = isSel and (it.danger and BTN.dangerSel or BTN.selected)
                      or BTN.normal
    button3d(x, isSel and (y - S) or y, tileW, tileH - 3 * S,
             st, isSel and 4 or 2)
    local faceY = isSel and (y - S) or y
    local mainCol = it.disabled and COL.faint
        or (it.danger and (isSel and COL.danger or COL.danger_dk)
        or (isSel and COL.fg or COL.dim))
    local iconCol = it.disabled and COL.faint
        or (isSel and (it.danger and COL.danger or COL.accent_hi) or COL.dim)
    drawIcon(it.icon or "download", x + 12 * S, faceY + 14 * S,
             3 * S, iconCol)
    text(fonts.item, mainCol, it.title,
         x + 43 * S, faceY + 13 * S, tileW - 54 * S)
    if it.desc and it.desc ~= "" then
      text(fonts.small, isSel and COL.dim or COL.faint, it.desc,
           x + 12 * S, faceY + 58 * S, tileW - 24 * S)
    end
    if isSel then
      text(fonts.small, it.danger and COL.danger or COL.accent_hi,
           "SELECTED", x + 12 * S, faceY + tileH - 29 * S,
           tileW - 24 * S, "right")
    end
  end
  if #items > perPage then
    text(fonts.small, COL.faint,
         string.format("PAGE %d/%d", page + 1, math.ceil(#items / perPage)),
         W - 118 * S, H - 27 * S, 100 * S, "right")
  end
end

local function drawLaunchOverlay()
  px({0, 0, 0, 0.78}, 0, 0, W, H)
  local bw, bh = floor(W * 0.62), floor(H * 0.30)
  local bx, by = floor((W - bw) / 2), floor((H - bh) / 2)
  px(COL.accent, bx - S, by - S, bw + 2 * S, bh + 2 * S)
  bevelBox(bx, by, bw, bh, COL.panel, true)
  px(COL.accent_dk, bx, by, bw, 3 * S)
  shadowText(fonts.item, COL.accent_hi, "LAUNCHING", bx, by + 8 * S, bw, "center")
  text(fonts.item, COL.fg, launching.name, bx, by + floor(bh * 0.36), bw, "center")
  text(fonts.small, COL.dim, "loading the game - this can take a while",
       bx, by + floor(bh * 0.60), bw, "center")
  -- slider-style loading knob sweeping the groove; it freezes mid-run once
  -- the menu hands the frame over to the game boot, which still reads as
  -- "working" rather than "hung".
  local sw = floor(bw * 0.68)
  local x0 = bx + floor((bw - sw) / 2)
  local ybar = by + bh - 22 * S
  local t = (clock * 0.8) % 2
  drawSlider(x0, ybar, sw, t < 1 and t or 2 - t, true)
end

function love.draw()
  if not firstFrameReported then
    firstFrameReported = true
    writeAll(CONFDIR .. "/menu_first_frame.txt", "ready\n")
  end
  if screen == "confirm" and confirm then
    drawChrome(confirm.title)
    local bw, bh = floor(W * 0.74), floor(H * 0.46)
    local bx, by = floor((W - bw) / 2), floor((H - bh) / 2)
    local edge = confirm.danger and COL.danger or COL.accent
    px(edge, bx - S, by - S, bw + 2 * S, bh + 2 * S)
    bevelBox(bx, by, bw, bh, COL.panel, true)
    px(confirm.danger and COL.danger_dk or COL.accent_dk, bx, by, bw, 3 * S)
    local bodyFont = (#confirm.lines > 3) and fonts.small or fonts.item
    local y = by + 8 * S
    for _, line in ipairs(confirm.lines) do
      local bodyWidth = bw - 16 * S
      local _, wrapped = bodyFont:getWrap(line, bodyWidth)
      text(bodyFont, COL.fg, line, bx + 8 * S, y, bodyWidth)
      y = y + bodyFont:getHeight() * math.max(1, #wrapped) * 1.15 + 2 * S
    end
    local options = {
      {title = "No, go back"},
      {title = confirm.yesLabel or "Yes", danger = confirm.danger},
    }
    local rowH = floor(H * 0.09)
    local ly = by + bh - 2 * rowH - 6 * S
    for i, it in ipairs(options) do
      local isSel = (i == sel.confirm)
      local oy = ly + (i - 1) * rowH
      local oh = rowH - 6 * S
      local st = isSel and (it.danger and BTN.dangerSel or BTN.selected)
                        or BTN.normal
      button3d(bx + 8 * S, oy, bw - 16 * S, oh, st, isSel and 3 or 2)
      if isSel and blinkOn then
        text(fonts.item, it.danger and COL.danger or COL.accent,
             ">", bx + 13 * S, oy + rowH * 0.14)
      end
      text(fonts.item,
           it.danger and (isSel and COL.danger or COL.danger_dk)
             or (isSel and COL.fg or COL.dim),
           it.title, bx + 26 * S, oy + rowH * 0.14, bw - 46 * S)
    end
    drawHints({{"A", "choose"}, {"B", "back"}})
    return
  end

  if screen == "main" then
    local top = drawChrome("Port launcher")
    drawList(top, mainItems(), sel.main, {rowH = 0.096})
    drawHints({{"A", "select"}, {"^v", "navigate"}})
  elseif screen == "versions" then
    local top = drawChrome("Installed versions - A: play this, X: delete")
    local items = {}
    for _, v in ipairs(versions) do
      items[#items + 1] = {
        title = v.name .. (v.name == settingsVersion and "  *" or ""),
        desc = v.tag .. (v.name == settingsVersion and "   (current)" or ""),
      }
    end
    drawList(top, items, sel.versions)
    drawHints({{"A", "select"}, {"X", "delete"}, {"B", "back"}})
  elseif screen == "install" then
    local top = drawChrome("Install a complete metadata-matched APK set")
    local items = {}
    for _, group in ipairs(apkGroups) do
      items[#items + 1] = {title = group.title,
                           desc = (group.ready and "" or "[BLOCKED] ") .. group.desc}
    end
    drawList(top, items, sel.install)
    drawHints({{"A", "install"}, {"X", "delete file"}, {"B", "back"}})
  elseif screen == "download" then
    local top = drawChrome("Google Play - purchased copy, private session, APKs stay local")
    local items = {}
    for _, entry in ipairs(DOWNLOADS) do
      items[#items + 1] = {title = entry.title, desc = entry.desc, icon = "download"}
    end
    items[#items + 1] = {
      title = "Other versions [EXPERIMENTAL]",
      desc = "EVERY VERSION | ARM64 + ARM32 releases/previews; untested.",
      icon = "versions",
    }
    items[#items + 1] = {
      title = "How sign-in and storage work",
      desc = "PRIVATE + OPTIONAL | Google owns the form; first use needs ~700 MB.",
      icon = "help",
    }
    items[#items + 1] = {
      title = "Sign out of Google Play",
      desc = DOWNLOADER_SESSION
        and "PRIVACY | Remove only the saved account session; keep APKs and game."
        or "NO SAVED SESSION | Google will ask you to sign in before downloading.",
      disabled = not DOWNLOADER_SESSION,
      icon = "exit",
    }
    items[#items + 1] = {
      title = "Remove optional downloader",
      desc = "FREE ~700 MB | Remove browser, keyboard and session; keep APKs/game.",
      danger = true,
      icon = "exit",
    }
    drawTileGrid(top, items, sel.download)
    drawHints({{"A", "choose"}, {"D-PAD", "move"}, {"B", "back"}})
  elseif screen == "download_other" then
    local builds = currentOtherDownloads()
    local architecture = downloadOtherAbi == "armhf" and "ARM32" or "ARM64"
    local channel = downloadOtherChannel == "preview" and "PREVIEWS/BETAS" or "RELEASES"
    local top = drawChrome(string.format(
      "All %s %s - %d builds - experimental", architecture, channel, #builds))
    local items = {}
    for _, entry in ipairs(builds) do
      items[#items + 1] = {title = entry.title, desc = entry.desc, icon = "download"}
    end
    drawList(top, items, sel.download_other, {rowH = 0.082})
    drawHints({{"A", "download"}, {"<>", "ARM64/32"}, {"X", "release/beta"}, {"B", "back"}})
  elseif screen == "download_info" then
    local top = drawChrome("How Google sign-in, private storage and removal work")
    local items = {}
    for _, entry in ipairs(DOWNLOAD_INFO) do
      items[#items + 1] = {title = entry.t, desc = entry.d}
    end
    -- This is a readable reference page, not a menu: all six rows fit on the
    -- 720x480 reference panel, so do not imply that its text is selectable.
    drawList(top, items, 0, {rowH = 0.105})
    drawHints({{"B", "back to downloads"}})
  elseif screen == "settings" then
    local top = drawChrome("Settings - saved instantly, applied on every launch")
    local items = {}
    for _, row in ipairs(SCHEMA) do
      local it = {title = row.label,
                  desc = (sel.settings == #items + 1) and row.help or nil}
      local i, n = settingIndex(row), #row.values
      if row.widget == "slider" then
        it.slider = {pos = (n > 1) and ((i - 1) / (n - 1)) or 0,
                     label = settingName(row)}
      elseif row.widget == "toggle" then
        it.toggle = (settings[row.key] == "1")
      else
        it.value = settingName(row)
      end
      items[#items + 1] = it
    end
    drawList(top, items, sel.settings, {rowH = 0.096})
    drawHints({{"<>", "change"}, {"B", "back"}})
  elseif screen == "backup" then
    local top = drawChrome("Backups of worlds, settings and profiles")
    local items = {{title = "Create new backup",
                    desc = "archives profiles/ (worlds, options) + menu settings"}}
    for _, b in ipairs(backups) do
      items[#items + 1] = {title = backupLabel(b.name),
                           desc = prettySize(b.size) .. "   " .. b.name}
    end
    drawList(top, items, sel.backup)
    drawHints({{"A", "create/restore"}, {"X", "delete"}, {"B", "back"}})
  elseif screen == "help" then
    local top = drawChrome("Help - quick troubleshooting")
    local items = {}
    for _, h in ipairs(HELP) do
      items[#items + 1] = {title = h.t, desc = h.d}
    end
    drawList(top, items, sel.help, {rowH = 0.105})
    drawHints({{"^v", "scroll"}, {"B", "back"}})
  end

  if launching then drawLaunchOverlay() end

  if SHOT_PATH and not shotDone then
    shotFrames = shotFrames + 1
    if shotFrames >= SHOT_AT then
      shotDone = true
      love.graphics.captureScreenshot(function(img)
        local fh = io.open(SHOT_PATH, "wb")
        if fh then fh:write(img:encode("png"):getString()); fh:close() end
      end)
    end
  end
end

-- input ----------------------------------------------------------------------
local function adjustSetting(dir)
  local row = SCHEMA[sel.settings]
  if not row then return end
  local i = settingIndex(row) + dir
  if i < 1 then i = #row.values end
  if i > #row.values then i = 1 end
  settings[row.key] = row.values[i]
  saveSettings()
end

local function confirmDownload(entry, backScreen)
  local architecture = entry.abi == "armhf" and "32-bit armeabi-v7a" or "64-bit arm64-v8a"
  confirm = {
    title = "Download " .. entry.title, back = backScreen,
    yesLabel = "Continue to Google sign-in",
    lines = {architecture .. " | Play code " .. entry.code,
             entry.warning,
             "First use needs about 700 MB for the optional browser.",
             "Google handles password/approval; session and APKs stay local."},
    onYes = function() quitWith("download_apk", entry.code .. ":" .. entry.abi) end,
  }
  sel.confirm = 1
  screen = "confirm"
end

local function activate()
  if screen == "confirm" then
    if sel.confirm == 2 and confirm and confirm.onYes then
      confirm.onYes()
    else
      screen = confirm and confirm.back or "main"
      confirm = nil
    end
    return
  end
  if screen == "main" then
    local it = mainItems()[sel.main]
    if not it or it.disabled then return end
    if it.id == "play" then
      local cur = currentVersion()
      if cur then beginLaunch(cur.name) end
    elseif it.id == "exit" then
      quitWith("exit")
    elseif it.id == "update" then
      confirm = {
        title = "Update port", back = "main",
        yesLabel = "Yes, update now",
        lines = {"Download and install the newest",
                 "port version? Needs WiFi.",
                 "Worlds and settings are kept."},
        onYes = function() quitWith("update") end,
      }
      sel.confirm = 1
      screen = "confirm"
    elseif it.id == "support_bundle" then
      quitWith("support_bundle")
    elseif it.id == "controller_test" then
      confirm = {
        title = "Controller test", back = "main",
        yesLabel = "Start 8-second test",
        lines = {"Press every button and move both sticks.",
                 "Results stay local in logs/controller-test.txt."},
        onYes = function() quitWith("controller_test") end,
      }
      sel.confirm = 1
      screen = "confirm"
    else
      screen = it.id
      clampSel(screen, math.huge)
    end
  elseif screen == "backup" then
    if sel.backup == 1 then
      quitWith("backup_create")
    else
      local b = backups[sel.backup - 1]
      if b then
        confirm = {
          title = "Restore backup", danger = true, back = "backup",
          yesLabel = "Yes, restore this backup",
          lines = {"Restore backup from " .. backupLabel(b.name) .. "?",
                   "Current worlds and settings will be",
                   "overwritten with the backed-up copies."},
          onYes = function() quitWith("backup_restore", b.name) end,
        }
        sel.confirm = 1
        screen = "confirm"
      end
    end
  elseif screen == "versions" then
    local v = versions[sel.versions]
    if v then
      settingsVersion = v.name
      beginLaunch(v.name)
    end
  elseif screen == "install" then
    local group = apkGroups[sel.install]
    if group and group.ready then
      if group.untested then
        -- Asked here, before anything is unpacked: the installer used to
        -- refuse these only after extracting the whole build.
        confirm = {
          title = "Untested: " .. group.title, back = "install",
          yesLabel = "Install it anyway",
          lines = {group.untested .. ".",
                   "Nobody has run this build on this port, so it",
                   "may fail to install, or install and not start.",
                   "Your other installed versions are not touched."},
          onYes = function()
            writeAll(CONFDIR .. "/install_request.txt", group.files)
            quitWith("install_untested")
          end,
        }
        sel.confirm = 2
        screen = "confirm"
      else
        writeAll(CONFDIR .. "/install_request.txt", group.files)
        quitWith("install")
      end
    end
  elseif screen == "download" then
    local entry = DOWNLOADS[sel.download]
    if entry then
      confirmDownload(entry, "download")
    elseif sel.download == #DOWNLOADS + 1 then
      screen = "download_other"
      clampSel("download_other", #currentOtherDownloads())
    elseif sel.download == #DOWNLOADS + 2 then
      screen = "download_info"
      clampSel("download_info", #DOWNLOAD_INFO)
    elseif sel.download == #DOWNLOADS + 3 and DOWNLOADER_SESSION then
      confirm = {
        title = "Sign out", danger = true, back = "download",
        yesLabel = "Yes, remove saved session",
        lines = {"Remove the saved Google Play session?",
                 "Downloaded APKs and installed game stay."},
        onYes = function() quitWith("downloader_signout") end,
      }
      sel.confirm = 1
      screen = "confirm"
    elseif sel.download == #DOWNLOADS + 4 then
      confirm = {
        title = "Remove downloader", danger = true, back = "download",
        yesLabel = "Yes, remove optional files",
        lines = {"Remove browser, keyboard and session?",
                 "Downloaded APKs and installed game stay."},
        onYes = function() quitWith("downloader_remove") end,
      }
      sel.confirm = 1
      screen = "confirm"
    end
  elseif screen == "download_other" then
    local entry = currentOtherDownloads()[sel.download_other]
    if entry then confirmDownload(entry, "download_other") end
  elseif screen == "settings" then
    adjustSetting(1)
  end
end

local function contextDelete()
  if screen == "download_other" then
    downloadOtherChannel = downloadOtherChannel == "release" and "preview" or "release"
    sel.download_other = 1
  elseif screen == "backup" then
    local b = backups[sel.backup - 1]
    if not b then return end
    confirm = {
      title = "Delete backup", danger = true, back = "backup",
      yesLabel = "Yes, delete the backup",
      lines = {"Delete the backup from " .. backupLabel(b.name) .. "?",
               "Current worlds are not affected."},
      onYes = function() quitWith("backup_delete", b.name) end,
    }
    sel.confirm = 1
    screen = "confirm"
  elseif screen == "versions" then
    local v = versions[sel.versions]
    if not v then return end
    confirm = {
      title = "Delete version", danger = true, back = "versions",
      yesLabel = "Yes, delete " .. v.name,
      lines = {"Delete version '" .. v.name .. "'?",
               "Frees the extracted game files.",
               "Your worlds (profiles/) are kept."},
      onYes = function() quitWith("delete", v.name) end,
    }
    sel.confirm = 1
    screen = "confirm"
  elseif screen == "install" then
    local group = apkGroups[sel.install]
    if not group then return end
    confirm = {
      title = "Delete APK set", danger = true, back = "install",
      yesLabel = "Yes, delete these files",
      lines = {"Delete files for '" .. group.title .. "'?",
               "Only do this after a successful install."},
      onYes = function() quitWith("delete_apk_group", group.id) end,
    }
    sel.confirm = 1
    screen = "confirm"
  end
end

local function goBack()
  if screen == "confirm" then
    screen = confirm and confirm.back or "main"
    confirm = nil
  elseif screen == "main" then
    quitWith("exit")
  elseif screen == "download_other" or screen == "download_info" then
    screen = "download"
  else
    screen = "main"
  end
end

local function move(dir)
  local counts = {
    main = #mainItems(), versions = #versions,
    download = #DOWNLOADS + 4,
    download_other = #currentOtherDownloads(),
    download_info = 1,
    install = #apkGroups,
    settings = #SCHEMA, confirm = 2,
    backup = #backups + 1, help = #HELP,
  }
  local n = counts[screen] or 1
  if n < 1 then return end
  sel[screen] = sel[screen] + dir
  if sel[screen] < 1 then sel[screen] = n end
  if sel[screen] > n then sel[screen] = 1 end
end

local function moveDownloadTile(which, n, dx, dy)
  local cols = 2
  local current = sel[which]
  local row = floor((current - 1) / cols)
  local col = (current - 1) % cols
  if dx ~= 0 then
    local rowLength = math.min(cols, n - row * cols)
    col = (col + dx + rowLength) % rowLength
    sel[which] = row * cols + col + 1
    return
  end
  local rows = math.ceil(n / cols)
  repeat
    row = (row + dy + rows) % rows
    current = row * cols + col + 1
  until current <= n
  sel[which] = current
end

local function moveDirectional(direction)
  local tiled = screen == "download"
  local tileCount = #DOWNLOADS + 4
  if direction == "up" then
    if tiled then moveDownloadTile(screen, tileCount, 0, -1) else move(-1) end
  elseif direction == "down" then
    if tiled then moveDownloadTile(screen, tileCount, 0, 1) else move(1) end
  elseif direction == "left" then
    if tiled then moveDownloadTile(screen, tileCount, -1, 0)
    elseif screen == "download_other" then
      downloadOtherAbi = downloadOtherAbi == "arm64" and "armhf" or "arm64"
      sel.download_other = 1
    elseif screen == "settings" then adjustSetting(-1) end
  elseif direction == "right" then
    if tiled then moveDownloadTile(screen, tileCount, 1, 0)
    elseif screen == "download_other" then
      downloadOtherAbi = downloadOtherAbi == "arm64" and "armhf" or "arm64"
      sel.download_other = 1
    elseif screen == "settings" then adjustSetting(1) end
  end
end

-- Held up/down repeats. The version browser is over a hundred rows deep and
-- stepping it one press at a time is unusable. This polls rather than pairing
-- press with release events, because the same D-pad reaches us as keyboard,
-- gamepad or raw hat depending on the device profile, and a missed release on
-- any one of those paths would leave the list scrolling by itself.
-- Left/right is deliberately excluded: it toggles ARM64/ARM32, which must not
-- flip back and forth while a direction is held.
local REPEAT_DELAY, REPEAT_RATE = 0.35, 0.10
local REPEAT_RAMP, REPEAT_FAST = 1.2, 0.04
local repeatDir, repeatWait, repeatHeld = nil, 0, 0

local function heldDirection()
  if love.keyboard.isDown("up") then return "up" end
  if love.keyboard.isDown("down") then return "down" end
  for _, js in ipairs(love.joystick.getJoysticks()) do
    local ok, mapped = pcall(function() return js:isGamepad() end)
    if ok and mapped then
      if js:isGamepadDown("dpup") then return "up" end
      if js:isGamepadDown("dpdown") then return "down" end
    else
      local hatOk, dir = pcall(function() return js:getHat(1) end)
      if hatOk and type(dir) == "string" then
        if dir:find("u", 1, true) then return "up" end
        if dir:find("d", 1, true) then return "down" end
      end
    end
  end
  return nil
end

-- The first step comes from the press callback, so the timer starts at the
-- long delay: a tap never moves twice.
function tickRepeat(dt)
  local dir = heldDirection()
  if dir ~= repeatDir then
    repeatDir, repeatWait, repeatHeld = dir, REPEAT_DELAY, 0
  elseif dir then
    repeatHeld = repeatHeld + dt
    repeatWait = repeatWait - dt
    if repeatWait <= 0 then
      moveDirectional(dir)
      repeatWait = (repeatHeld > REPEAT_RAMP) and REPEAT_FAST or REPEAT_RATE
    end
  end
end

function love.keypressed(key)
  if launching then return end
  if key == "up" or key == "down" or key == "left" or key == "right" then
    moveDirectional(key)
  elseif key == "return" or key == "space" then activate()
  elseif key == "x" then contextDelete()
  elseif key == "escape" or key == "backspace" then goBack()
  end
end

-- confirmBtn/backBtn are resolved per pad GUID in detectButtons().
function love.gamepadpressed(_, button)
  if launching then return end
  if button == "dpup" then moveDirectional("up")
  elseif button == "dpdown" then moveDirectional("down")
  elseif button == "dpleft" then moveDirectional("left")
  elseif button == "dpright" then moveDirectional("right")
  elseif button == confirmBtn or button == "start" then activate()
  elseif button == "y" or button == "x" then contextDelete()
  elseif button == backBtn or button == "back" then goBack()
  end
end

-- Safety net for firmware SDL builds that expose the pad as a Joystick but do
-- not apply its GameController mapping. LOVE numbers raw buttons from 1; the
-- verified RG34XXSP mapping is printed A=b0, printed B=b1, X=b2, Y=b3,
-- Start=b7 and D-pad=hat 1. Ignore this path once SDL recognizes the gamepad,
-- otherwise one press would generate both raw and mapped callbacks.
local function needsRawPadFallback(joystick)
  local ok, mapped = pcall(function() return joystick:isGamepad() end)
  return not ok or not mapped
end

function love.joystickpressed(joystick, button)
  if launching or not needsRawPadFallback(joystick) then return end
  if button == 1 or button == 8 then activate()
  elseif button == 2 then goBack()
  elseif button == 3 or button == 4 then contextDelete() end
end

function love.joystickhat(joystick, hat, direction)
  if launching or not needsRawPadFallback(joystick) or hat ~= 1 then return end
  if direction:find("u", 1, true) then moveDirectional("up")
  elseif direction:find("d", 1, true) then moveDirectional("down")
  elseif direction:find("l", 1, true) then moveDirectional("left")
  elseif direction:find("r", 1, true) then moveDirectional("right") end
end

-- A lua error must never leave the device on LOVE's blue error screen with no
-- pad handling: record it and quit, so the shell can fall back to autoplay.
function love.errorhandler(msg)
  pcall(function()
    writeAll(CONFDIR .. "/menu_error.txt",
             tostring(msg) .. "\n" .. debug.traceback())
  end)
  return function() return 1 end
end
