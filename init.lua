-- readflow: select text anywhere, hit ctrl+escape, hear it. Press again to stop.
-- Hammerspoon config — https://github.com/michiosw/readflow

hs.autoLaunch(true)
require("hs.ipc") -- enables `hs -c ...` CLI for testing

hs.menuIcon(false) -- hide Hammerspoon's hammer; readflow shows its own icon below
hs.dockIcon(false)

local CONFIG = {
  url = "https://api.groq.com/openai/v1/audio/speech", -- OpenAI-compatible
  model = "canopylabs/orpheus-v1-english",
  localUrl = "http://127.0.0.1:8930/v1/audio/speech",
  localModel = "mlx-community/Kokoro-82M-bf16",
  localVoice = "af_heart",
  hotkey = { mods = { "ctrl" }, key = "escape" },
  firstChunk = 200,
  chunk = 400,
  hardChunk = 450, -- ponytail: stay below Groq's unstable/oversize request range
  maxChars = 4000,
}
local VOICES = { "austin", "autumn", "daniel", "diana", "hannah", "troy" }

local envKey = hs.execute("/bin/zsh -lc 'echo -n $GROQ_API_KEY'")
local function setting(k, default)
  local v = hs.settings.get("readflow." .. k)
  return (v and #v > 0) and v or default
end
local function apiKey() return setting("key", envKey) end
local function voice() return setting("voice", VOICES[1]) end

-- Warm Kokoro in the background so a fallback does not wait for the model to load.
hs.http.asyncPost(CONFIG.localUrl, hs.json.encode({
  model = CONFIG.localModel, input = "warm up", voice = CONFIG.localVoice, response_format = "wav",
}), { ["Content-Type"] = "application/json" }, function() end)

-- ── playback queue ──────────────────────────────────────────────────────────
player = nil -- global: inspectable from `hs -c` for testing
local session = 0 -- bumped to cancel in-flight fetches and callbacks
local retryDelays = { 0.7, 1.5, 3, 6, 12 }
local localRetryDelays = { 0.5, 1, 2 }
local queueParts, pending, activePath = {}, {}, nil
local queueActive, fetching, fetchDone, nextToFetch = false, false, false, 1
local overflowText, fallbackText, currentProvider = "", nil, nil
local groqAlerted, builtInAlerted = false, false
local retryTimer, slowTimer = nil, nil

local function removeFile(path)
  if path then os.remove(path) end
end

local function stop()
  local wasBusy = queueActive or player ~= nil or #pending > 0
  session = session + 1
  queueActive, fetching, fetchDone, nextToFetch = false, false, false, 1
  if retryTimer then retryTimer:stop() end
  if slowTimer then slowTimer:stop() end
  retryTimer, slowTimer = nil, nil
  if player then player:stop() end
  player = nil
  removeFile(activePath)
  activePath = nil
  for _, item in ipairs(pending) do removeFile(item.path) end
  queueParts, pending = {}, {}
  overflowText, fallbackText, currentProvider = "", nil, nil
  groqAlerted, builtInAlerted = false, false
  return wasBusy
end

local function terminalError(message)
  stop()
  hs.alert.show(message)
end

local function headerValue(headers, name)
  if type(headers) ~= "table" then return nil end
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == name then return value end
  end
  return nil
end

local function finishIfIdle()
  if queueActive and fetchDone and not player and #pending == 0 then
    queueActive = false
  end
end

local function speakBuiltIn(text)
  local sess = session
  player = hs.speech.new()
  if not player then return false end
  player:setCallback(function(_, why) -- clear on natural finish or the next hotkey press reads as "stop"
    if sess == session and why == "didFinish" then
      player = nil
      queueActive = false
    end
  end)
  player:speak(text)
  return true
end

local function remainingText(after)
  local parts = {}
  for i = after + 1, #queueParts do parts[#parts + 1] = queueParts[i] end
  if #overflowText > 0 then parts[#parts + 1] = overflowText end
  return table.concat(parts, " ")
end

local fetchChunk, playIfReady, beginProvider

local function startBuiltIn(sess)
  if sess ~= session or player or #pending > 0 or not fallbackText then return end
  local text = fallbackText
  fallbackText = nil
  queueActive = false
  if #text > 0 and not speakBuiltIn(text) then terminalError("readflow: built-in voice failed") end
end

local function advanceProvider(sess, failedAt, provider)
  if sess ~= session then return end
  fetching = false
  if retryTimer then retryTimer:stop() end
  if slowTimer then slowTimer:stop() end
  retryTimer, slowTimer = nil, nil
  local text = remainingText(failedAt - 1)
  if provider == "groq" then
    currentProvider = "local"
    if not groqAlerted then
      groqAlerted = true
      hs.alert.show("readflow: Groq limit — switching to local voice")
    end
    beginProvider(text, sess)
    return
  end
  currentProvider = "builtin"
  fetchDone = true
  fallbackText = text
  if not builtInAlerted then
    builtInAlerted = true
    hs.alert.show("readflow: using built-in macOS voice")
  end
  playIfReady(sess)
  startBuiltIn(sess)
end

playIfReady = function(sess)
  if sess ~= session or player or #pending == 0 then return end
  local item = table.remove(pending, 1)
  player, activePath = item.sound, item.path
  player:setCallback(function(_, completed)
    if sess ~= session then return end
    player = nil
    activePath = nil
    removeFile(item.path)
    if not completed then
      terminalError("readflow: audio playback failed")
      return
    end
    playIfReady(sess)
    startBuiltIn(sess)
    finishIfIdle()
  end)
  if player:play() == false then
    player = nil
    activePath = nil
    removeFile(item.path)
    terminalError("readflow: audio playback failed")
    return
  end
  if slowTimer then
    slowTimer:stop()
    slowTimer = nil
  end
end

fetchChunk = function(i, sess, retry)
  if sess ~= session or fetching or fetchDone then return end
  if i > #queueParts then
    fetchDone = true
    finishIfIdle()
    return
  end
  fetching = true
  local provider = currentProvider
  local useLocal = provider == "local"
  local body = hs.json.encode({
    model = useLocal and CONFIG.localModel or CONFIG.model,
    input = queueParts[i],
    voice = useLocal and CONFIG.localVoice or voice(),
    response_format = "wav",
  })
  local headers = { ["Content-Type"] = "application/json" }
  if not useLocal then headers["Authorization"] = "Bearer " .. apiKey() end
  hs.http.asyncPost(useLocal and CONFIG.localUrl or CONFIG.url, body, headers,
      function(status, audio, responseHeaders)
    if sess ~= session then return end
    fetching = false
    local delays = useLocal and localRetryDelays or retryDelays
    local retryable = useLocal and status ~= 200
      or status == 429
      or (type(status) == "number" and status >= 500 and status < 600)
    local retryAfter = tonumber(headerValue(responseHeaders, "retry-after"))
    if not useLocal and status == 429 and retryAfter and retryAfter > 15 then
      advanceProvider(sess, i, provider)
      return
    end
    if retryable and retry < #delays then
      local delay = not useLocal and retryAfter and (retryAfter + 0.2) or delays[retry + 1]
      retryTimer = hs.timer.doAfter(delay, function()
        retryTimer = nil
        fetchChunk(i, sess, retry + 1)
      end)
      return
    end
    if status ~= 200 then
      advanceProvider(sess, i, provider)
      return
    end
    if type(audio) ~= "string" or #audio == 0 then
      advanceProvider(sess, i, provider)
      return
    end
    local base = os.tmpname()
    removeFile(base)
    local path = base .. ".wav"
    local f = io.open(path, "wb")
    if not f then
      advanceProvider(sess, i, provider)
      return
    end
    local wrote = f:write(audio)
    local closed = f:close()
    if not wrote or not closed then
      removeFile(path)
      advanceProvider(sess, i, provider)
      return
    end
    local sound = hs.sound.getByFile(path)
    if not sound then
      removeFile(path)
      advanceProvider(sess, i, provider)
      return
    end
    pending[#pending + 1] = { sound = sound, path = path }
    nextToFetch = i + 1
    fetchChunk(nextToFetch, sess, 0)
    playIfReady(sess)
  end)
end

-- split on word boundaries, flushing at sentence ends for natural pauses
local function textLength(text)
  return utf8.len(text) or #text
end

local function splitAt(text, limit)
  local length = utf8.len(text)
  if not length then return text:sub(1, limit), text:sub(limit + 1) end
  if length <= limit then return text, "" end
  local cut = utf8.offset(text, limit + 1)
  return text:sub(1, cut - 1), text:sub(cut)
end

local function chunkText(text)
  local parts, buf = {}, ""
  local function limit()
    local preferred = #parts == 0 and CONFIG.firstChunk or CONFIG.chunk
    return math.min(preferred, CONFIG.hardChunk)
  end
  local function flush()
    if #buf == 0 then return end
    parts[#parts + 1] = buf
    buf = ""
  end
  for word in text:gmatch("%S+") do
    while textLength(word) > limit() do
      flush()
      local head
      head, word = splitAt(word, limit())
      parts[#parts + 1] = head
    end
    local separator = #buf > 0 and 1 or 0
    if textLength(buf) + separator + textLength(word) > limit() then flush() end
    if #word > 0 then
      buf = #buf > 0 and (buf .. " " .. word) or word
    end
    local firstSentence = #parts == 0
    if #buf > 0 and buf:match("[%.!%?]%p*$") and (firstSentence or textLength(buf) > 150) then
      flush()
    end
  end
  flush()
  return parts
end

beginProvider = function(text, sess)
  local limited
  limited, overflowText = splitAt(text, CONFIG.maxChars)
  queueParts = chunkText(limited)
  nextToFetch = 1
  fetchDone = #queueParts == 0
  if fetchDone then
    finishIfIdle()
    return
  end
  fetchChunk(1, sess, 0)
end

function speak(text) -- global so `hs -c 'speak("hi")'` works
  stop()
  local key = apiKey()
  currentProvider = key and #key > 0 and "groq" or "local"
  local sess = session
  queueActive, fetchDone = true, false
  slowTimer = hs.timer.doAfter(4, function()
    slowTimer = nil
    if sess == session and queueActive and not player then
      hs.alert.show("readflow: still fetching…")
    end
  end)
  beginProvider(text, sess)
end

-- ── hotkey ──────────────────────────────────────────────────────────────────
function readSelection() -- global: the hotkey action, callable from `hs -c` for testing
  if stop() then return end -- second press = stop playback

  local saved = hs.pasteboard.getContents()
  local count = hs.pasteboard.changeCount() -- detects whether Cmd+C actually copied
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)
  local tries = 0
  local function poll()
    tries = tries + 1
    if hs.pasteboard.changeCount() == count then
      if tries < 20 then return hs.timer.doAfter(0.05, poll) end
      return hs.alert.show("readflow: no selection")
    end
    local text = hs.pasteboard.getContents()
    if saved then hs.pasteboard.setContents(saved) end
    if not text or #text == 0 then return hs.alert.show("readflow: no selection") end
    hs.alert.show("🔊")
    speak(text)
  end
  hs.timer.doAfter(0.05, poll)
end

hs.hotkey.bind(CONFIG.hotkey.mods, CONFIG.hotkey.key, readSelection)

-- ── menu bar ────────────────────────────────────────────────────────────────
local function menubarIcon() -- small waveform, template so it adapts to menu bar theme
  local c = hs.canvas.new({ x = 0, y = 0, w = 18, h = 18 })
  for i, h in ipairs({ 6, 10, 14, 10, 6 }) do
    c[#c + 1] = {
      type = "rectangle", action = "fill", fillColor = { white = 0 },
      roundedRectRadii = { xRadius = 1, yRadius = 1 },
      frame = { x = 1 + (i - 1) * 3.5, y = (18 - h) / 2, w = 2.5, h = h },
    }
  end
  local img = c:imageFromCanvas()
  img:template(true)
  return img
end

local function promptKey()
  hs.focus()
  local button, key = hs.dialog.textPrompt(
    "Groq API key",
    "Paste your key from console.groq.com/keys.\nLeave empty to use the free built-in macOS voice.",
    setting("key", ""), "Save", "Cancel")
  if button == "Save" then
    hs.settings.set("readflow.key", key:gsub("%s", ""))
  end
end

local bar = hs.menubar.new()
bar:setIcon(menubarIcon())
bar:setTooltip("readflow — Ctrl+Esc reads your selection")
bar:setMenu(function()
  local voices = {}
  for _, v in ipairs(VOICES) do
    voices[#voices + 1] = {
      title = v:gsub("^%l", string.upper),
      checked = v == voice(),
      fn = function() hs.settings.set("readflow.voice", v) end,
    }
  end
  local hasKey = apiKey() ~= nil and #apiKey() > 0
  return {
    { title = "Select text, press Ctrl+Esc — again to stop", disabled = true },
    { title = "-" },
    { title = hasKey and "Groq API key ✓" or "Set Groq API key…", fn = promptKey },
    { title = "Voice", menu = voices, disabled = not hasKey },
    { title = "Test voice", fn = function()
        speak(hasKey and ("Hi, I'm " .. voice() .. ". I read whatever you select.")
          or "This is the built-in voice. Add a Groq key for nicer ones.")
      end },
    { title = "-" },
    { title = "GitHub", fn = function() hs.urlevent.openURL("https://github.com/michiosw/readflow") end },
    { title = "Reload config", fn = hs.reload },
    { title = "Quit readflow", fn = function() hs.application.get("Hammerspoon"):kill() end },
  }
end)
