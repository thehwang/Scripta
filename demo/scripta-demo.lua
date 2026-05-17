-- Scripta demo recording automation
-- =================================
-- Drives the Scripta UI through the v3.2.0 Gemma 4 demo script while
-- voiceover-final.mp3 plays. Designed for one-shot screen recording sessions
-- where you want every take to look identical.
--
-- Prerequisites:
--   1. Hammerspoon installed and granted Accessibility permission.
--   2. Scripta v3.2.1+ installed (earlier versions miss the AX identifiers).
--   3. Gemma 4 E2B pulled in Ollama (`ollama pull gemma4:e2b`).
--   4. voiceover-final.mp3 exists at the path configured below.
--
-- Setup:
--   Add this line to ~/.hammerspoon/init.lua (adjust path to your clone):
--     local SCRIPTA_REPO = os.getenv("HOME") .. "/path/to/Scripta"
--     dofile(SCRIPTA_REPO .. "/demo/scripta-demo.lua")
--   Then reload Hammerspoon config (menu bar → Reload Config).
--
-- Hotkeys:
--   ⌥⌘D  Start the demo (3-second countdown so you can hit ⌘⇧5 to record first).
--   ⌥⌘.  Abort the running demo (kills all pending timers + afplay).
--
-- See MeetingPilot/demo/README.md for the full operational checklist.

local M = {}

-- Resolve the ElevenLabs voiceover path. Default: ../blog/voiceover-final.mp3
-- relative to this script (i.e. blog/voiceover-final.mp3 inside your Scripta
-- clone). Override with $SCRIPTA_DEMO_VOICEOVER if you keep the file elsewhere.
local function resolveVoiceoverPath()
    local override = os.getenv("SCRIPTA_DEMO_VOICEOVER")
    if override and override ~= "" then return override end
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local dir = src:match("(.*/)") or ""
    return dir .. "../blog/voiceover-final.mp3"
end

-- ── Configuration ────────────────────────────────────────────────────────
local CONFIG = {
    -- Path to the ElevenLabs voiceover audio that drives the demo timing.
    -- See resolveVoiceoverPath() above for default + override behavior.
    voiceoverPath = resolveVoiceoverPath(),

    -- The Ollama model the demo should select. Must match what's in
    -- SummaryModelManager.recommendedModels and `ollama list`.
    gemmaModel = "gemma4:e2b",

    -- Cue timestamps, in seconds, anchored to voiceover-final.mp3 (78.5s total).
    -- Tweak if you re-record the voiceover. Each cue corresponds to a paragraph
    -- start in the narration; see blog/gemma4-challenge-demo-script.md.
    cues = {
        openSettings   = 7.5,    -- "Notice the context window column..."
        clickGemmaRow  = 13.0,   -- Highlight selection in the picker
        closeSettings  = 23.5,   -- Esc just before "I'll record a short clip"
        clickRecord    = 25.0,   -- "Two channels, transcribed in real time..."
        -- Mic line: user reads "Let me try summarizing this meeting" out loud.
        -- System Audio channel is auto-filled by afplay'd voiceover via
        -- ScreenCaptureKit, so no separate clip is needed.
        promptUserToSpeak = 27.5,
        clickStop      = 47.0,   -- After "Now the interesting part."
        clickSummarize = 50.5,   -- During "Summarize calls Ollama locally..."
        -- Optional Terminal peek to flash the `num_ctx=131072` log line.
        -- Set both to nil if you want to skip this beat entirely.
        showTerminalCue = 55.0,
        backToScripta   = 60.0,
        scrollSummary   = 67.0,   -- "Now Gemma 4 sees the whole transcript"
        endAlert        = 79.0,   -- One second after voiceover ends → stop recording
    },

    -- App name to focus when showTerminalCue fires. Must exactly match the
    -- app bundle name (e.g. "Terminal", "iTerm", "Warp", "Ghostty").
    terminalAppName = "Terminal",

    -- When true, suppress all alerts/HUDs that would otherwise appear during
    -- the demo (Speak prompt, Demo complete banner). Pre-demo alerts (warmup
    -- heartbeat, 3-2-1 countdown) still fire because they're emitted before
    -- you've hit ⌘⇧5 to start recording.
    --
    -- Set to false during dry-run iteration if you want the visual cues; flip
    -- back to true before the actual take.
    silentRecording = true,
}

