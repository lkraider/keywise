# Firefox's on-disk format

What Firefox writes into a profile directory, and how its encryption layers
fit together. Mozilla owns every fact here, and a Firefox release can change
any of them. Read this before changing the decryption path.

The measurements come from a live Firefox 152.0.6 profile on macOS 15.7.7
arm64.

## Where Firefox stores the data

- `logins.json` — one record per saved login. The on-disk keys are `hostname`,
  `httpRealm`, `formSubmitURL`, `usernameField`, `passwordField`,
  `encryptedUsername`, `encryptedPassword`, `guid`, `encType`, `timeCreated`,
  `timeLastUsed`, `timePasswordChanged`, `timesUsed`, `encryptedUnknownFields`.
  There is no `origin` key. That name belongs to the JavaScript side.
- `key4.db` — SQLite. `metaData` holds the global salt and the password-check
  value under `id = 'password'`. `nssPrivate` holds the wrapped master keys.
- `cert9.db` — certificate store, unused here.

`metaData` also holds `sig_key_*` rows, so `keydb.zig` matches
`id = "password"`. `nssPrivate` also holds non-key objects, so the same
file filters on CKA_ID `f8000000000000000000000000000001` and object class
`a0 = 00 00 00 04`.

`nssPrivate` declares 192 columns in the `unmigrated` fixture and 193 in
every other one. The reader resolves column positions from the
`CREATE TABLE` text.

### Two master keys, one key id

A profile Firefox 144 has opened holds **two** rows under CKA_ID
`f8000000000000000000000000000001` with object class `CKO_SECRET_KEY`
(`a0 = x'00000004'`):

| wrapped size | decrypted size | key |
|---|---|---|
| 32 bytes | 24 bytes | legacy 3DES |
| 48 bytes | 32 bytes | AES-256, added by Firefox 144 |

Firefox 144 adds the AES-256 key and leaves the 3DES key in place.
`keydb.zig` unwraps both rows and picks by decrypted length. The 3DES row
comes first in insertion order, so a reader that stops at the first row
decrypts every AES entry with the legacy key and fails its PKCS7 check.

### Firefox 144 migrated the whole store at once

Read an entry's cipher from its OID. On the measured profile, 1625 of the
1701 entries predate October 2025 and the oldest dates to March 2011. All
1701 use AES-256, so the timestamps predict nothing. The 144 upgrade
re-encrypted every entry in one pass. The `unmigrated` and `migrated`
fixtures are the same profile before and after that pass.

### A Primary Password changes the global salt's size and the seed hash

A never-initialized token stores metaData's global salt as 20 raw bytes and
seeds its key derivation with SHA-1. Setting a Primary Password for the
first time replaces it with a 48-byte salt and reseeds with SHA-384.
`sftkdb_passwordToKey` in NSS's softoken picks the hash by the salt's
length, so the reader must do the same. Seeding with SHA-1 for a 48-byte
salt makes the correct password fail. That failure looks exactly like a
wrong password, so the `primary` fixture covers it.

### profiles.ini

Since Firefox 67 the `[InstallXXXX]` section names the profile for a given
installation. `Default=1` under `[ProfileN]` is the pre-67 fallback. On the
measured machine `Default=1` sits on a profile that contains no `key4.db`,
and the install section names the profile Firefox opens. Resolution reads
the install section first.

### Sync tombstones and the non-web schemes

A profile synced to a Mozilla Account uses the same encryption as any
other profile. It adds deletion tombstones and rows whose hostname carries
a non-web scheme.

A tombstone carries `{deleted: true, everSynced, guid, id, syncCounter,
timePasswordChanged}` and no hostname or encrypted field. These are
deletions held for propagation to other devices. `logins.zig` counts them
under `tombstones_skipped` and leaves them out of the entry list. The
`sync-shaped` fixture carries two.

One entry has `hostname = chrome://FirefoxAccounts` and
`httpRealm = Firefox Accounts credentials`. Its username is the Mozilla
Account email, and its decrypted password is a JSON document holding sync
key material. Revealing it hands over the whole Mozilla Account. The store
labels this row `account_credential`. Entries can also carry a
`moz-extension://` origin, labelled `extension`. Hostname parsing must not
assume `http` or `https`.

## The decryption chain

Both layers use PBKDF2 and AES-256-CBC. They differ in how the IV is carried.

**Unwrapping a key4.db value** (`metaData.item2` and each `nssPrivate.a11`):

```
seed = SHA1(globalSalt ‖ primaryPassword)     — SHA-384 if globalSalt is 48 bytes
key  = PBKDF2-HMAC-SHA256(seed, entrySalt, iterations, keyLength)
iv   = the full DER encoding of the IV element, header included
plain = AES-256-CBC-decrypt(ciphertext, key, iv), PKCS7 stripped
```

The IV element carries a 14-byte body. NSS feeds the two header octets plus
that body to AES as the 16-byte IV.

`iterations` was 1 on a never-initialized token and 10000 once a Primary
Password is set. The reader takes the value from the structure.

**Decrypting a logins.json field:** base64-decode, then parse
`SEQUENCE { OCTET keyId, SEQUENCE { OID cipher, OCTET iv }, OCTET ciphertext }`.
Here the IV is the element **body**, 16 bytes, used directly. Decrypt with
the 32-byte master key.

`metaData.item2` decrypts to the ASCII string `password-check`. This
confirms the Primary Password before any key material is unwrapped.

## Limits

- `oids.zig`'s `Cipher.fromOid` knows two OIDs, AES-256-CBC and legacy
  3DES. Firefox 152.0.6 writes no others. A profile using any other
  cipher stops at `error.UnsupportedCipher` from `sdr.parse`. Adding one
  means adding its OID and an implementation.
- `sqlitedb.zig` caps the b-tree walk at 24 stack frames and at the file's
  own page count. A crafted `key4.db` with a cyclic or fan-out b-tree hits
  one of these limits and returns `error.QueryFailed`.
  `core/testdata/fanout.db` exercises the page budget.
- Reading `key4.db` while Firefox has it open works. Verified against
  Firefox 152.0.6 running with its `.parentlock` held, decrypting the
  same 1701 entries as a closed-Firefox run, and no `key4.db-wal`
  appeared. A read landing mid-write with a WAL file present is
  untested. Reaching that state needs a write to a live profile.
  `sqlitedb.zig` reads the write version at header offset 18 and returns
  `error.WalJournal` for a value of 2. The message a person sees is
  "key4.db uses write-ahead logging. Open Firefox and close it to commit
  the log". Every committed `key4.db` reports 1.

## Prior art

- `firepwd.py` (lclevy) — pure Python, no NSS, updated October 2025 for
  the Firefox 144 change. Cross-check format questions against this one.
  The IV construction above came from it.
- `firefox_decrypt` (unode) — Python, calls into NSS. Run it on the same
  profile to compare this core's output against NSS itself.
