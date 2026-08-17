# MacWhisper Screen Sharing Bridge

A small macOS helper that makes third-party dictation work reliably inside
Apple's Screen Sharing app.

Native macOS Dictation works while controlling another Mac through Screen
Sharing. Third-party dictation tools have a harder problem: their simulated
typing can lose capitalization and punctuation, while a synthetic Command+V
may be forwarded to the remote Mac as a plain `v`. Clipboard synchronization
can also race the dictation app's own paste and cleanup behavior.

This project demonstrates one practical bridge between
[MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper),
[BetterTouchTool](https://folivora.ai/), and Apple Screen Sharing. It is
especially useful when a lightweight Mac acts as a thin client for a more
powerful Mac elsewhere.

## How it works

1. BetterTouchTool intercepts the Globe/Fn key only while Screen Sharing is
   active and launches this helper.
2. The helper presents a small local capture toast and asks BetterTouchTool to
   send the Globe key to MacWhisper.
3. It watches MacWhisper's local SQLite database in read-only mode for the next
   completed dictation.
4. If MacWhisper uses an AI cleanup prompt, the helper waits for
   `processedText` rather than capturing the earlier unpolished transcript.
5. Paragraph breaks and repeated whitespace are flattened so they cannot turn
   into accidental Return keystrokes on the remote Mac.
6. The final text is placed on the local clipboard twice, followed by a short
   propagation delay.
7. BetterTouchTool sends one deliberately paced Command+V chord into Screen
   Sharing. The polished transcript remains on the clipboard afterward.

The helper never sends the transcript over the network itself. Screen Sharing
continues to provide the clipboard transport to the remote Mac.

## Requirements

- macOS 26 Tahoe and the matching Command Line Tools
- Apple Screen Sharing (`com.apple.ScreenSharing`)
- MacWhisper with Dictation enabled
- BetterTouchTool with Accessibility permission
- **Use Shared Clipboard** enabled in Screen Sharing's Edit menu

The current implementation was developed against MacWhisper 14.6 and
BetterTouchTool 6.640. MacWhisper's database is not a documented public API, so
future versions may require a schema adjustment.

## Build

Clone the repository and run:

```sh
./scripts/build.sh
```

The ad-hoc signed app will be written to:

```text
dist/Screen Sharing Dictation.app
```

Move the app somewhere permanent before configuring BetterTouchTool. A path
such as `~/Applications/Screen Sharing Dictation.app` works well. Rebuilding or
moving the app may cause macOS to request permissions again.

## Configure MacWhisper

1. Open MacWhisper's Dictation settings.
2. Set the dictation activation key to **Globe/Fn**.
3. Configure any transcription-polishing prompt you normally use.

The helper waits for polishing to finish, even when transcription takes tens
of seconds.

## Configure BetterTouchTool

1. Add an app-specific configuration for **Screen Sharing**.
2. Add a keyboard trigger for the physical **Globe/Fn** key.
3. Assign **Launch Application / Open File / Start Apple Script**.
4. Select the permanent copy of `Screen Sharing Dictation.app`.
5. Ensure BetterTouchTool itself is enabled for Screen Sharing and is not
   globally disabled.

The trigger must be app-specific. After BetterTouchTool launches the helper,
Screen Sharing is no longer the active app, allowing the helper's synthesized
Globe key to reach MacWhisper instead of recursively launching itself.

On first use, macOS may ask whether Screen Sharing Dictation may control
BetterTouchTool. Allow that request. BetterTouchTool also needs its normal
Accessibility permission to issue the final paste shortcut.

### Optional: Force Click to switch Spaces on the remote Mac

Apple Screen Sharing forwards Control-Left Arrow and Control-Right Arrow to
the remote Mac, which makes them convenient shortcuts for moving between its
Spaces. BetterTouchTool's **Send Keyboard Shortcut** action may briefly
synthesize an Fn transition when sending these chords. If MacWhisper uses
Globe/Fn to activate dictation, that synthetic transition can unexpectedly
start recording.

For each Force Click trigger, use **Run AppleScript (Blocking)** instead:

```applescript
tell application "System Events" to key code 123 using control down
```

Use key code `124` for Control-Right Arrow. This preserves the remote shortcut
without passing through BetterTouchTool's keyboard-shortcut sender. The
machine-specific recovery script in
`scripts/configure-btt-remote-space-force-clicks.applescript` applies this to
two existing triggers; its trigger UUIDs must be changed for another BTT
installation.

## Use

1. Focus a text field on the remote Mac.
2. Press Globe/Fn.
3. Dictate normally.
4. Press Globe/Fn again to finish.
5. Wait for MacWhisper to transcribe and polish the text.

The toast disappears after the result has been placed into the remote field.
Press Escape or use the close button to cancel. A three-minute timeout prevents
an abandoned capture from remaining open forever.

## Diagnostics and privacy

Metadata-only logs are stored at:

```text
~/Library/Logs/Screen Sharing Dictation/bridge.log
```

The log includes timestamps, state changes, application bundle identifiers,
character counts, and errors. It deliberately does **not** record dictated
text.

The helper reads only MacWhisper's local database, keeps the finished text on
the clipboard, and uses Screen Sharing's existing shared-clipboard channel.
It contains no analytics, accounts, remote services, or embedded credentials.

## Troubleshooting

### Screen Sharing receives only `v`

Confirm **Edit → Use Shared Clipboard** is enabled in Screen Sharing. The helper
waits before issuing Command+V, but Screen Sharing still needs its clipboard
channel enabled.

### Capitalization or punctuation is missing

That indicates text is being simulated character-by-character instead of
pasted. Confirm BetterTouchTool launches this helper rather than using its
**Type Custom Text** action.

### The toast waits forever

MacWhisper may have changed its database schema, or the dictation may not have
completed successfully. Cancel with Escape, then inspect the metadata log.

### The app is reported as damaged or incomplete

Run `./scripts/build.sh` and launch the generated `.app` bundle. Do not launch
the standalone executable from `.build`.

## Limitations

- The integration depends on MacWhisper's undocumented local database schema.
- The Screen Sharing bundle identifier is based on current macOS releases.
- This is a focused proof of concept rather than a general dictation framework.
- Other remote-desktop clients may need different clipboard timing.

## License

MIT. This project is not affiliated with Apple, Good Snooze, MacWhisper,
Folivora, or BetterTouchTool.
