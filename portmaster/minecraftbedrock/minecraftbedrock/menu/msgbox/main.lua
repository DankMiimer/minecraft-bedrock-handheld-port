-- A message the player can actually read.
--
-- show_msg writes to /dev/tty1, which only reaches the panel on firmwares that
-- bind fbcon to it. muOS does not bind it, so on muOS every launcher message
-- was written to a console nobody can see. This draws the same lines as a real
-- LOVE frame instead.
--
-- Input is the message file named by MCPE_MSG_FILE, one line per row, because
-- an argv of arbitrary player-visible text is awkward to quote through the
-- launch chain. Uses only LOVE's built-in font so the app stays self-contained.
local msgPath = os.getenv("MCPE_MSG_FILE") or ""
local timeout = tonumber(os.getenv("MCPE_MSG_TIMEOUT") or "") or 12
local heading = os.getenv("MCPE_MSG_HEADING") or "Minecraft Bedrock"

local lines = {}
local elapsed = 0
local W, H
local headingFont, bodyFont, smallFont

local function loadLines()
    local file = io.open(msgPath, "rb")
    if not file then return end
    for line in file:lines() do
        -- Trim a trailing CR so a file written on any host still lays out right.
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    file:close()
end

function love.load()
    love.mouse.setVisible(false)
    W, H = love.graphics.getDimensions()
    local scale = math.min(W / 640, H / 480)
    headingFont = love.graphics.newFont(math.floor(26 * scale))
    bodyFont = love.graphics.newFont(math.floor(19 * scale))
    smallFont = love.graphics.newFont(math.floor(15 * scale))
    loadLines()
end

function love.update(dt)
    elapsed = elapsed + dt
    if timeout > 0 and elapsed >= timeout then love.event.quit(0) end
end

-- Any button or key dismisses it; a player should never be stuck staring at a
-- message waiting for a timer they cannot see.
function love.keypressed() love.event.quit(0) end
function love.gamepadpressed() love.event.quit(0) end
function love.joystickpressed() love.event.quit(0) end

function love.draw()
    love.graphics.clear(0.04, 0.06, 0.09)

    local margin = math.floor(W * 0.07)
    local y = math.floor(H * 0.13)

    love.graphics.setFont(headingFont)
    love.graphics.setColor(0.50, 0.86, 0.42)
    love.graphics.printf(heading, margin, y, W - margin * 2, "left")
    y = y + headingFont:getHeight() * 1.6

    love.graphics.setFont(bodyFont)
    love.graphics.setColor(0.93, 0.93, 0.93)
    for _, line in ipairs(lines) do
        love.graphics.printf(line, margin, y, W - margin * 2, "left")
        -- printf wraps, so advance by the height the wrapped block really used.
        local _, wrapped = bodyFont:getWrap(line, W - margin * 2)
        y = y + bodyFont:getHeight() * math.max(1, #wrapped) * 1.25
    end

    love.graphics.setFont(smallFont)
    love.graphics.setColor(0.55, 0.55, 0.58)
    love.graphics.printf("Press any button to continue",
        margin, H - math.floor(H * 0.12), W - margin * 2, "left")
end
