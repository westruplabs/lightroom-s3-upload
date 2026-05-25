# S3Upload — Lightroom Classic Export Plugin

Export photos directly from Lightroom Classic to **Amazon S3** or **Cloudflare R2** (and any S3-compatible storage). Automatically creates thumbnails and uploads a `meta.json` sidecar file alongside each commission folder.

## Features

- Export photos directly to S3 / R2 from the Lightroom export dialog
- Automatically resize and upload thumbnails to a `thumbs/` subfolder
- Generates a `meta.json` file with title, client, and year — useful for portfolio websites driven by the S3 bucket
- Supports Amazon S3 (all regions) and Cloudflare R2 via custom endpoint
- Signing handled by curl's built-in `--aws-sigv4` — no external dependencies

## Requirements

- **Lightroom Classic**
- **macOS** — uses `/usr/bin/curl` (built-in) and `sips` (built-in) for thumbnails
- **Windows 10/11** — uses `curl` (built-in since Win10 1803). For thumbnails, [ImageMagick](https://imagemagick.org) must be installed separately. Without it, images still upload but thumbnails are skipped.

## Installation

1. Download or clone this repository
2. In Lightroom Classic, go to **File → Plug-in Manager**
3. Click **Add** and select the `S3Upload.lrplugin` folder
4. The plugin should show as "Installed and running" — click **Done**

## Setup

### Amazon S3

| Field | Value |
|---|---|
| Access Key ID | Your IAM user's access key |
| Secret Access Key | Your IAM user's secret key |
| Bucket | Your bucket name |
| Region | e.g. `us-east-1` or `eu-north-1` |
| Custom Endpoint | Leave blank |

Create an IAM user with `s3:PutObject` permission on your bucket.

### Cloudflare R2

| Field | Value |
|---|---|
| Access Key ID | R2 S3-compatible access key ID |
| Secret Access Key | R2 S3-compatible secret key |
| Bucket | Your R2 bucket name |
| Region | `auto` |
| Custom Endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |

Create S3-compatible credentials in the Cloudflare Dashboard under **R2 → Manage R2 API Tokens**.
Your Account ID and endpoint URL are shown under **R2 → your bucket → Settings**.

## Usage

1. Select photos in Lightroom Classic
2. Go to **File → Export**
3. Under **Export To**, choose **Amazon S3**
4. Fill in your S3/R2 credentials
5. Set **Key Prefix** to the folder path, e.g. `commissions/My-Project/`
6. Optionally fill in **Title**, **Client**, and **Year** — this creates a `meta.json` in the folder
7. Check **Upload thumbnail** if you want a resized copy in a `thumbs/` subfolder
8. Click **Export**

### Folder structure in S3

```
my-bucket/
  commissions/
    My-Project/
      meta.json
      photo-001.jpg
      photo-002.jpg
      thumbs/
        photo-001.jpg
        photo-002.jpg
```

## License

MIT License — free to use, modify, and distribute. Attribution appreciated but not required.

---

Developed by [westruplabs](https://www.westruplabs.com)
