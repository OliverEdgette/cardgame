
-- Global state
Player = {
        name = "Hero",
        hp = 10,
        maxhp = 10,
        mana = 3,
        maxmana = 4,
}
Enemy = {
        name = "CPU",
        hp = 10,
        maxhp = 10,
        mana = 0,
        maxmana = 6,
}
local deck        = {}
local playerHand  = {}
local discard     = {}

local currentCard    = nil
local currentInstant = nil

local gameOver  = false
local victory   = false
local message   = ""          -- feedback line shown to player
local msgTimer  = 0           -- seconds the message stays visible

-- Turn phase state machine
-- Phases: "draw" → "player" → "instant" → "execute" → "end_turn" → "draw"
local phase     = "draw"
local phaseTimer = 0
local PHASE_DELAY = 0.8       -- seconds between auto-phases

-- Mouse-click card selection (for player phase)
local selectedIdx = nil       -- index in playerHand the player clicked

-- Card dimensions for UI
local CARD_W, CARD_H = 90, 130
local HAND_Y         = 430    -- y position of the hand row
-- button dimensions
local BTN_X, BTN_Y   = 490, 460
local BTN_W, BTN_H   = 130, 50

--Utility functions 

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function showMessage(msg, duration)
    message  = msg
    msgTimer = duration or 2
end

--- shuffle
local function shuffle(t)
    for i = #t, 2, -1 do
        local j = love.math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end


-- Card definitions (to be swapped for JSON)

local json      = require("dkjson")
local CARD_DEFS = {}