-- ── State (so abort can clean up) ────────────────────────────────────────
local state = {
    timers = {},
    afplayTask = nil,
    running = false,
}

-- ── Helpers ──────────────────────────────────────────────────────────────

local function log(msg)
    print(os.date("[%H:%M:%S]") .. " scripta-demo: " .. msg)
end

local function findScripta()
    return hs.application.get("Scripta")
end

-- Walk the accessibility tree to find an element by its AXIdentifier.
-- Returns nil if not found within `depthLimit`.
local function findByIdentifier(app, identifier, depthLimit)
    depthLimit = depthLimit or 25
    local axApp = hs.axuielement.applicationElement(app)
    if not axApp then return nil end

    local function walk(el, depth)
        if depth > depthLimit then return nil end
        local ok, ident = pcall(function() return el.AXIdentifier end)
        if ok and ident == identifier then return el end
        local kidsOk, kids = pcall(function() return el:attributeValue("AXChildren") end)
        if not kidsOk or not kids then return nil end
        for _, child in ipairs(kids) do
            local match = walk(child, depth + 1)
            if match then return match end
        end
        return nil
    end

    return walk(axApp, 0)
end

-- Walk the AX tree and click the first AXButton whose AXTitle matches `title`.
-- Used as fallback when an element doesn't have an explicit identifier.
local function findButtonByTitle(app, title, depthLimit)
    depthLimit = depthLimit or 25
    local axApp = hs.axuielement.applicationElement(app)
    if not axApp then return nil end

    local function walk(el, depth)
        if depth > depthLimit then return nil end
        local roleOk, role = pcall(function() return el.AXRole end)
        local titleOk, t = pcall(function() return el.AXTitle end)
        if roleOk and titleOk and role == "AXButton" and t == title then return el end
        local kidsOk, kids = pcall(function() return el:attributeValue("AXChildren") end)
        if not kidsOk or not kids then return nil end
        for _, child in ipairs(kids) do
            local match = walk(child, depth + 1)
            if match then return match end
        end
        return nil
    end

    return walk(axApp, 0)
end

local function pressButton(identifier, fallbackTitle)
    local scripta = findScripta()
    if not scripta then
        log("ERROR: Scripta not running")
        return false
    end

    local el = findByIdentifier(scripta, identifier)
    if not el and fallbackTitle then
        el = findButtonByTitle(scripta, fallbackTitle)
    end

    if not el then
        log(string.format("ERROR: could not find button id=%s title=%s",
            identifier, tostring(fallbackTitle)))
        return false
    end

    local ok, err = pcall(function() el:performAction("AXPress") end)
    if not ok then
        log("ERROR: AXPress failed: " .. tostring(err))
        return false
    end
    log(string.format("clicked %s", identifier))
    return true
end

-- Schedule a callback at `seconds` from now; track it so abort can cancel.
local function at(seconds, callback)
    local t = hs.timer.doAfter(seconds, function()
        if state.running then callback() end
    end)
    table.insert(state.timers, t)
end

local function bigAlert(text, color, duration)
    hs.alert.show(text, {
        textSize = 28,
        textFont = "Menlo-Bold",
        fillColor = color or {white = 0, alpha = 0.85},
        strokeColor = {white = 1, alpha = 0},
        radius = 14,
    }, duration or 4)
end

-- ── Demo lifecycle ───────────────────────────────────────────────────────

