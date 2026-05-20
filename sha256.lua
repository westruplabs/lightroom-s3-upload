-- Pure-Lua SHA-256 and HMAC-SHA-256
-- Targets Lightroom Classic (LuaJIT + 'bit' library).
-- Falls back to pure arithmetic if no bit library is found.

local M = {}

-- ── bit operations ───────────────────────────────────────────
local ok, bitlib = pcall(require, 'bit')          -- LuaJIT / Lightroom
if not ok then ok, bitlib = pcall(require, 'bit32') end  -- Lua 5.2 fallback

local band, bor, bxor, rshift, lshift, ror

if ok and bitlib then
  band   = bitlib.band
  bor    = bitlib.bor
  bxor   = bitlib.bxor
  rshift = bitlib.rshift
  lshift = bitlib.lshift
  ror    = bitlib.ror or function(x, n)
             return bor(rshift(x, n), lshift(x, 32 - n)) end
else
  -- Pure-math fallback (slow but correct for any Lua version)
  local M32 = 2^32
  band = function(a, b)
    local r, p = 0, 1
    a, b = a % M32, b % M32
    for _ = 1, 32 do
      if a % 2 == 1 and b % 2 == 1 then r = r + p end
      p = p * 2; a = math.floor(a/2); b = math.floor(b/2)
    end; return r
  end
  bor = function(a, b)
    local r, p = 0, 1
    a, b = a % M32, b % M32
    for _ = 1, 32 do
      if a % 2 == 1 or b % 2 == 1 then r = r + p end
      p = p * 2; a = math.floor(a/2); b = math.floor(b/2)
    end; return r
  end
  bxor = function(a, b)
    local r, p = 0, 1
    a, b = a % M32, b % M32
    for _ = 1, 32 do
      if a % 2 ~= b % 2 then r = r + p end
      p = p * 2; a = math.floor(a/2); b = math.floor(b/2)
    end; return r
  end
  rshift = function(a, n) return math.floor(a % M32 / 2^n) end
  lshift = function(a, n) return (a * 2^n) % M32 end
  ror    = function(a, n) return bor(rshift(a, n), lshift(a, 32 - n)) end
end

local MOD32 = 2^32

local function add(...)
  local s = 0
  for _, v in ipairs({...}) do s = s + v end
  return s % MOD32
end

-- ── SHA-256 round constants ───────────────────────────────────
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- ── process one 64-byte block ─────────────────────────────────
local function process_block(H, msg, i)
  local W = {}
  for j = 1, 16 do
    local p = i + (j - 1) * 4
    W[j] = bor(bor(bor(
      lshift(msg:byte(p),   24),
      lshift(msg:byte(p+1), 16)),
      lshift(msg:byte(p+2),  8)),
              msg:byte(p+3))
  end
  for j = 17, 64 do
    local w15 = W[j-15]; local w2 = W[j-2]
    local s0  = bxor(bxor(ror(w15,7),  ror(w15,18)), rshift(w15,3))
    local s1  = bxor(bxor(ror(w2, 17), ror(w2, 19)), rshift(w2, 10))
    W[j] = add(W[j-16], s0, W[j-7], s1)
  end

  local a,b,c,d,e,f,g,h = H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]
  for j = 1, 64 do
    local S1  = bxor(bxor(ror(e,6), ror(e,11)), ror(e,25))
    local ch  = bxor(band(e,f), band(bxor(e, 0xffffffff), g))
    local t1  = add(h, S1, ch, K[j], W[j])
    local S0  = bxor(bxor(ror(a,2), ror(a,13)), ror(a,22))
    local maj = bxor(bxor(band(a,b), band(a,c)), band(b,c))
    local t2  = add(S0, maj)
    h=g; g=f; f=e; e=add(d,t1); d=c; c=b; b=a; a=add(t1,t2)
  end
  H[1]=add(H[1],a); H[2]=add(H[2],b); H[3]=add(H[3],c); H[4]=add(H[4],d)
  H[5]=add(H[5],e); H[6]=add(H[6],f); H[7]=add(H[7],g); H[8]=add(H[8],h)
end

-- ── public: sha256(string) → hex string ──────────────────────
function M.sha256(msg)
  local H = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  }
  local len  = #msg
  msg = msg .. '\x80'
  while #msg % 64 ~= 56 do msg = msg .. '\x00' end

  local bits_lo = (len * 8) % MOD32
  local bits_hi = math.floor(len * 8 / MOD32)
  local function u32be(n)
    return string.char(
      math.floor(n/0x1000000)%256, math.floor(n/0x10000)%256,
      math.floor(n/0x100)%256,     n%256)
  end
  msg = msg .. u32be(bits_hi) .. u32be(bits_lo)

  for i = 1, #msg, 64 do process_block(H, msg, i) end

  return string.format('%08x%08x%08x%08x%08x%08x%08x%08x',
    H[1]%MOD32, H[2]%MOD32, H[3]%MOD32, H[4]%MOD32,
    H[5]%MOD32, H[6]%MOD32, H[7]%MOD32, H[8]%MOD32)
end

-- ── helpers ───────────────────────────────────────────────────
local function hex2bin(h)
  return (h:gsub('%x%x', function(b) return string.char(tonumber(b,16)) end))
end

-- public: hmac(key_bin_or_str, data) → hex string
function M.hmac(key, data)
  if #key > 64 then key = hex2bin(M.sha256(key)) end
  while #key < 64 do key = key .. '\0' end
  local ipad, opad = '', ''
  for i = 1, 64 do
    local k = key:byte(i)
    ipad = ipad .. string.char(bxor(k, 0x36))
    opad = opad .. string.char(bxor(k, 0x5c))
  end
  return M.sha256(opad .. hex2bin(M.sha256(ipad .. data)))
end

-- public: hmac_bin(key, data) → binary string (32 bytes)
function M.hmac_bin(key, data)
  return hex2bin(M.hmac(key, data))
end

return M
