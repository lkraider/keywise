//! The text a front end shows for a failure the core reports.

/// Every error in store.Error and store.RevealError, mapped to text a person
/// can act on. Internal parse errors ask for a bug report.
pub fn friendly(err: anyerror) []const u8 {
    return switch (err) {
        error.WrongPassword => "wrong Primary Password",
        error.LegacyTripleDes => "this entry is still 3DES and this app cannot decrypt it",
        error.OpenFailed => "could not open key4.db for this profile",
        error.WalJournal => "key4.db uses write-ahead logging. Open Firefox and close it to commit the log",
        error.KeyUnwrapFailed => "could not unwrap the key in key4.db; the Primary Password may be wrong, or the key data may be damaged",
        error.MissingPasswordRow, error.NoSdrKey, error.QueryFailed => "this profile's key4.db is missing data this app expects",
        error.NoLoginsArray => "logins.json is not in the shape this app expects",
        error.MalformedJson => "logins.json is not valid JSON",
        error.LoginsUnreadable => "could not read logins.json for this profile",
        error.OutOfMemory => "out of memory",
        error.AccessDenied => "permission denied reading this profile",
        error.UnsupportedScheme,
        error.UnsupportedPrf,
        error.UnsupportedCipher,
        error.BadIvLength,
        error.UnsupportedKeyLen,
        error.UnsupportedGlobalSaltLen,
        error.Truncated,
        error.UnsupportedLength,
        error.UnexpectedTag,
        error.IntegerTooLarge,
        error.BadCiphertextLength,
        error.BadPadding,
        error.BufferTooSmall,
        error.WeakParameters,
        error.InvalidCharacter,
        error.InvalidPadding,
        error.NoSpaceLeft,
        error.TooLarge,
        => "internal format error; please file a bug report",
        else => unexpected,
    };
}

pub const unexpected = "could not read this profile (unexpected error)";