local function loadCardDefs(path)
    -- Check the file exists and is visible to LÖVE's filesystem
    local info = love.filesystem.getInfo(path)
    if not info then
        error("File not found: '" .. path .. "'\nReal path: " .. love.filesystem.getSource())
    end

    local contents, err = love.filesystem.read(path)
    if not contents then
        error("Read failed: " .. tostring(err))
    end

    -- Print the raw first 60 bytes so we can see exactly what dkjson receives
    print("File size:", #contents)
    print("First 60 chars: [" .. contents:sub(1, 60) .. "]")
    print("First 3 bytes (hex):")
    for i = 1, math.min(3, #contents) do
        io.write(string.format("0x%02X ", contents:byte(i)))
    end
    print()

    -- Strip BOM if present
    if contents:sub(1, 3) == "\xEF\xBB\xBF" then
        print("BOM detected and stripped.")
        contents = contents:sub(4)
    end

    local data, pos, jsonErr = json.decode(contents, 1, nil)
    if not data then
        error("JSON parse error at position " .. tostring(pos) .. ": " .. tostring(jsonErr))
    end
    if not data.cards then
        error("JSON parsed OK but has no 'cards' key. Keys found: " ..
            (function()
                local ks = {}
                for k in pairs(data) do table.insert(ks, tostring(k)) end
                return table.concat(ks, ", ")
            end)())
    end
    return data.cards
end

--- Build a fresh copy of a card from its definition
local function newCard(def)
    local c = {}
    for k, v in pairs(def) do c[k] = v end
    return c
end

--- Build and shuffle the starting deck (3 copies of each card)
local function buildDeck()
    local d = {}
    for _, def in ipairs(CARD_DEFS) do
        for _ = 1, 2 do
            table.insert(d, newCard(def))
        end
    end
    shuffle(d)
    return d
end


-- Deck / hand helpers

local function drawCard()
    if #deck == 0 then
        -- Reshuffle discard into deck
        if #discard == 0 then
            showMessage("No cards left anywhere!")
            return
        end
        deck    = discard
        discard = {}
        shuffle(deck)
        showMessage("Deck reshuffled from discard.")
    end

    local card = table.remove(deck, 1)
    if card then
        table.insert(playerHand, card)
    end
end

--- Draw up to a target hand size
local function drawUpTo(n)
    while #playerHand < n do
        drawCard()
    end
end

local function removeFromHand(idx)
    local card = table.remove(playerHand, idx)
    if card then
        table.insert(discard, card)
    end
    return card
end


-- Combat helpers 

local function applyCardEffect(card, isInstant)
    -- Temporary debug: remove once confirmed working
    print("applyCardEffect called:")
    for k, v in pairs(card) do
        print("  " .. tostring(k) .. " = " .. tostring(v))
    end
    -- temp
    if card.type == "attack" or (isInstant and card.type == "instant" and card.attack > 0) then
        Enemy.hp = clamp(Enemy.hp - card.attack, 0, Enemy.maxhp)
        showMessage(card.name .. " deals " .. card.attack .. " damage!")
    end
    if card.type == "defense" or (isInstant and card.type == "instant" and card.defense > 0) then
        Player.hp = clamp(Player.hp + math.floor(card.defense / 3), 0, Player.maxhp)
        showMessage(card.name .. " blocks — +" .. math.floor(card.defense / 3) .. " HP shielded.")
    end
    if card.type == "heal" and card.heal then
        Player.hp = clamp(Player.hp + card.heal, 0, Player.maxhp)
        showMessage(card.name .. " restores " .. card.heal .. " HP.")
    end
    if card.type == "mana" and card.mana then
        Player.mana = clamp(Player.mana + card.mana, 0, Player.maxmana)
        showMessage(card.name .. " restores " .. card.mana .. " mana!")
    end
    if card.type == "lifesteal" then
        local dmg   = card.attack or 0
        local steal = card.steal  or dmg
        Enemy.hp  = clamp(Enemy.hp  - dmg,   0, Enemy.maxhp)
        Player.hp = clamp(Player.hp + steal, 0, Player.maxhp)
        showMessage(card.name .. " steals " .. steal .. " HP from " .. Enemy.name .. "!")
    end
end

local function enemyAttack()
    local dmg = love.math.random(1, 6)
    Player.hp = clamp(Player.hp - dmg, 0, Player.maxhp)
    showMessage(Enemy.name .. " attacks for " .. dmg .. " damage!", 1.5)
end


-- Win / loss check

local function checkEndConditions()
    if Enemy.hp <= 0 then
        victory = true
        gameOver = true
        showMessage("Victory! The " .. Enemy.name .. " is defeated!", 999)
        return true
    end
    if Player.hp <= 0 then
        victory  = false
        gameOver = true
        showMessage("Defeat! You have fallen...", 999)
        return true
    end
    return false
end


-- LÖVE2D core callbacks

function love.load()
    love.window.setTitle("Card Battle")
    love.window.setMode(640, 580, { resizable = false })

    math.randomseed(os.time())

    CARD_DEFS   = loadCardDefs("cards.json")

    deck        = buildDeck()
    playerHand  = {}
    discard     = {}

    -- Draw opening hand of 4
    drawUpTo(4)

    phase      = "player"
    phaseTimer = 0

    showMessage("Your turn — click a card to play it.", 3)
end


function love.update(dt)
    if gameOver then return end

    -- Count down the message overlay
    if msgTimer > 0 then
        msgTimer = msgTimer - dt
    end

    -- The "draw" and "end_turn" phases advance automatically after a short delay
    -- The "player" phase waits for mouse input

    if phase == "draw" then
        phaseTimer = phaseTimer + dt
        if phaseTimer >= PHASE_DELAY then
            phaseTimer = 0
            drawUpTo(4)
            phase = "player"
            showMessage("Your turn — click a card to play it.", 3)
        end

    elseif phase == "instant" then
        -- Check if any instant in hand should auto-trigger
        phaseTimer = phaseTimer + dt
        if phaseTimer >= PHASE_DELAY then
            phaseTimer = 0
            currentInstant = nil
            for i, card in ipairs(playerHand) do
                if card.type == "instant" then
                    currentInstant = removeFromHand(i)
                    break
                end
            end
            phase = "execute"
        end

    elseif phase == "execute" then
        phaseTimer = phaseTimer + dt
        if phaseTimer >= PHASE_DELAY then
            phaseTimer = 0
            if currentInstant then
                applyCardEffect(currentInstant, true)
                currentInstant = nil
            end
            if not checkEndConditions() then
                phase = "end_turn"
            end
        end

    elseif phase == "end_turn" then
        phaseTimer = phaseTimer + dt
        if phaseTimer >= PHASE_DELAY then
            phaseTimer = 0
            enemyAttack()
            if not checkEndConditions() then
                phase = "draw"
            end
        end
    end
    -- "player" phase: idle — waiting for love.mousepressed
end


function love.mousepressed(x, y, button)
    if gameOver or button ~= 1 then return end
    if phase ~= "player" then return end

    -- End Turn button
    if x >= BTN_X and x <= BTN_X + BTN_W and
       y >= BTN_Y and y <= BTN_Y + BTN_H then
        phase      = "instant"
        phaseTimer = 0
        showMessage("Turn ended.", 1)
        return
    end
    -- Detect which card in hand was clicked
    for i, card in ipairs(playerHand) do
        local cx = 20 + (i - 1) * (CARD_W + 10)
        local cy = HAND_Y
        if x >= cx and x <= cx + CARD_W and y >= cy and y <= cy + CARD_H then
            if Player.mana < card.cost then
                showMessage("Not enough mana for " .. card.name .. "!", 1.5)
                return
            end
            Player.mana = Player.mana - card.cost
            currentCard = removeFromHand(i)
            applyCardEffect(currentCard, false)
            -- Removed the showMessage("Card played...") that was overwriting effect messages
            checkEndConditions()
            return
        end
    end
end

function love.keypressed(key)
    if key == "r" and gameOver then
        love.load()   -- restart
    end
    if key == "escape" then
        love.event.quit()
    end
end


-- UI helpers

--- Draw a card rectangle at (x, y)
local function drawCardUI(card, x, y, highlight)
    -- Background colour by type
    local bg = {
        attack  = {0.55, 0.12, 0.12},
        defense = {0.10, 0.30, 0.55},
        heal    = {0.15, 0.50, 0.20},
        instant = {0.50, 0.35, 0.05},
        mana    = {0.20, 0.20, 0.70},
        lifesteal = {0.40, 0.10, 0.45},
    }
    local col = bg[card.type] or {0.25, 0.25, 0.25}

    love.graphics.setColor(col)
    love.graphics.rectangle("fill", x, y, CARD_W, CARD_H, 6, 6)

    -- Highlight border when hovered / selected
    if highlight then
        love.graphics.setColor(1, 0.9, 0.2)
    else
        love.graphics.setColor(0.8, 0.8, 0.8)
    end
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, CARD_W, CARD_H, 6, 6)

    -- Card name
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(card.name, x + 4, y + 6, CARD_W - 8, "center")

    -- Divider
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.line(x + 6, y + 24, x + CARD_W - 6, y + 24)

    -- Type tag
    love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.printf("[" .. card.type .. "]", x + 4, y + 28, CARD_W - 8, "center")

    -- Description
    love.graphics.setColor(0.9, 0.9, 0.9)
    love.graphics.printf(card.description, x + 4, y + 46, CARD_W - 8, "left")

    -- Stats row
    love.graphics.setColor(1, 0.4, 0.4)
    if card.attack and card.attack > 0 then
        love.graphics.print("ATK " .. card.attack, x + 4, y + CARD_H - 34)
    end
    love.graphics.setColor(0.4, 0.7, 1)
    if card.defense and card.defense > 0 then
        love.graphics.print("DEF " .. card.defense, x + 4, y + CARD_H - 22)
    end
    if card.heal and card.heal > 0 then
        love.graphics.setColor(0.4, 1, 0.5)
        love.graphics.print("HEAL " .. card.heal, x + 4, y + CARD_H - 22)
    end

    if card.mana and card.mana > 0 then
    love.graphics.setColor(0.5, 0.5, 1)
    love.graphics.print("MANA +" .. card.mana, x + 4, y + CARD_H - 22)
    end

    if card.steal and card.steal > 0 then
    love.graphics.setColor(0.85, 0.4, 1)
    love.graphics.print("STEAL " .. card.steal, x + 4, y + CARD_H - 10)
    end

    -- Mana cost bubble (top-right)
    love.graphics.setColor(0.3, 0.3, 0.8)
    love.graphics.circle("fill", x + CARD_W - 12, y + 12, 10)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(tostring(card.cost), x + CARD_W - 22, y + 6, 20, "center")
end

--- HP bar
local function drawBar(x, y, w, h, current, max, r, g, b)
    love.graphics.setColor(0.2, 0.2, 0.2)
    love.graphics.rectangle("fill", x, y, w, h, 3, 3)
    local ratio = clamp(current / max, 0, 1)
    love.graphics.setColor(r, g, b)
    love.graphics.rectangle("fill", x, y, w * ratio, h, 3, 3)
    love.graphics.setColor(0.6, 0.6, 0.6)
    love.graphics.rectangle("line", x, y, w, h, 3, 3)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(current .. "/" .. max, x, y, w, "center")
end


-- Main draw

function love.draw()
    local W = love.graphics.getWidth()

    -- Background
    love.graphics.setColor(0.10, 0.10, 0.15)
    love.graphics.rectangle("fill", 0, 0, W, love.graphics.getHeight())

    -- ── Title bar ──
    love.graphics.setColor(0.9, 0.8, 0.3)
    love.graphics.printf("♦  CARD BATTLE  ♦", 0, 10, W, "center")

    -- ── Enemy panel ──
    love.graphics.setColor(0.65, 0.15, 0.15)
    love.graphics.rectangle("fill", W/2 - 120, 40, 240, 70, 8, 8)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(Enemy.name, W/2 - 120, 48, 240, "center")
    drawBar(W/2 - 100, 68, 200, 18, Enemy.hp, Enemy.maxhp, 0.85, 0.15, 0.15)

    -- ── Player panel ──
    love.graphics.setColor(0.15, 0.35, 0.55)
    love.graphics.rectangle("fill", 20, 350, 200, 70, 8, 8)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("Player", 30, 358)
    drawBar(30, 375, 180, 16, Player.hp, Player.maxhp, 0.20, 0.75, 0.25)

    -- Mana
    love.graphics.setColor(0.6, 0.6, 1)
    love.graphics.print("Mana", 30, 396)
    drawBar(30, 410, 180, 14, Player.mana, Player.maxmana, 0.25, 0.25, 0.90)

    -- ── Deck / discard counters ──
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.print("Deck: "    .. #deck,    W - 120, 350)
    love.graphics.print("Discard: " .. #discard, W - 120, 368)

    -- ── Phase label ──
    love.graphics.setColor(0.6, 0.9, 0.6)
    love.graphics.printf("Phase: " .. phase, 0, 390, W, "center")

    -- ── Hand ──
    local mx, my = love.mouse.getPosition()
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.printf("── Your Hand ──", 0, HAND_Y - 18, W, "center")

    for i, card in ipairs(playerHand) do
        local cx = 20 + (i - 1) * (CARD_W + 10)
        local cy = HAND_Y
        local hover = (mx >= cx and mx <= cx + CARD_W and my >= cy and my <= cy + CARD_H)
        -- Lift card on hover
        local drawY = hover and cy - 10 or cy
        drawCardUI(card, cx, drawY, hover)
    end

    -- ── End Turn Button ──
    if not gameOver and phase == "player" then
        local mx, my = love.mouse.getPosition()
        local hover  = mx >= BTN_X and mx <= BTN_X + BTN_W
                    and my >= BTN_Y and my <= BTN_Y + BTN_H
        love.graphics.setColor(hover and {0.25, 0.65, 0.25} or {0.15, 0.45, 0.15})
        love.graphics.rectangle("fill", BTN_X, BTN_Y, BTN_W, BTN_H, 8, 8)
        love.graphics.setColor(hover and {0.5, 1, 0.5} or {0.4, 0.8, 0.4})
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", BTN_X, BTN_Y, BTN_W, BTN_H, 8, 8)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf("End Turn\n[E]", BTN_X, BTN_Y + 12, BTN_W, "center")
    end

    -- ── Message overlay ──
    if msgTimer > 0 then
        love.graphics.setColor(0, 0, 0, 0.65)
        love.graphics.rectangle("fill", 0, 165, W, 36)
        love.graphics.setColor(1, 0.95, 0.5)
        love.graphics.printf(message, 0, 173, W, "center")
    end

    -- ── Game Over overlay ──
    if gameOver then
        love.graphics.setColor(0, 0, 0, 0.78)
        love.graphics.rectangle("fill", 0, 0, W, love.graphics.getHeight())
        local col = victory and {0.3, 1, 0.5} or {1, 0.3, 0.3}
        love.graphics.setColor(col)
        local txt = victory and "VICTORY!" or "DEFEAT"
        love.graphics.printf(txt, 0, 200, W, "center")
        love.graphics.setColor(0.8, 0.8, 0.8)
        love.graphics.printf("Press R to restart  |  ESC to quit", 0, 250, W, "center")
   
    end
end