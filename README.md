<p align="center">
  <img src="Resources/AppIconSource.png" width="160" alt="Pošćar icon: Žuća the postman">
</p>

<h1 align="center">Pošćar</h1>

A fast, keyboard-first mail app for macOS. On disk, in Homebrew and in paths it is plain `Poscar`. Gmail shortcuts by default, and every button shows its
shortcut, Raycast style. Works with Gmail and any IMAP server, with all accounts in one inbox.
No calendar, no contacts app, no AI: mail only.

- Vim-flavoured Gmail shortcuts out of the box (`j`/`k`, `h`/`l`, `gg`/`G`, `dd`, `e`, `r`, `c`,
  `/`, `g i`, …), with plain Gmail and Superhuman presets, and every shortcut can be changed.
- `⌘K` opens Raycast-style actions for the selected conversation, and `⌘P` a palette with every
  command, label and account.
- A unified inbox with conversations (threads), as in Gmail.
- Undo (`z`) for any action, plus undo send and send later.
- Markdown when writing: you type plain text, and it is sent as plain text plus HTML.
- Remote images are blocked until you press `i`.
- New mail arrives instantly through IMAP IDLE, with notifications and a Dock badge.
- A local cache with headers of all mail and bodies of the last 90 days, so lists open instantly.

## Install

Requires macOS 14+ on Apple silicon.

```sh
brew tap aleksandargosevski/tap
brew install poscar
ln -sfn "$(brew --prefix)/opt/poscar/Poscar.app" /Applications/Poscar.app
```

The link makes Poscar visible to Spotlight, Raycast and the Dock, and keeps pointing at the newest
version after `brew upgrade`.

## Accounts

