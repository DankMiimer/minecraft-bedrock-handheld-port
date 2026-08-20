-- Fullscreen progress surface for Knulli/fbdev. A real LOVE frame replaces the
-- launcher's retained GPU frame; tty text alone is hidden while the VT remains
-- in graphics mode. The file protocol contains no account data or tokens.
local progressPath = os.getenv("MCPE_PROGRESS_FILE") or ""
local kind = os.getenv("MCPE_PROGRESS_KIND") or "download"
local exitInteractive = os.getenv("MCPE_PROGRESS_EXIT_INTERACTIVE") == "1"

local pct, mode = 1, "active"
local heading = kind == "install" and "Installing game files" or "Starting Google Play downloader"
local detail = "Preparing..."
local elapsed, sampleClock = 0, 0
local W, H
local titleFont, headingFont, bodyFont, smallFont

local function readFirstLine(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local line = file:read("*l")
  file:close()
  return line
end

local function refresh()
  local line = readFirstLine(progressPath)
  if not line or line == "" then return end
  if line:find("|", 1, true) then
    local p, m, h, d = line:match("^(%d+)|([^|]+)|([^|]*)|(.*)$")
    if p then
      pct = math.max(0, math.min(100, tonumber(p) or pct))
      mode, heading, detail = m, h ~= "" and h or heading, d ~= "" and d or detail
    end
  else
    local p, d = line:match("^(%d+)%s+(.+)$")
    if p then
      pct = math.max(0, math.min(100, tonumber(p) or pct))
      heading = "Installing game files"
      detail = d
      mode = "active"
    end
  end
  if mode == "interactive" and exitInteractive then love.event.quit(0) end
end

function love.load()
  love.mouse.setVisible(false)
  W, H = love.graphics.getDimensions()
  titleFont = love.graphics.newFont(math.max(24, math.floor(H * 0.070)))
  headingFont = love.graphics.newFont(math.max(19, math.floor(H * 0.050)))
  bodyFont = love.graphics.newFont(math.max(15, math.floor(H * 0.036)))
  smallFont = love.graphics.newFont(math.max(12, math.floor(H * 0.029)))
  refresh()
end

function love.update(dt)
  elapsed = elapsed + dt
  sampleClock = sampleClock + dt
  if sampleClock >= 0.10 then
    sampleClock = 0
    refresh()
  end
end

local function label(font, color, value, x, y, width, align)
  love.graphics.setFont(font)
  love.graphics.setColor(color)
  love.graphics.printf(value, x, y, width, align or "left")
end

function love.draw()
  local green = {0.38, 0.95, 0.28, 1}
  local pale = {0.78, 0.86, 0.77, 1}
  local dim = {0.48, 0.57, 0.52, 1}
  love.graphics.clear(0.025, 0.055, 0.060, 1)

  love.graphics.setColor(0.055, 0.105, 0.11, 1)
  love.graphics.rectangle("fill", 0, 0, W, H * 0.15)
  love.graphics.setColor(green)
  love.graphics.rectangle("fill", 0, H * 0.145, W, math.max(2, H * 0.008))
  label(titleFont, green, "MINECRAFT BEDROCK", W * 0.025, H * 0.018, W * 0.95)
  label(smallFont, dim,
        kind == "install" and "LOCAL APK INSTALLER" or "GOOGLE PLAY APK DOWNLOADER",
        W * 0.027, H * 0.103, W * 0.94)

  local bx, by, bw, bh = W * 0.075, H * 0.22, W * 0.85, H * 0.58
  love.graphics.setColor(0.10, 0.15, 0.15, 1)
  love.graphics.rectangle("fill", bx, by, bw, bh)
  love.graphics.setColor(green)
  love.graphics.setLineWidth(math.max(2, H * 0.005))
  love.graphics.rectangle("line", bx, by, bw, bh)

  label(headingFont, pale, heading, bx + bw * 0.05, by + bh * 0.10, bw * 0.90, "center")

  local barX, barY, barW, barH = bx + bw * 0.09, by + bh * 0.39, bw * 0.82, H * 0.072
  love.graphics.setColor(0.025, 0.045, 0.045, 1)
  love.graphics.rectangle("fill", barX, barY, barW, barH)
  love.graphics.setColor(0.20, 0.30, 0.27, 1)
  love.graphics.rectangle("line", barX, barY, barW, barH)
  local fillW = barW * pct / 100
  love.graphics.setColor(0.22, 0.67, 0.18, 1)
  love.graphics.rectangle("fill", barX + 3, barY + 3, math.max(0, fillW - 6), barH - 6)
  if pct < 100 then
    local travel = math.max(1, barW - H * 0.04)
    local marker = barX + ((elapsed * W * 0.15) % travel)
    love.graphics.setColor(0.65, 1.0, 0.50, 0.85)
    love.graphics.rectangle("fill", marker, barY + 3, H * 0.025, barH - 6)
  end
  label(bodyFont, {0.95, 1, 0.93, 1}, string.format("%d%%", pct),
        barX, barY + barH * 0.16, barW, "center")

  label(bodyFont, pale, detail, bx + bw * 0.06, by + bh * 0.60, bw * 0.88, "center")
  label(smallFont, dim,
        kind == "install" and "Worlds and settings are kept separate. Do not turn off."
                              or "Google credentials are never written to this progress screen.",
        bx + bw * 0.06, by + bh * 0.84, bw * 0.88, "center")
end
