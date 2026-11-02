-- Hammerspoon hotkey for voice-to-text.
-- Press the hotkey to start recording, press again to stop; the transcript
-- is copied to the clipboard and pasted at the cursor.
-- Menu bar: "○ REC" while the mic opens (don't talk yet), red "● REC" with a
-- sound once it is live, another sound when recording stops.
-- Load from ~/.hammerspoon/init.lua:
--   dofile("/path/to/voice-to-text/voice-to-text.lua")

local M = {}

-- The bash script lives next to this file.
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
M.script = here .. "voice-to-text"
M.hotkey = { mods = { "ctrl" }, key = "." }
M.state = "idle" -- idle | starting | recording | transcribing
-- Names from /System/Library/Sounds; set one to false to mute it.
M.sounds = { start = "Tink", stop = "Pop" }

local menu = hs.menubar.new()
local red = { red = 1, green = 0.23, blue = 0.19 }

local function setState(state)
  M.state = state
  local titles = {
    starting = "○ REC",
    recording = hs.styledtext.new("● REC", { color = red }),
    transcribing = "…",
  }
  if titles[state] then
    menu:returnToMenuBar()
    menu:setTitle(titles[state])
  else
    menu:removeFromMenuBar()
  end
end

-- Cached so a playing sound is not garbage-collected.
local loaded = {}
local function play(name)
  if not name then return end
  loaded[name] = loaded[name] or hs.sound.getByName(name)
  if loaded[name] then
    loaded[name]:stop()
    loaded[name]:play()
  end
end

local function run(args, onDone)
  hs.task.new(M.script, function(code, out, err)
    onDone(code, out or "", err or "")
  end, args):start()
end

function M.start()
  setState("starting")
  -- `start` exits once the mic delivers audio.
  run({ "start" }, function(code, _, err)
    if code ~= 0 then
      setState("idle")
      hs.alert.show("voice-to-text: " .. err)
      return
    end
    setState("recording")
    play(M.sounds.start)
  end)
end

function M.stop()
  setState("transcribing")
  play(M.sounds.stop) -- capture ends when `stop` signals ffmpeg, right after this
  run({ "stop" }, function(code, out, err)
    setState("idle")
    if code ~= 0 then
      hs.alert.show("voice-to-text: " .. err)
      return
    end
    if out == "" then
      hs.alert.show("voice-to-text: nothing heard")
      return
    end
    hs.pasteboard.setContents(out)
    hs.eventtap.keyStroke({ "cmd" }, "v")
  end)
end

function M.toggle()
  if M.state == "idle" then
    M.start()
  elseif M.state == "recording" then
    M.stop()
  end -- ignore presses while starting or transcribing
end

hs.hotkey.bind(M.hotkey.mods, M.hotkey.key, M.toggle)
setState("idle")

VoiceToText = M
return M