**Gmail / Google Workspace**: click **Sign in with Google**, pick the account in the browser and
allow access. Poscar stores only an OAuth refresh token in the keychain and logs in to IMAP and SMTP
with short-lived access tokens (XOAUTH2). An [App Password](https://myaccount.google.com/apppasswords)
still works as an alternative. Poscar uses Gmail's IMAP extensions for labels, threads and Gmail
search syntax (`from:ana has:attachment`).

Google sign-in needs an OAuth client of type "Desktop app" in Google Cloud, with the Gmail API
enabled and the consent screen published ("In production"; it may stay unverified for up to 100
users). Its ID and secret are written into the app's Info.plist at build time: locally from
`scripts/google-client.env` (git-ignored), in CI from repository secrets. They are kept out of the
repository because GitHub reports Google secrets it finds, and Google then disables the client.

```sh
# scripts/google-client.env
POSCAR_GOOGLE_CLIENT_ID=….apps.googleusercontent.com
POSCAR_GOOGLE_CLIENT_SECRET=GOCSPX-…
```

**iCloud, Fastmail** and other providers also use an app-specific password. **Other IMAP** servers
need IMAP over TLS (port 993) and SMTP with TLS (465) or STARTTLS (587).

Passwords are stored in the macOS keychain. Settings live in
`~/Library/Application Support/Poscar/accounts.json`, and the mail cache in `mail.sqlite` next to it.

## Shortcuts

Press `?` in the app for the full list, or `⌘P` to search commands. The defaults (Vim preset):

| | |
|---|---|
| `j` / `k` | next / previous conversation |
| `o`, `l` or `↩` / `u` or `h` | open conversation / back to list |
| `g g` / `G` | first / last conversation |
| `n` / `p` | next / previous message in a conversation |
| `e` / `#` or `d d` / `!` | archive / delete / spam |
| `s`, `⇧I`, `⇧U` | star, mark read, mark unread |
| `x`, `* a`, `* n` | select, select all, deselect |
| `⇧L` / `v` / `y` | label / move to / remove the current label |
| `z` | undo |
| `c` / `r` / `a` / `f` | compose / reply / reply all / forward |
| `g i`, `g s`, `g t`, `g d`, `g a` | inbox, starred, sent, drafts, all mail |
| `g l`, `g o` | go to label, scheduled messages |
| `⌘0`, `⌘1`…`⌘5` | all accounts, one account |
| `/` or `⌘F` | search all accounts and folders; `from:`, `to:` and `in:` (e.g. `in:sent`, `in:trash`, a label) complete as you type |
| `g f` | attachments of all accounts, with previews, filterable by type and account |
| `⌘K`, `⌘P`, `?` | actions for the selection, all commands, shortcut list |
| `⌘R`, `⌘S` | check for mail, toggle the sidebar |
| `i`, `⇧O` | load images, open attachments |
| `space` / `⇧space`, `⌃d` / `⌃u` | scroll the open conversation down / up |
| `⌘↩`, `⌘⇧↩`, `⌘⇧A` | send, send later, attach (in the composer) |
| `⌘⇧P` | switch between writing and a preview of the message as it will be sent |

`⌃⌥M` shows or hides Poscar from any app. Change it in **Settings → General**, where Poscar can
also leave the Dock and live only in the menu bar with its unread count.

Shortcuts work on any keyboard layout, Cyrillic included: keys are matched by position when the
layout does not produce Latin letters.

Change shortcuts in **Settings → Shortcuts**: click a shortcut and press the new keys (sequences
like `g` then `i` work). Changes are saved to `~/.config/poscar/keybindings.json`, which can be kept
in dotfiles:

```json
{
  "preset": "gmail",
  "bindings": {
    "archive": ["e", "y"],
    "goInbox": ["g i"],
    "commandPalette": ["cmd+k", "cmd+p"]
  }
}
```

Only overrides are stored; everything else comes from the preset (`gmail`, `superhuman` or `vim`).
Keys are written as `e`, `#`, `I` (shift is implied by the character), `cmd+shift+a`, `enter`,
`esc`, `space`, `up`, and sequences are separated by spaces.

## Privacy

Poscar runs entirely on your Mac. It talks only to your mail servers (for Gmail, Google's IMAP,
SMTP and sign-in endpoints) and never sends your mail, contacts or usage data anywhere else.

- Mail is cached in a local database in `~/Library/Application Support/Poscar`.
- Passwords and Google sign-in tokens are stored in the macOS keychain.
- With Google sign-in, Poscar requests access to Gmail (`https://mail.google.com/`) to read,
  organise and send your mail over IMAP and SMTP, and your email address and name to set up the
  account. This data is used only inside the app and is not shared with anyone.
- Remote images in messages are blocked until you load them, so senders can't track opens.
- Removing an account deletes its local mail and keychain items. Revoke Google access any time at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

## Troubleshooting

Poscar keeps running when its window is closed, so new mail and notifications keep arriving; click
the Dock icon, the menu bar item or the global shortcut to bring it back, and quit with `⌘Q`.
Launches, quits (and who asked for them) and window closes are logged to
`~/Library/Logs/Poscar/poscar.log`. Crash reports are in `~/Library/Logs/DiagnosticReports`.

## Known limits

- Drafts are not saved: closing the composer asks to discard.
- Send later and undo send run inside Poscar. A scheduled message is sent while the app is running,
  or the next time it starts.
- IMAP needs TLS on connect (port 993). STARTTLS is supported for SMTP only.

## Install from source

Requires the Xcode Command Line Tools.

```sh
./scripts/create-cert.sh   # once: self-signed "Poscar Dev" signing certificate
./scripts/install.sh       # builds and installs into ~/Applications, then starts the app
```

Every build is signed with the same certificate, so the keychain keeps trusting Poscar with saved
passwords across rebuilds.

## Development

```sh
./scripts/build.sh --run   # build into ./build and restart
./scripts/test.sh          # run tests
POSCAR_NETWORK_TESTS=1 ./scripts/test.sh   # also check TLS/STARTTLS against Gmail's servers
swift scripts/make-icon.swift Resources/AppIcon.icns   # regenerate the app icon
```

`Sources/PoscarCore` holds everything that is not UI, and is unit tested:

- an IMAP client (`IMAP/`) and an SMTP client (`SMTP/`)
- MIME parsing and building, and Markdown rendering (`Mail/`)
- the SQLite cache with full-text search (`Store/`, using GRDB)
- sync, plus the planner that turns actions into local changes and server commands (`Sync/`)
- keymaps and key sequences (`Keys/`), and conversation HTML (`Render/`)

`Sources/Poscar` is the SwiftUI/AppKit app. `KeyboardRouter` sends key presses to commands, and
`ActionQueue` applies actions locally at once and commits them to the server 5 seconds later,
which is what makes `z` instant.

## Releasing

Pushing a tag like `v1.2.3` runs `.github/workflows/release.yml`, which tests, builds and signs the
app, publishes `Poscar-1.2.3.zip` as a GitHub release and updates `poscar.rb` in
[aleksandargosevski/homebrew-tap](https://github.com/aleksandargosevski/homebrew-tap).

Required repository secrets:

| Secret | Value |
|---|---|
| `POSCAR_CERT_P12_BASE64` | `base64 -i poscar-dev.p12` of the "Poscar Dev" certificate exported from Keychain Access |
| `POSCAR_CERT_PASSWORD` | password chosen when exporting the `.p12` |
| `HOMEBREW_TAP_TOKEN` | fine-grained token with Contents: read and write on the tap repository |
| `POSCAR_GOOGLE_CLIENT_ID` | OAuth client ID for Google sign-in |
| `POSCAR_GOOGLE_CLIENT_SECRET` | OAuth client secret for Google sign-in |

Releases must always be signed with the same certificate. A new certificate makes the keychain ask
again for access to every saved password.
