-- SPIKE: prove lua-https loads and does an HTTPS 200 to GitHub from inside
-- love-android 11.5a. Prints a sentinel line to logcat that CI greps for.
-- Sentinels: "HTTPS_SPIKE OK" (pass) / "HTTPS_SPIKE FAIL ..." (fail).

local status = "running..."

function love.load()
  local ok, https = pcall(require, "https")
  if not ok then
    status = "FAIL require: " .. tostring(https)
    print("HTTPS_SPIKE FAIL require: " .. tostring(https))
    return
  end

  -- Small response on purpose; the JNI/HttpURLConnection backend de-chunks
  -- regardless, but this keeps the smoke test quick.
  local url = "https://api.github.com/repos/love2d/love/releases?per_page=1"
  local code, body = https.request(url)
  local len = body and #body or 0
  print(string.format("HTTPS_SPIKE code=%s len=%d", tostring(code), len))

  if code == 200 and len > 0 then
    status = "OK code=200 len=" .. len
    print("HTTPS_SPIKE OK")
  else
    status = "FAIL code=" .. tostring(code)
    print("HTTPS_SPIKE FAIL code=" .. tostring(code))
  end
end

function love.draw()
  love.graphics.printf("https spike\n" .. status, 0, 120, 400, "center")
end

-- let `adb shell input keyevent BACK` or the watchdog close it
function love.keypressed(k) if k == "escape" then love.event.quit() end end
