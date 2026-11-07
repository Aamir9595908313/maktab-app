# Monthly backup to Google Drive - one-time setup

Every month (02:00 IST on the 2nd) GitHub exports the whole database (plus uploaded files),
zips it with a password, and saves it in your Google Drive folder **Maktab Backups**.
Last 24 months are kept. If anything fails, GitHub emails you.
You can also run it any time: GitHub > Actions > "Monthly backup to Google Drive" > Run workflow.

## Step 1 - Google Drive receiver (2 minutes, in YOUR Google account)
1. Open https://script.google.com > New project. Delete the sample code, paste the code below.
2. Replace `PASTE_A_LONG_RANDOM_TOKEN_HERE` with a long random password you make up (keep a copy).
3. Deploy > New deployment > type **Web app** > Execute as **Me** > Who has access **Anyone** > Deploy.
   Approve the Google permission prompt. Copy the **Web app URL**.

```js
const TOKEN = 'PASTE_A_LONG_RANDOM_TOKEN_HERE';
const FOLDER_NAME = 'Maktab Backups';
const KEEP_MONTHS = 24;

function doPost(e) {
  try {
    const req = JSON.parse(e.postData.contents);
    if (req.token !== TOKEN) return out({ ok: false, error: 'unauthorized' });
    const it0 = DriveApp.getFoldersByName(FOLDER_NAME);
    const folder = it0.hasNext() ? it0.next() : DriveApp.createFolder(FOLDER_NAME);
    const blob = Utilities.newBlob(Utilities.base64Decode(req.data), 'application/zip', req.filename);
    const file = folder.createFile(blob);
    const cutoff = new Date(); cutoff.setMonth(cutoff.getMonth() - KEEP_MONTHS);
    const files = folder.getFiles();
    while (files.hasNext()) { const f = files.next(); if (f.getDateCreated() < cutoff) f.setTrashed(true); }
    return out({ ok: true, id: file.getId(), name: file.getName(), size: file.getSize() });
  } catch (err) { return out({ ok: false, error: String(err) }); }
}
function out(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
```

## Step 2 - Add 4 secrets in GitHub (repo > Settings > Secrets and variables > Actions > New repository secret)
| Secret name | Value |
|---|---|
| `DRIVE_UPLOAD_URL` | the Web app URL from Step 1 |
| `DRIVE_UPLOAD_TOKEN` | the same random password you put in the script |
| `BACKUP_ZIP_PASSWORD` | a strong password to open the backup zip (store it safely - without it the backup cannot be opened) |
| `SUPABASE_DB_URL` | Supabase Dashboard > Connect > **Session pooler** connection string, with your database password filled in |

Optional (to also back up uploaded files such as photos and PDFs): `SUPABASE_URL` (the project URL) and
`SUPABASE_SERVICE_KEY` (Dashboard > Project Settings > API > service_role key).

Never share these values in chat or commit them anywhere.

## Step 3 - Test
Actions > Monthly backup to Google Drive > Run workflow. In ~2 minutes a file
`maktab-backup-YYYY-MM.zip` appears in Drive > Maktab Backups. The run page shows row counts per table.

## What is inside the zip (password protected, AES-256)
- `database_public.dump` - full database, restorable with `pg_restore`
- `csv/*.csv` - every table as a spreadsheet-readable file
- `auth_users_identities.sql` - login accounts
- `storage/` - uploaded files (if the optional secrets are set)
- `row_counts.txt` - quick completeness check

## Restore (when needed)
Open the zip with the password, then `pg_restore --no-owner -d <new database URL> database_public.dump`.
