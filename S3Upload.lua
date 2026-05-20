-- S3Upload.lua
-- Uploads files to S3 / Cloudflare R2 using AWS Signature Version 4.
-- macOS: uses /usr/bin/curl + sips
-- Windows: uses curl (built-in Win10/11) + ImageMagick (magick) for thumbnails

local sha256 = require 'sha256'
local M = {}

-- ── OS detection ──────────────────────────────────────────────
local IS_WIN = package.config:sub(1, 1) == '\\'

-- ── helpers ───────────────────────────────────────────────────

local function encode_path(s)
  return (s:gsub('[^A-Za-z0-9%-_%.~/]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

-- Shell-quote a string for the current OS
local function sh(s)
  if IS_WIN then
    -- Windows cmd: wrap in double quotes, escape internal double quotes
    return '"' .. s:gsub('"', '\\"') .. '"'
  else
    -- macOS/Linux: wrap in single quotes, escape internal single quotes
    return "'" .. s:gsub("'", "'\\''") .. "'"
  end
end

-- Platform-specific helpers
local CURL     = IS_WIN and 'curl'         or '/usr/bin/curl'
local DEV_NULL = IS_WIN and 'NUL'          or '/dev/null'
local RM       = IS_WIN and 'del /f /q '   or 'rm -f '

local function tmp_path(suffix)
  -- os.tmpname() works cross-platform; append suffix for correct MIME detection
  local base = os.tmpname()
  if IS_WIN then base = os.getenv('TEMP') .. '\\s3upload_' .. os.time() end
  return base .. (suffix or '')
end

local function mime_type(path)
  local ext = (path:match('%.([^.]+)$') or ''):lower()
  return ({ jpg='image/jpeg', jpeg='image/jpeg',
            png='image/png', tif='image/tiff', tiff='image/tiff' })[ext]
         or 'application/octet-stream'
end

local function popen_read(cmd)
  local fh  = io.popen(cmd)
  local out = fh and fh:read('*all') or ''
  if fh then fh:close() end
  return out
end

-- ── core: upload one file via curl --aws-sigv4 ───────────────

local function put(p, file_path, s3_key)
  local datetime = os.date('!%Y%m%dT%H%M%SZ')
  local date     = os.date('!%Y%m%d')
  local ctype    = mime_type(file_path)

  -- Build host + URI
  local host, uri
  if p.endpoint and p.endpoint ~= '' then
    local ep = (p.endpoint:match('[^\r\n]+') or p.endpoint)
      :gsub('%s', '')
      :gsub('^https?://', '')
      :gsub('/+$', '')
    host = ep
    uri  = '/' .. encode_path(p.bucket) .. '/' .. encode_path(s3_key)
  else
    host = p.bucket .. '.s3.' .. p.region .. '.amazonaws.com'
    uri  = '/' .. encode_path(s3_key)
  end
  local url = 'https://' .. host .. uri

  -- SigV4 signing (used as fallback via LrHttp)
  local scope = date .. '/' .. p.region .. '/s3/aws4_request'
  local canon_hdrs =
    'content-type:'         .. ctype    .. '\n' ..
    'host:'                 .. host     .. '\n' ..
    'x-amz-content-sha256:UNSIGNED-PAYLOAD\n'   ..
    'x-amz-date:'           .. datetime .. '\n'
  local signed = 'content-type;host;x-amz-content-sha256;x-amz-date'
  local canon  = table.concat({'PUT', uri, '', canon_hdrs, signed, 'UNSIGNED-PAYLOAD'}, '\n')
  local sts    = table.concat({'AWS4-HMAC-SHA256', datetime, scope, sha256.sha256(canon)}, '\n')
  local kd     = sha256.hmac_bin('AWS4' .. p.secret_key, date)
  local sig    = sha256.hmac(sha256.hmac_bin(sha256.hmac_bin(sha256.hmac_bin(kd, p.region), 's3'), 'aws4_request'), sts)
  local auth   = string.format(
    'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s',
    p.access_key, scope, signed, sig)

  -- ── Primary: curl --aws-sigv4 ────────────────────────────────
  -- macOS: -k because LibreSSL has TLS compat issues with Cloudflare R2
  -- Windows: no -k needed (uses Schannel/WinSSL which works fine)
  local curl_flags = IS_WIN and '-sS' or '-sS -k'
  local cmd = CURL .. ' ' .. curl_flags
    .. ' -w "\\nHTTPSTATUS:%{http_code}"'
    .. ' -X PUT'
    .. ' --aws-sigv4 ' .. sh('aws:amz:' .. p.region .. ':s3')
    .. ' --user '      .. sh(p.access_key .. ':' .. p.secret_key)
    .. ' -H '          .. sh('Content-Type: ' .. ctype)
    .. ' --data-binary ' .. sh('@' .. file_path)
    .. ' '             .. sh(url)
    .. ' 2>&1'

  local cout = popen_read(cmd)
  local cs   = tonumber(cout:match('HTTPSTATUS:(%d+)'))
  if cs == 200 or cs == 204 then return true end

  -- ── Fallback: LrHttp with our own SigV4 ─────────────────────
  local LrHttp = import 'LrHttp'
  local fh2, err2 = io.open(file_path, 'rb')
  if not fh2 then return false, 'Cannot open file: ' .. (err2 or '?') end
  local body = fh2:read('*all'); fh2:close()

  local lrhdrs = {
    { field = 'Authorization',        value = auth },
    { field = 'Content-Type',         value = ctype },
    { field = 'x-amz-content-sha256', value = 'UNSIGNED-PAYLOAD' },
    { field = 'x-amz-date',           value = datetime },
    { field = 'Content-Length',       value = tostring(#body) },
  }
  local resp_body, resp_hdrs = LrHttp.post(url, body, lrhdrs, 'PUT', 120)
  local lrstatus = (type(resp_hdrs) == 'table' and resp_hdrs.status) or 0
  if lrstatus == 200 or lrstatus == 204 then return true end

  local cd = (cout:match('^(.-)%s*HTTPSTATUS:') or cout):gsub('%s+', ' '):sub(1, 120)
  local ld = tostring(resp_body or ''):gsub('%s+', ' '):sub(1, 120)
  return false, string.format('curl HTTP %s: %s | LrHttp HTTP %d: %s',
    tostring(cs), cd, lrstatus, ld)
end

-- ── thumbnail creation ────────────────────────────────────────

local function make_thumb(src, max_px)
  local dst = src:gsub('%.([^.]+)$', '_lrthumb.%1')

  if IS_WIN then
    -- Windows: use ImageMagick (magick) if available, else skip
    local cmd = string.format('magick %s -resize %dx%d> %s 2>&1',
      sh(src), max_px, max_px, sh(dst))
    popen_read(cmd)
  else
    -- macOS: use sips (built-in)
    local cmd = string.format('sips -Z %d %s --out %s > %s 2>&1',
      max_px, sh(src), sh(dst), DEV_NULL)
    popen_read(cmd)
  end

  local test = io.open(dst, 'rb')
  if test then test:close(); return dst end

  if IS_WIN then
    return nil, 'Thumbnail failed — is ImageMagick installed? (https://imagemagick.org)'
  end
  return nil, 'sips failed'
end

-- ── upload string content (for meta.json) ────────────────────

function M.upload_string(p, content, s3_key)
  local tmp = tmp_path('.json')
  local fh  = io.open(tmp, 'w')
  if not fh then return false, 'Cannot create temp file' end
  fh:write(content); fh:close()

  local ok, err = M.upload {
    access_key = p.access_key, secret_key = p.secret_key,
    region = p.region, bucket = p.bucket, endpoint = p.endpoint,
    key = s3_key, file_path = tmp, thumb = false,
  }
  popen_read(RM .. sh(tmp))
  return ok, err
end

-- ── public API ────────────────────────────────────────────────

function M.upload(p)
  local ok, err = put(p, p.file_path, p.key)
  if not ok then return false, err end

  if p.thumb then
    local dir, filename = p.key:match('^(.*)/([^/]+)$')
    local thumb_key = dir and (dir .. '/thumbs/' .. filename) or ('thumbs/' .. p.key)

    local thumb_path, thumb_err = make_thumb(p.file_path, p.thumb_size or 800)
    if not thumb_path then
      return true, 'Image uploaded, but thumbnail failed: ' .. (thumb_err or '?')
    end

    local tok, terr = put(p, thumb_path, thumb_key)
    popen_read(RM .. sh(thumb_path))

    if not tok then
      return true, 'Image uploaded, but thumbnail upload failed: ' .. (terr or '?')
    end
  end

  return true
end

return M
