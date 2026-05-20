-- ExportServiceProvider.lua
-- Lightroom Classic export service: exports photos and uploads each one to Amazon S3.

local LrDialogs   = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrView      = import 'LrView'

local S3Upload = require 'S3Upload'

local provider = {}

-- Hide the "Export To" section — files go straight to S3
provider.hideSections = { 'exportLocation' }

-- ── Persistent settings ───────────────────────────────────────
provider.exportPresetFields = {
  { key = 's3_access_key', default = '' },
  { key = 's3_secret_key', default = '' },
  { key = 's3_bucket',     default = '' },
  { key = 's3_region',     default = 'eu-north-1' },
  { key = 's3_prefix',     default = '' },
  { key = 's3_endpoint',   default = '' },
  { key = 's3_thumbs',     default = true },
  { key = 's3_thumb_size', default = '800' },
  { key = 's3_title',      default = '' },
  { key = 's3_client',     default = '' },
  { key = 's3_year',       default = '' },
}

-- ── Export-dialog UI section ──────────────────────────────────
function provider.sectionsForBottomOfDialog(f, props)
  local bind = LrView.bind
  return {
    {
      title = 'Amazon S3',

      synopsis = function(p)
        if p.s3_bucket ~= '' then
          return p.s3_bucket .. '/' .. (p.s3_prefix ~= '' and p.s3_prefix or '')
        end
        return 'Not configured'
      end,

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Access Key ID', width = 130 },
        f:edit_field {
          value               = bind 's3_access_key',
          width_in_chars      = 30,
          placeholder_string  = 'AKIAIOSFODNN7EXAMPLE',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Secret Access Key', width = 130 },
        f:edit_field {
          value               = bind 's3_secret_key',
          width_in_chars      = 40,
          placeholder_string  = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Bucket', width = 130 },
        f:edit_field {
          value               = bind 's3_bucket',
          width_in_chars      = 22,
          placeholder_string  = 'my-photo-bucket',
        },
        f:spacer { width = 16 },
        f:static_text { title = 'Region', width = 50 },
        f:edit_field {
          value               = bind 's3_region',
          width_in_chars      = 14,
          placeholder_string  = 'auto',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Custom Endpoint', width = 130 },
        f:edit_field {
          value               = bind 's3_endpoint',
          width_in_chars      = 50,
          placeholder_string  = 'Cloudflare R2: https://xxx.r2.cloudflarestorage.com  (leave blank for AWS)',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Key Prefix (folder)', width = 130 },
        f:edit_field {
          value               = bind 's3_prefix',
          width_in_chars      = 40,
          placeholder_string  = 'photos/2024/  (leave blank for bucket root)',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = '', width = 130 },
        f:checkbox {
          title = 'Ladda upp thumbnail automatiskt (i thumbs/-undermapp)',
          value = bind 's3_thumbs',
        },
      },

      f:row {
        enabled = bind 's3_thumbs',
        spacing = f:label_spacing(),
        f:static_text { title = 'Thumbnail max px', width = 130 },
        f:edit_field {
          value          = bind 's3_thumb_size',
          width_in_chars = 6,
          placeholder_string = '800',
        },
        f:static_text {
          title = 'px (längsta sidan) — hamnar i [mapp]/thumbs/filnamn.jpg',
          font  = '<system/small>',
        },
      },

      f:separator { fill_horizontal = 1 },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Titel (commission)', width = 130 },
        f:edit_field {
          value              = bind 's3_title',
          width_in_chars     = 36,
          placeholder_string = 't.ex. Kungen',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'Klient', width = 130 },
        f:edit_field {
          value              = bind 's3_client',
          width_in_chars     = 36,
          placeholder_string = 't.ex. Kungliga hovet (valfritt)',
        },
      },

      f:row {
        spacing = f:label_spacing(),
        f:static_text { title = 'År', width = 130 },
        f:edit_field {
          value              = bind 's3_year',
          width_in_chars     = 8,
          placeholder_string = tostring(os.date('*t').year),
        },
      },

      f:row {
        f:static_text {
          title = 'Tips: Cloudflare R2 → Region = auto, Custom Endpoint = https://[account-id].r2.cloudflarestorage.com',
          font  = '<system/small>',
          width_in_chars = 70,
        },
      },
    },
  }
end

-- ── Validate settings before export ──────────────────────────
function provider.startDialog(props)
  -- nothing needed on open
end

-- ── Called after Lightroom has rendered each photo ────────────
function provider.processRenderedPhotos(functionContext, exportContext)
  local session  = exportContext.exportSession
  local settings = exportContext.propertyTable
  local nPhotos  = session:countRenditions()

  local progress = exportContext:configureProgress {
    title = string.format('Uploading %d photo(s) to S3…', nPhotos),
  }

  -- Validate credentials
  if settings.s3_access_key == '' or settings.s3_secret_key == '' or settings.s3_bucket == '' then
    LrDialogs.message('S3 Upload',
      'Please fill in your Access Key, Secret Key, and Bucket name\nin the S3 section of the Export dialog.',
      'critical')
    return
  end

  -- Normalise prefix: ensure trailing slash
  local prefix = settings.s3_prefix or ''
  if prefix ~= '' and prefix:sub(-1) ~= '/' then prefix = prefix .. '/' end

  local uploaded = 0
  local errors   = {}

  for i, rendition in session:renditions() do
    progress:setPortionComplete(i - 1, nPhotos)

    local ok, pathOrMsg = rendition:waitForRender()

    if ok then
      local filename = LrPathUtils.leafName(pathOrMsg)
      local s3key    = prefix .. filename
      progress:setCaption(filename)

      local uploaded_ok, err = S3Upload.upload {
        access_key = settings.s3_access_key,
        secret_key = settings.s3_secret_key,
        region     = settings.s3_region,
        bucket     = settings.s3_bucket,
        key        = s3key,
        file_path  = pathOrMsg,
        endpoint   = settings.s3_endpoint,
        thumb      = settings.s3_thumbs,
        thumb_size = tonumber(settings.s3_thumb_size) or 800,
      }

      if uploaded_ok then
        uploaded = uploaded + 1
      else
        table.insert(errors, filename .. ': ' .. (err or 'unknown error'))
      end

      -- Clean up the temporary rendered file
      LrFileUtils.delete(pathOrMsg)

    else
      -- pathOrMsg is the render error message in this case
      table.insert(errors, tostring(pathOrMsg))
    end

    if progress:isCanceled() then break end
  end

  progress:setPortionComplete(nPhotos, nPhotos)

  -- Upload meta.json if title is set
  if uploaded > 0 and settings.s3_title ~= '' then
    local year = settings.s3_year ~= '' and settings.s3_year
                 or tostring(os.date('*t').year)
    local json = string.format(
      '{"title":%q,"client":%q,"year":%q}',
      settings.s3_title, settings.s3_client or '', year)
    local meta_key = prefix .. 'meta.json'
    local mok, merr = S3Upload.upload_string(
      { access_key = settings.s3_access_key,
        secret_key = settings.s3_secret_key,
        region     = settings.s3_region,
        bucket     = settings.s3_bucket,
        endpoint   = settings.s3_endpoint },
      json, meta_key, 'application/json')
    if not mok then
      table.insert(errors, 'meta.json: ' .. (merr or '?'))
    end
  end

  if #errors == 0 then
    LrDialogs.message('S3 Upload Complete',
      string.format('✓ %d photo(s) uploaded to s3://%s/%s',
        uploaded, settings.s3_bucket, prefix))
  else
    LrDialogs.message('S3 Upload — Finished with errors',
      string.format('%d uploaded, %d failed:\n\n%s',
        uploaded, #errors, table.concat(errors, '\n')),
      'warning')
  end
end

return provider
