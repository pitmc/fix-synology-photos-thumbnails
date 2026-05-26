# Synology Photos Thumbnail Fix

Fixes Synology Photos when thumbnails stop showing, folders appear empty, or the app gets stuck in a video conversion loop.

## Symptoms

- Photos app shows broken thumbnails or empty folders
- Log shows repeated `video file already exist` errors (infinite loop)
- `metadata-wrapper is empty` errors during indexing
- Thumbnails exist in database but not on disk (or vice versa)

## Root Causes

1. **Video conversion loop** — `SYNOPHOTO_FILM_H.mp4` files in `@eaDir` cause Photos to retry endlessly
2. **Stale `@eaDir`** — corrupted or outdated thumbnail/metadata cache
3. **DB/disk mismatch** — database says thumbnails exist but files are missing

## What This Script Does

| Step | Action | Risk |
|------|--------|------|
| 1 | Stop Synology Photos | None |
| 2 | Delete `SYNOPHOTO_FILM_H.mp4` and `.fail` files | Removes transcoded video copies (regenerable) |
| 3 | Delete all `@eaDir` directories | Removes thumbnail cache (regenerable, never touches originals) |
| 4 | Truncate thumbnail DB tables | Clears stale records |
| 5 | Reset `index_stage` to 71 | Forces Photos to re-process all items |
| 6 | Start Photos | You trigger reindex from web UI |
| 7 | Delete 0-byte files (optional) | Removes corrupted/empty files |

**Original photos and videos are NEVER modified or deleted.**

Albums, shared links, facial recognition data, and user configuration are preserved.

## Requirements

- Synology DSM 7.x
- Synology Photos 1.7+
- Root/sudo access via SSH
- Terminal & SNMP enabled in Control Panel

## Usage

SSH into your NAS:

```bash
ssh your-user@your-nas-ip
```

Clone and run:

```bash
sudo git clone https://github.com/pit-mce/synology-photos-fix.git /tmp/synology-photos-fix
cd /tmp/synology-photos-fix
sudo sh fix-synology-photos.sh
```

Or download directly:

```bash
curl -sL https://raw.githubusercontent.com/pit-mce/synology-photos-fix/main/fix-synology-photos.sh -o /tmp/fix-synology-photos.sh
sudo sh /tmp/fix-synology-photos.sh
```

## After Running

1. Open Synology Photos in your browser
2. Go to **Settings → Reindex** (trigger both personal and shared space)
3. Wait 12-48 hours for thumbnail regeneration (depends on library size)
4. CPU will run at ~99% during regeneration — this is normal

### Monitor Progress

```bash
sudo -u postgres psql -d synofoto -c "SELECT (SELECT COUNT(*) FROM thumbnail) as thumbnails, (SELECT COUNT(*) FROM index_queue) as queue;"
```

- `queue` fills to ~total items, then drains to 0
- `thumbnails` grows to ~4x total items (4 sizes per photo)

### Check for Errors

```bash
sudo tail -20 /var/packages/SynologyPhotos/var/log/synofoto.log
```

### Validate Filesystem vs Database

```bash
# Count files on disk
find /volume1/photo -type f -not -path "*@eaDir*" -not -path "*#recycle*" | wc -l
find /volume1/homes -path "*/Photos/*" -type f -not -path "*@eaDir*" -not -path "*#recycle*" | wc -l

# Count in database
sudo -u postgres psql -d synofoto -c "SELECT COUNT(*) FROM unit;"
```

Filesystem count will be slightly higher than DB (auxiliary files like `.THM`, `.LRV`, `.WAV` are not indexed).

## Important Notes

- **DO NOT** press "Generate AVC previews" in Photos UI — it causes the video conversion loop
- If the video loop returns: delete `SYNOPHOTO_FILM_H.mp4` files + run `TRUNCATE convert_thumbnail_allocation;`
- The script is interactive — it asks for confirmation before each destructive step
- Tested with 1.2TB / 269k photos / Synology Photos 1.9.x on DSM 7.2

## If You Use Hyper Backup

Disable the backup schedule before running this script (the regeneration process causes heavy I/O). Re-enable after thumbnails finish generating.

## License

MIT
