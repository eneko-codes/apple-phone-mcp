# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Every tool reads. None places, deletes or edits a call, and none writes to Contacts. Do not add one.

**Tests run against fakes** — in-memory doubles, and a call history database the suite invents in a temporary directory. Never the owner's real call history or address book, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that. Every number in a fixture is from the fictional `555-0100` to `555-0199` range that the North American numbering plan reserves for fiction (`+1 212 555 01xx`), or `example.com`.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question. Print counts and structure, never a row: a call history is who someone talked to and when.

**Read paths have a gentle route: `SystemCallStore` takes a `databasePath`,** so work on a copy of `CallHistory.storedata` together with its `-wal` and `-shm` files under a temporary directory you made yourself — never the live file — and delete it in the same session. Contacts has no copy equivalent; it lives in the system's own store, so reading it for a debugging run needs the ask above.

## What this is

A local MCP server (Swift 6, stdio transport) for the Phone app's call history. Reads come from `~/Library/Application Support/CallHistoryDB/CallHistory.storedata` (read-only, through the write-ahead log); names come from Contacts. No network, no credential, no cloud API.

## APIs

No Apple framework exposes the call history on macOS. Reads are the [SQLite C API](https://www.sqlite.org/c3ref/intro.html) against `CallHistory.storedata`, opened read-only through a [URI filename](https://www.sqlite.org/uri.html) and read through its [write-ahead log](https://www.sqlite.org/wal.html); POSIX `open(2)` plus `errno` is the only way to tell a Full Disk Access denial from a missing file. Names are [Contacts](https://developer.apple.com/documentation/contacts): `CNContactStore`, `CNContact.predicateForContacts(matchingName:)`, `CNContactFormatter`, consent key [`NSContactsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription).

What the database holds, verified on macOS 27 against a real store (counts and types only):

- `ZCALLRECORD`: one row per call. `ZDATE` is seconds since 2001-01-01 (REAL on most rows, INTEGER on a few). `ZORIGINATED` 1 = outgoing. `ZANSWERED` 1 = answered, but 0 on every outgoing call. `ZCALLTYPE` 1 = phone, 8 = FaceTime video, 16 = FaceTime audio, matching `ZSERVICE_PROVIDER` `com.apple.Telephony` / `com.apple.FaceTime`. `ZADDRESS` is plain text, not encrypted. `ZNAME` is almost always empty. `ZORIGINATINGDEVICENAME` is empty and there is no `ZDEVICE_ID`.
- `ZHANDLE` + `Z_2REMOTEPARTICIPANTHANDLES`: the participants of each call. The join table's column names embed Core Data entity numbers (2 = CallRecord, 4 = Handle).
- The database is in WAL mode and `callservicesd` writes it. Its `-wal` file can be larger than the main file.

## Surface not used

Before proposing a tool, check it against this list rather than assuming.

- [`INSearchCallHistoryIntent`](https://developer.apple.com/documentation/intents/insearchcallhistoryintent): `API_UNAVAILABLE(macos)` in the SDK header, deprecated on iOS with no replacement, and in any case a request Siri hands *to* an app, not a way to read the history.
- [CallKit](https://developer.apple.com/documentation/callkit): `CXCallObserver` is `API_UNAVAILABLE(macos)`, and it sees calls in progress, never the history.
- The Phone app has no scripting dictionary (`sdef /System/Applications/Phone.app` fails with -192).
- The Phone app's App Intents (`PhoneAppIntents.framework`, private): its `CallRecord` entity has a query, but the only read action is marked not discoverable and is Siri's own plumbing. Private, and free to change.
- Columns read by nothing: `ZREAD`, `ZFACE_TIME_DATA`, `ZJUNKCONFIDENCE`, `ZBLOCKEDBYEXTENSION`, `ZLOCATION` and the rest of the screening/emergency columns — undocumented and not verified.
- `immutable=1` while the file is in use, the online-backup API and copying the file: all three hide or snapshot around the write-ahead log. `immutable=1` is used only when no `-wal`/`-shm` pair exists, i.e. nothing has the database open.
- Every Contacts write API (`CNSaveRequest`), and ContactsUI.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-phone-mcp | grep NSContactsUsageDescription
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary holds any other architecture. Do not add an x86_64 slice back.

`CallStore` and `ContactResolver` are the two seams. `SystemCallStore` → `CallHistoryDatabase` is the only code that speaks SQL; `SystemContactResolver` is the only code that touches Contacts. Every tool call opens its own connection, verifies the schema and runs inside one read transaction.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
