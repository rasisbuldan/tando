-- wrk script: one summary line (rps, p50/p95/p99/max ms, errors by kind, non-2xx/3xx)
-- WRK_HOST env sets the Host header (Caddy routes by it); WRK_CLOSE=1 sends Connection: close
local host = os.getenv("WRK_HOST")
local close = os.getenv("WRK_CLOSE") == "1"
local threads = {}
function setup(thread) table.insert(threads, thread) end
function init(args)
  if host and host ~= "" then wrk.headers["Host"] = host end
  if close then wrk.headers["Connection"] = "close" end
end
local known = {200, 301, 302, 400, 404, 408, 429, 500, 502, 503, 504}
function response(status, headers, body)
  local k = "c" .. status
  _G[k] = (_G[k] or 0) + 1
end
function done(summary, latency, requests)
  local merged = {}
  for _, t in ipairs(threads) do
    for _, s in ipairs(known) do
      local v = t:get("c" .. s)
      if v then merged[s] = (merged[s] or 0) + v end
    end
  end
  local cs = {}
  for k, v in pairs(merged) do table.insert(cs, k .. ":" .. v) end
  table.sort(cs)
  local e = summary.errors
  io.write(string.format("RESULT requests=%d secs=%.1f rps=%.0f p50_ms=%.1f p95_ms=%.1f p99_ms=%.1f max_ms=%.1f err_connect=%d err_read=%d err_write=%d err_timeout=%d non2xx3xx=%d codes=%s\n",
    summary.requests, summary.duration / 1e6, summary.requests / (summary.duration / 1e6),
    latency:percentile(50) / 1000, latency:percentile(95) / 1000, latency:percentile(99) / 1000,
    latency.max / 1000, e.connect, e.read, e.write, e.timeout, e.status, table.concat(cs, ",")))
end
