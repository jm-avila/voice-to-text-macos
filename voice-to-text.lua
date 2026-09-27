-- Hammerspoon hotkey for voice-to-text.
-- Press the hotkey to start recording, press again to stop; the transcript
-- is copied to the clipboard and pasted at the cursor.
-- Load from ~/.hammerspoon/init.lua:
--   dofile("/path/to/voice-to-text/voice-to-text.lua")

local M = {}

-- The bash script lives next to this file.
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
M.script = here .. "voice-to-text"
M.hotkey = { mods = { "ctrl" }, key = "." }
M.state = "idle" -- idle | recording | transcribing

local menu = hs.menubar.new()

local function setState(state)
  M.state = state
  local titles = { idle = nil, recording = "● REC", transcribing = "…" }
  if titles[state] then
    menu:returnToMenuBar()
    menu:setTitle(titles[state])
  else
    menu:removeFromMenuBar()
  end
end

local function run(args, onDone)
  hs.task.new(M.script, function(code, out, err)
    onDone(code, out or "", err or "")
  end, args):start()
end

function M.start()
  setState("recording")
  run({ "start" }, function(code, _, err)
    if code ~= 0 then
      setState("idle")
      hs.alert.show("voice-to-text: " .. err)
    end
  end)
end

function M.stop()
  setState("transcribing")
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
  end -- ignore presses while transcribing
end

hs.hotkey.bind(M.hotkey.mods, M.hotkey.key, M.toggle)
setState("idle")

VoiceToText = M
return M
