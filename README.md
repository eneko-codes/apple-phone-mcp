<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-phone-mcp icon">
</p>

# apple-phone-mcp

A local MCP server, written in Swift, that gives Claude read-only access to the call
history of the Phone app on this Mac, with names from Contacts. It ships as a Claude
extension.

The Phone app has no framework, no scripting dictionary and no public intent that lists
past calls, so this server reads the database the system keeps them in,
`~/Library/Application Support/CallHistoryDB/CallHistory.storedata`. That is the history
shared with the iPhone signed in to the same Apple Account, not only calls taken on the
Mac. It costs the broadest permission on the Mac, Full Disk Access.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `phone_status` | read | Reports whether the call history and Contacts can be read, how many calls the history holds and the span they cover, and the exact path of the binary to add to Full Disk Access. Lists no calls. |
| `calls_list` | read | Calls newest first: date, direction, kind, duration, number and contact name. One page at a time (`limit`, `offset`); filters by `from_date` and `to_date` (both inclusive), direction, kind, number or contact. |
| `call_get` | read | Every field the history keeps for one call, with the participants of a group call a page at a time (`limit`, `offset`). |

## Frameworks and APIs

| Used | For | Reference |
|---|---|---|
| SQLite C API — `sqlite3_open_v2` with `SQLITE_OPEN_READONLY`, prepared statements, `PRAGMA table_info`, `PRAGMA query_only` | Every read of the call history, over `file:…?mode=ro`, inside one read transaction | [SQLite C API](https://www.sqlite.org/c3ref/intro.html), [URI filenames](https://www.sqlite.org/uri.html), [Write-ahead logging](https://www.sqlite.org/wal.html) |
| POSIX `open(2)` + `errno` | Telling a Full Disk Access denial (`EPERM`) apart from a missing file (`ENOENT`) — macOS offers no API for this | — |
| Contacts — `CNContactStore` (`authorizationStatus(for:)`, `requestAccess(for:)`, `enumerateContacts(with:)`, `unifiedContacts(matching:keysToFetch:)`), `CNContact.predicateForContacts(matchingName:)`, `CNContactFormatter` | Names beside numbers, and the `contact` filter | [Contacts](https://developer.apple.com/documentation/contacts), [CNContactStore](https://developer.apple.com/documentation/contacts/cncontactstore), [CNContactFormatter](https://developer.apple.com/documentation/contacts/cncontactformatter), [predicateForContacts(matchingName:)](https://developer.apple.com/documentation/contacts/cncontact/predicateforcontacts(matchingname:)) |
| `NSContactsUsageDescription` in an embedded Info.plist | The Contacts consent dialog | [NSContactsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription) |

## The rules worth knowing before you use it

**Results are bounded, and a result says what it leaves out.** `calls_list` returns one page
of calls, newest first, and `call_get` one page of a call's participants; the first lines
of a page that is not the whole say how many exist and the `offset` of the next one. A
`limit` or `offset` outside its range is moved to the nearest allowed value and the result
says which was used. A call id outside its range, a value of the wrong type, a date that
does not exist and an argument a tool does not list are refused. `to_date` is inclusive at
the precision written, so a day covers that whole day. The other parties of a group call
are clipped in a listing row, and `call_get` reads them all. A call that has not finished
after 30 seconds is abandoned and answered with an error that says so. The figures are
constants in `ToolCatalog`, and the schemas, descriptions and instructions quote them.

**The database is opened `mode=ro`, and deliberately not `immutable=1`.** The system keeps
the call history in WAL mode and checkpoints rarely, so the newest calls often live only
in the `-wal` file. An immutable reader never looks at that file and would miss exactly
the recent calls. A read-only reader takes a shared lock for the length of one short
transaction; in WAL mode that never blocks the system's own writes, and a read-only
connection cannot checkpoint. SQLite does record the reader in the `-shm` index, so that
file's bytes and modification time change when this server reads — it is a coordination
file, never call data. `PRAGMA query_only` is set on every connection as a second refusal
to write.

The one exception is a database nobody has open: SQLite deletes the `-wal` and `-shm`
files when its last connection closes, and a `mode=ro` connection could not open the file
without them in testing. With nothing running there is nothing to read from the log and
nothing that can change the file — exactly what `immutable=1` promises, and one of the
three documented ways to open a WAL database read-only. That case, and only that case,
uses `immutable=1`.

**Two fields are inferred, not stored.** The database has no direction column: `ZORIGINATED`
says who placed the call and `ZANSWERED` whether it was picked up. "Missed" is incoming and
not answered — a declined call and one that rang out look the same. `ZANSWERED` is 0 on
every outgoing call whether or not the other side answered, so this server never reports
an answer state for an outgoing call.

**Numbers compare on their last nine digits.** The history stores a number however the
network delivered it, and Contacts however it was typed, so `+1 212 555 0101` and
`2125550101` are the same number here. Two numbers from different countries sharing their
last nine digits would also compare equal; numbers under seven digits compare whole.

**Dates are seconds since 2001-01-01**, Core Data's reference date.

**Names are a courtesy.** Contacts asks for its own permission the first time calls are
listed. With it denied every tool still works, showing numbers alone; only the `contact`
filter refuses.

**There is no record of which device took a call.** The column meant for it is empty, and
no other column says.

**Nothing here modifies anything.** No tool places, deletes or edits a call, and none
writes to Contacts.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
```

```bash
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours.

That builds an arm64 (Apple silicon only) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-phone-mcp.mcpb`. Without an identity it signs ad-hoc, which works but
re-prompts for permission on every rebuild.

### 2. Install it

Open `dist/apple-phone-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — installing does not replace a server process that is already running.

### 3. Grant the permissions

**Full Disk Access, for the call history.** This has no Info.plist key and no dialog — a
server cannot ask for it. Call `phone_status`; if the database is unreadable it names the
fix: System Settings → Privacy & Security → Full Disk Access, and the exact binary to add,
which lives at

```
~/Library/Application Support/Claude/Claude Extensions/local.mcpb.eneko-codes.apple-phone-mcp/server/apple-phone-mcp
```

**Contacts, for names.** macOS asks the first time `calls_list` or `call_get` runs. The
grant then lives under System Settings → Privacy & Security → Contacts.

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`, so the
child cannot inherit Claude.app's own permissions — Full Disk Access granted to Claude.app
does not reach this server. To check the Contacts key is embedded:

```bash
otool -P extension/server/apple-phone-mcp | grep NSContactsUsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. A linker-signed binary never gets a consent dialog at all.

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate, which survives rebuilds. `pack.sh` prints the requirement on every
build, so a silent regression to ad-hoc is visible immediately.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="<Developer ID Application hash>" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires.

## Tool switches

Plug and play: there is nothing to configure. Every tool can be turned on and off
individually in Claude Desktop, because the bundle declares all three in its manifest.
**Reinstalling may reset the switches**; check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Phone": {
      "command": "/absolute/path/to/apple-phone-mcp/.build/release/apple-phone-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide, and `phone_status` prints the binary path precisely so you can tell
which one answered.

## Known limits

- **The history reaches back only as far as the system keeps it.** `phone_status` reports
  the oldest call; nothing older exists on this Mac.
- **The schema is Apple's private Core Data model.** It is checked with `PRAGMA table_info`
  on every call; a missing load-bearing column fails with a message naming it rather than
  answering with an empty history. The join table's column names embed Core Data entity
  numbers, which a model change would renumber.
- **Disconnect causes are shown as raw numbers.** Their meaning is not documented.
- **Full Disk Access cannot be requested from here.** There is no dialog and no Info.plist
  key for it; the only honest thing a server can do is detect the failure and name the fix.

## Development

```bash
swift build
swift test
```

The suite runs against in-memory doubles and against a database it invents in a temporary
directory with the same tables and columns as the real one — including rows left only in
the write-ahead log. No test opens the real call history or the real address book. See
`CLAUDE.md`.

## Licence

MIT.
