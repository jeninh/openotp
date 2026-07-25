<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="OpenOTP icon">
</p>

<h1 align="center">OpenOTP</h1>

<p align="center">
  <b>Your email verification codes, autofilled on your Mac.</b><br>
  <sub>Works with Gmail and any IMAP provider — iCloud, Outlook, Fastmail, …</sub>
</p>

<p align="center">
  <a href="https://github.com/jeninh/OpenOTP/releases/latest">Download</a> ·
  <a href="#building-from-source">Build from source</a> <br>
  <sub>macOS 13+</sub>
</p>

<p align="center">
  <img src="docs/demo.gif" alt="OpenOTP demo" width="640">
</p>

## What it does

You paste email verification codes dozens of times a week. OpenOTP is like the way an iPhone surfaces SMS codes above the keyboard, but for the one-time passcodes that land in your email. It watches your inbox, and spots any incoming codes. It presents it to you in three formats:

- **Global shortcut** (default `⌃⌥V`, customizable) types the latest code into the focused field
- **Floating pill** next to the field you're filling
- **Menu-bar list** of recent codes, one click to copy, with a 12-hour history

Heads up: this is a simple personal project I built for myself and decided to share, not a polished product. It works well for me, but expect some issues :)

## Getting started

1. Grab the app from [Releases](https://github.com/jeninh/OpenOTP/releases/latest), or build from source below
2. Follow the setup wizard. Connect with an [app password](https://support.google.com/accounts/answer/185833) for your email account
3. When a code arrives, press `⌃⌥V`, click the pill, or copy it from the menu bar

Filling into other apps needs macOS's **Accessibility** permission — the same one Raycast uses. Copying from the menu needs no permission at all.

## Private by design

There is no OpenOTP server, so nothing about your email ever touches one. Mail is read directly from your Mac, read-only, using credentials you provide. Detected codes are held in memory only with a short TTL. It's never written to disk, and never logged. Credentials live in the macOS Keychain.

Detection is also deliberately conservative. OpenOTP only shows you something when it's certain it found a code.

### Hidden from screen capture

If you're on a call, streaming, or recording your screen, a code on screen is a way into your accounts. OpenOTP guards against this, **on by default**, toggleable under Preferences → "Hide codes from screen recording":

- The **floating pill** (where you read the code) is excluded from all screen capture. It stays fully visible to you, but it's blank in screen recordings, screenshots (`⌘⇧5`/`⌘⇧4`), and shares over Zoom, Slack, etc.
- The **menu bar list** is drawn by macOS and can't be excluded from capture, so it simply omits the digits — the menu shows "Copy code · sender" (clicking still copies).

One limit: when you actually *fill* a code, it lands in a real text field on screen, which is capturable like anything else you type — that's true of any autofill. The protection covers OpenOTP's own surfaces.

## Building from source

```sh
git clone https://github.com/jeninh/OpenOTP
cd OpenOTP
Scripts/bundle.sh release      # builds + packages build/OpenOTP.app
open build/OpenOTP.app
```

## Extras

### Use the detection engine in your own project

The detector ships as `OpenOTPCore`, a SwiftPM target with no AppKit dependency:

```swift
import OpenOTPCore

let email = EmailMessage(
    id: "1", account: "me@example.com",
    sender: "GitHub <noreply@github.com>",
    subject: "Your verification code",
    body: "Your code is 123456. It expires in 10 minutes.",
    isHTML: false, receivedAt: Date()
)

if let detected = OTPv2.extract(from: email) {
    print(detected.code)        // "123456"
    print(detected.confidence)  // 0.0...1.0
}
```

The pipeline:
- Render map - It parses the HTML into a render map (which characters belong to which block or cell?)
- Tokenizer - It splits it into tokens but then only accepts complete ones with boundaries. This prevents a fragment of an IPv6 address like 1234:a1b2:... because the token is the whole address or nothing. This removed a false-positive I had with some emails with an IP address getting flagged.
- Claiming - before anything gets flagged, seven "claimers" walk the tokens and claim everything that's part of something else. This includes URLs, IP/MAC addresses, dates, currency, phone numbers, etc. A claimer needs actual proof (currency symbol, date separators, etc.) before it can claim it. All claimed tokens are off the table.
- Structural / lexical / shape scoring - Whatever survives gets scored on three channels. Structural (does it sit like a real code in the email?), lexical (is it bound to any language like "your verification code is..."), and shape (does it look like a code? does it have 6 digits, 8 alphanumeric characters, etc.)
- Final decision - The channels combine. A candidate needs structural evidence, plus either lexical backing or overwhelming evidence structure-wise. A great shape score alone will never flag an OTP. If nothing clears the bar, the system returns nothing. That's why it runs conservatively. A missed code costs you a trip to your email client, but a wrong code auto-filled into a login field costs trust. So when in doubt, it stays silent.

## Credits

Icons by [Hack Club](https://icons.hackclub.com)

## License

[MIT](LICENSE) © jeninh