-- Async warmup the Ollama model so the first Summarize click during the demo
-- is hot (~1s response) instead of cold (~80s while Gemma 4's 7.2 GB weights
-- load into RAM). The callback fires when the warmup request completes; we
-- also enforce a hard timeout so a misbehaving Ollama can't stall the demo
-- forever.
local function warmOllama(onComplete)
    log("warming Ollama (" .. CONFIG.gemmaModel .. ")...")
    local startedAt = hs.timer.secondsSinceEpoch()
    local fired = false

    local function finish(reason)
        if fired then return end
        fired = true
        local elapsed = hs.timer.secondsSinceEpoch() - startedAt
        log(string.format("warmup %s (%.1fs)", reason, elapsed))
        if onComplete then onComplete(elapsed) end
    end

    local task = hs.task.new("/usr/bin/curl", function(exitCode)
        finish("completed exit=" .. tostring(exitCode))
    end, {
        "-s", "--max-time", "100",
        "-X", "POST", "http://localhost:11434/api/generate",
        "-d", string.format('{"model":"%s","prompt":"hi","stream":false,"options":{"num_predict":1}}',
            CONFIG.gemmaModel),
    })
    task:start()

    -- Hard 100s ceiling — first cold load is ~80s on Apple Silicon. If we
    -- exceed this, something is wrong (Ollama down, model not pulled, etc.)
    hs.timer.doAfter(100, function()
        if not fired then
            log("WARN: warmup timed out after 100s — Ollama may be down or model not pulled")
            pcall(function() task:terminate() end)
            finish("TIMEOUT")
        end
    end)
end

local function abortDemo()
    if not state.running then
        hs.alert.show("Demo not running", 1)
        return
    end
    log("aborting demo")
    state.running = false
    for _, t in ipairs(state.timers) do
        if t and t.stop then t:stop() end
    end
    state.timers = {}
    if state.afplayTask then
        state.afplayTask:terminate()
        state.afplayTask = nil
    end
    -- Stop any in-progress recording, just in case.
    pressButton("StopButton", "Stop Recording")
    bigAlert("Demo aborted", {red=0.6, green=0.1, blue=0.1, alpha=0.85}, 2)
end

local function startVoiceover()
    if not hs.fs.attributes(CONFIG.voiceoverPath) then
        log("ERROR: voiceover not found at " .. CONFIG.voiceoverPath)
        bigAlert("voiceover-final.mp3 not found!\nCheck CONFIG.voiceoverPath", {red=0.8, green=0.1, blue=0.1}, 4)
        return false
    end
    log("starting voiceover: " .. CONFIG.voiceoverPath)
    state.afplayTask = hs.task.new("/usr/bin/afplay", function(exitCode)
        log("afplay exited: " .. tostring(exitCode))
    end, {CONFIG.voiceoverPath})
    state.afplayTask:start()
    return true
end

