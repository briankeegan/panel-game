-- Minimal LÖVE config for the lua-https-on-Android spike (throwaway).
function love.conf(t)
  t.identity = "https-spike"
  t.version = "11.5"
  t.window.width = 400
  t.window.height = 300
  t.window.title = "https spike"
  t.modules.audio = false
  t.modules.sound = false
  t.modules.physics = false
end
