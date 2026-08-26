# Fixtures

Each profile fixture holds files copied out of a profile written by an
installed Firefox. `scripts/test-mkfixtures.py` drives Firefox over Marionette
to create the populated fixtures. Every credential is synthetic. `no-logins`
intentionally has no `logins.json`, matching a new profile before its first
saved login.

Firefox writes these files, so a test against them checks this reader
against Firefox's own output. A generator built from this project's own
reading of the format would only show the reader agrees with itself.

| Fixture | Documented password | Firefox version | Covers |
|---|---|---|---|
| `fresh` | none (empty Primary Password) | 152.0.6 | one AES-256 key row, 3 logins |
| `no-logins` | none (empty Primary Password) | 154.0.1 | a current, newly created profile where Firefox has not written `logins.json` yet |
| `primary` | `fixture-primary-password-1` | 152.0.6 | a Primary Password set by the user: a 48-byte SHA384 global salt, rejection of the empty and the wrong password |
| `two-profiles` | none | 152.0.6 | `profiles.ini` install-section precedence over the legacy `Default=1` flag |
| `sync-shaped` | none (empty Primary Password) | 152.0.6 | a `chrome://FirefoxAccounts` row, a `moz-extension://` row, and 2 sync deletion tombstones |
| `unmigrated` | none | 143.0.4 | a 24-byte 3DES key, no AES-256 key, and 3 `des_ede3_cbc` entries |
| `migrated` | none | `unmigrated`'s profile, opened once by 152.0.6 | both key rows under one CKA_ID, and every entry re-encrypted to AES-256 |

Firefox writes every fixture above. `scripts/test-mkfixtures.py overflow` writes
`overflow.db` through Python's own `sqlite3`. It is a bare SQLite database
and it stands outside any profile directory. Its page size is 512 bytes. Its
rows therefore spill onto overflow pages, and its table b-tree grows 6
interior pages. Every `key4.db` here has a 32768-byte page and rows of about
400 bytes, and each of its tables fits on one leaf page. Each row of
`overflow.db` holds content derived from its row number, so two runs of the
generator write the same bytes. `core/test/oracle.zig` reads the file through
`core/src/sqlitedb.zig` and through the system sqlite3, then compares every
column.

`scripts/test-mkfixtures.py fanout` writes `fanout.db`. Python assembles
those 23 pages byte by byte, since sqlite3 refuses to write a b-tree that
reaches one page twice. The file declares a `metaData` table with columns
`id,item1,item2`, so `keydb.load` on it reaches the b-tree walk. Every
interior page names the next page 72 times, once per cell and once as the
rightmost child, and the walk therefore reaches 72<sup>21</sup> leaves. The
page budget in `RowIterator.push` stops it after 23 pushes and returns
`error.Corrupt`. sqlite3 reports `database disk image is malformed` for this
file, so `core/test/oracle.zig` leaves it out of its fixture list.

`scripts/test-mkfixtures.py page64k` writes `page64k.db` through Python's own
`sqlite3` with `PRAGMA page_size = 65536`. Header offset 16 is two bytes wide,
so SQLite stores that size as the value 1 and `sqlitedb.Db.open` maps it back.
Every `key4.db` uses 32768 bytes, so a fixture Firefox writes reaches that
value through neither field. The file holds one row per arm of the local-size
choice. A 70005-byte record makes `k` run past `max_local`, so `local` falls
back to `min_local`. A 75005-byte record makes `local` take `k`. Each row
spills onto one overflow page. `core/test/oracle.zig` reads it, so
`row_buf_len` there holds 128 KB.

`scripts/test-mkfixtures.py reserved` writes `reserved.db`. Python assembles
its 3 pages byte by byte. Header offset 20 reserves a tail on every page for an
extension such as SEE, and the payload arithmetic in `readPayload` counts
`page_size` minus that tail. Firefox loads no extension, so every `key4.db`
stores 0 there, and 0 makes `usable` and `page_size` equal. This file reserves
16 bytes of each 512-byte page, so `usable` is 496. Its one record totals 600
bytes. 108 of them sit in the cell and 492 on one overflow page. A reader that counts
`page_size` takes 92 local bytes and returns other content. The record's blob
holds `(position * 7) % 251`, so `core/src/tests.zig` asserts every byte, and
the system sqlite3 reads the file, so `core/test/oracle.zig` covers it too.

`scripts/test-mkfixtures.py random` writes `random.db` through Python's own
`sqlite3`. A fixed seed controls every choice, so two runs write the same bytes.
Five tables carry random column counts and type affinities. Each table starts
with 30 rows, gains a column through `ALTER TABLE ADD COLUMN`, then gains 10
more rows. The first 30 rows have records that stop before the added column.
Values span nulls, zero-length blobs, integers at the serial-type boundaries,
floats, text, and blobs up to 200 bytes. `core/test/oracle.zig` diffs the record
decoder against the system sqlite3 over these column shapes.

`scripts/test-mkfixtures.py synthetic` writes two fixtures through Python's
`sqlite3`. Both carry the `metaData` schema and the password-check row
copied verbatim from `core/testdata/fresh/key4.db`, so no test needs an
encryptor. The empty Primary Password passes the password check.

| Fixture | What it omits | Expected error |
|---|---|---|
| `no-password-row/key4.db` | the `id = 'password'` row in `metaData` | `MissingPasswordRow` |
| `no-key-row/key4.db` | every row in `nssPrivate` | `NoSdrKey` |

`core/test/oracle.zig` reads both files, so the record decoder is diffed
against the system sqlite3 there too.

Some fixtures have hand-written parts. Every such edit stays outside the
encrypted bytes, so the crypto in each fixture is still Firefox's own
output.

`two-profiles/profiles.ini` is hand-written, since `profiles.ini` is
plain text and carries no encrypted field.
`Profiles/real.default-release` is a copy of the `fresh` fixture's
`key4.db` and `logins.json`. `Profiles/abandoned.default` is empty. It
stands in for a profile that the legacy `Default=1` flag points at and
Firefox no longer uses.

`sync-shaped`'s tombstones are appended to `logins.json` as plain JSON
text after Firefox quits. A tombstone carries no encrypted field. Getting
Firefox to write them needs a sign-in to a Mozilla Account, and no
account is used to build these fixtures.

`unmigrated` needs Firefox 143.0.4, from
`ftp.mozilla.org/pub/firefox/releases/143.0.4/mac/en-US/`, since Firefox 144
adds the AES-256 key. `migrated` is `unmigrated`'s profile directory,
copied and then opened once by the installed Firefox 152 with
`test-mkfixtures.py --profile <copy> migrate`. Nothing is added to it.

Regenerate a fixture with, for example:

```
python3 scripts/test-mkfixtures.py --profile /tmp/scratch fresh
cp /tmp/scratch/key4.db /tmp/scratch/logins.json core/testdata/fresh/
```

Regenerate the bare databases in place with:

```
python3 scripts/test-mkfixtures.py overflow
python3 scripts/test-mkfixtures.py fanout
python3 scripts/test-mkfixtures.py page64k
python3 scripts/test-mkfixtures.py reserved
python3 scripts/test-mkfixtures.py random
```

`core/src/tests.zig` asserts each fixture's password-check decrypts under its
documented password. Your own Firefox profile dropped in here fails that
assertion, since the documented password does not unlock it. The failure
stops your credentials from reaching a test run.