local function runCues()
    local c = CONFIG.cues

    at(c.openSettings, function()
        log("⌘, → open Settings")
        local scripta = findScripta()
        if scripta then scripta:activate() end
        hs.eventtap.keyStroke({"cmd"}, ",")
    end)

    at(c.clickGemmaRow, function()
        pressButton("InstalledModel." .. CONFIG.gemmaModel)
    end)

    at(c.closeSettings, function()
        log("Esc → close Settings (uses v3.2.1 fix)")
        hs.eventtap.keyStroke({}, "escape")
    end)

    at(c.clickRecord, function()
        local scripta = findScripta()
        if scripta then scripta:activate() end
        pressButton("RecordButton", "Start Recording")
    end)

    at(c.promptUserToSpeak, function()
        if CONFIG.silentRecording then
            -- Silent take: rely on the voiceover audio cue. Around this beat
            -- the narrator says "I'll record a short clip..." — speak the
            -- demo line right after that.
            log("(silent) speak now: 'Let me try summarizing this meeting.'")
        else
            bigAlert("🎤 Speak now:\n\"Let me try summarizing this meeting.\"",
                {red=0.15, green=0.55, blue=0.25, alpha=0.92}, 4)
        end
    end)

    at(c.clickStop, function()
        pressButton("StopButton", "Stop Recording")
    end)

    at(c.clickSummarize, function()
        -- A small delay to let recorder.state transition to .completed before
        -- the SummarizeButton becomes interactive.
        hs.timer.doAfter(0.3, function()
            pressButton("SummarizeButton", "Summarize")
        end)
    end)

    -- Optional peek at the Terminal to show the `num_ctx=131072` log line.
    -- Uses launchOrFocus rather than ⌘⇥ because ⌘⇥ depends on the MRU app
    -- order and is unreliable for automation. Set CONFIG.cues.showTerminalCue
    -- and backToScripta to nil to skip this beat entirely.
    if c.showTerminalCue then
        at(c.showTerminalCue, function()
            log("focus " .. CONFIG.terminalAppName .. " (peek at num_ctx log)")
            local ok = hs.application.launchOrFocus(CONFIG.terminalAppName)
            if not ok then
                log("WARN: could not focus " .. CONFIG.terminalAppName ..
                    " — check CONFIG.terminalAppName")
            end
        end)
    end

    if c.backToScripta then
        at(c.backToScripta, function()
            log("focus Scripta")
            hs.application.launchOrFocus("Scripta")
        end)
    end

    at(c.scrollSummary, function()
        log("scroll summary panel")
        local scripta = findScripta()
        if scripta then scripta:activate() end
        -- Three down-arrow strokes inside the summary scroll view.
        for i = 1, 3 do
            hs.timer.doAfter(i * 0.4, function()
                hs.eventtap.keyStroke({}, "down")
            end)
        end
    end)

    at(c.endAlert, function()
        if CONFIG.silentRecording then
            -- Silent take: when the voiceover audio stops playing, that's
            -- your cue to stop the screen recording (⌘⌃Esc or click the
            -- menubar stop icon).
            log("(silent) demo complete — stop screen recording now")
        else
            bigAlert("✓ Demo complete — STOP screen recording now",
                {red=0.1, green=0.4, blue=0.2, alpha=0.9}, 5)
        end
        state.running = false
    end)
end

function M.runDemo()
    if state.running then
        hs.alert.show("Demo already running — press ⌥⌘. to abort", 2)
        return
    end

    local scripta = findScripta()
    if not scripta then
        bigAlert("Scripta is not running.\nLaunch it first, then retry.",
            {red=0.7, green=0.1, blue=0.1}, 3)
        return
    end

    log("=== demo run begin ===")
    state.running = true
    state.timers = {}

    scripta:activate()

    -- Warm Ollama BEFORE the countdown so the model is hot in memory by the
    -- time we click Summarize at ~50s into the voiceover. First cold load of
    -- Gemma 4 takes ~80s; subsequent runs within Ollama's keep_alive window
    -- (~5 min) are instant. We display progress so the user knows what's
    -- happening during the otherwise-silent wait.
    bigAlert("Warming " .. CONFIG.gemmaModel ..
             "...\n(first run ~80s, repeat runs instant)",
             {white=0, alpha=0.9}, 5)

    -- Show a heartbeat every 10s so the user knows we're not frozen.
    local heartbeatTimer
    heartbeatTimer = hs.timer.doEvery(10, function()
        if not state.running then return end
        hs.alert.show("...still warming Gemma 4", 1)
    end)
    table.insert(state.timers, heartbeatTimer)

    warmOllama(function(elapsed)
        if heartbeatTimer then heartbeatTimer:stop() end
        if not state.running then return end

        bigAlert(string.format("✓ Model warm (%.1fs)\nStart screen recording NOW. Demo begins in 3...", elapsed),
                 {white=0, alpha=0.9}, 1)
        hs.timer.doAfter(1, function() if state.running then bigAlert("...2", nil, 1) end end)
        hs.timer.doAfter(2, function() if state.running then bigAlert("...1", nil, 1) end end)
        hs.timer.doAfter(3, function()
            if not state.running then return end
            if not startVoiceover() then
                state.running = false
                return
            end
            runCues()
        end)
    end)
end

-- ── Hotkeys ─────────────────────────────────────────────────────────────

local mods = {"alt", "cmd"}
hs.hotkey.bind(mods, "d", M.runDemo)
hs.hotkey.bind(mods, ".", abortDemo)

log("scripta-demo.lua loaded — ⌥⌘D to start, ⌥⌘. to abort")
hs.alert.show("Scripta demo loaded — ⌥⌘D to run", 2)

return M
