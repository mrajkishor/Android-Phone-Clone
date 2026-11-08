# Privacy Policy — Phone Clone

**Effective date:** 8 November 2026
**App:** Phone Clone (Android), package `com.mrajkishor.phoneclone`
**Developer:** [@mrajkishor](https://github.com/mrajkishor)

Phone Clone copies your data from your old Android phone to your new Android phone. This policy explains what the app accesses, where that data goes, and what it never does.

## The short version

- Your data goes **directly from your old phone to your new phone** over your own Wi-Fi network or your new phone's hotspot.
- There are **no servers, no cloud, no accounts, no ads and no analytics**. The developer never receives, sees or stores any of your data.
- Nothing on your old phone is changed or deleted. The app only reads it.

## What the app accesses, and why

| Data | Why | Where it goes |
|---|---|---|
| Photos and videos | To copy them to your new phone | Your new phone only |
| Music and audio files | To copy them to your new phone | Your new phone only |
| Documents and other files on your phone's storage | To copy them to your new phone, in the same folders | Your new phone only |
| Contacts (names, phone numbers, emails, addresses, notes, photos and other contact fields) | To copy them to your new phone, skipping ones already there | Your new phone only |
| Camera | Only to scan the pairing QR code shown on the new phone. No photos are taken or saved | Nowhere: the image is processed on the device and discarded |
| Local network information (your phone's local IP address) | So the two phones can find each other | Shown on the new phone's screen and QR code |

The app transfers only the categories **you** switch on, and only after **you** tap *Start transfer*.

## How the transfer works

- The new phone runs a small server that can only be reached from the same local network. The old phone connects to it using an address and a 6-digit pairing code shown on the new phone's screen.
- Files are checked with SHA-256 checksums so they arrive unchanged.
- **The connection is not encrypted.** Data travels as plain HTTP over your local network, protected by the pairing code. Use a network you trust, such as your home Wi-Fi or the new phone's own hotspot.

## What is stored, and where

- **On the new phone:** the files and contacts you transferred, plus a small record of which files were received. This record is used to skip files that are already there and to resume interrupted transfers. Partly received files are kept in a hidden folder (`.phonetransfer_tmp`) until the transfer completes.
- **On the old phone:** a small record of the last unfinished transfer (the new phone's local address, the pairing code and the categories you chose), so you can continue with one tap. It's deleted when a transfer completes.
- All of this stays on your phones. You can remove it at any time by clearing the app's storage or uninstalling the app.

## What the app never does

- It never sends your data to the developer or any third party.
- It never uploads anything to the internet.
- It contains no advertising, no analytics and no tracking.
- It never sells data.
- It never modifies or deletes anything on your old phone.

## Children

Phone Clone is a general-purpose utility and is not directed at children.

## Your choices

- You choose which categories to transfer, and you can stop or pause at any time.
- You can revoke permissions in Android *Settings → Apps → Phone Clone → Permissions*.
- To remove everything the app stored, uninstall it or clear its storage. Files you transferred stay on your new phone until you delete them, like any other files.

## Changes to this policy

If this policy changes, the new version will be published at this address with a new effective date.

## Contact

Questions or concerns: open an issue at <https://github.com/mrajkishor/Android-Phone-Clone/issues>.
