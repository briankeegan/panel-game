-- Headless probe: no window/graphics/audio, just love.math for the RNG compare.
function love.conf(t)
  t.window = false
  t.modules.window = false
  t.modules.graphics = false
  t.modules.audio = false
  t.modules.sound = false
  t.modules.joystick = false
  t.modules.physics = false
end
