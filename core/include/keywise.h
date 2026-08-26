/* C ABI for the Firefox password viewer core.
 *
 * One keywise_store belongs to one thread. Two threads calling into the same
 * store race.
 */
#ifndef KEYWISE_H
#define KEYWISE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct keywise_store keywise_store;

typedef enum {
  KEYWISE_OK = 0,
  KEYWISE_ERR_NO_PROFILE,
  KEYWISE_ERR_OPEN,
  KEYWISE_ERR_NEEDS_PASSWORD,
  KEYWISE_ERR_WRONG_PASSWORD,
  KEYWISE_ERR_LEGACY_3DES,
  KEYWISE_ERR_OOM,
  KEYWISE_ERR_IO,
  KEYWISE_ERR_RANGE
} keywise_status;

enum {
  KEYWISE_FLAG_ACCOUNT_CREDENTIAL = 1u << 0, /* chrome://FirefoxAccounts */
  KEYWISE_FLAG_EXTENSION          = 1u << 1, /* moz-extension:// origin  */
  /* Remaining bits are reserved. Setting one later does not move a field. */
};

typedef struct {
  const char *hostname; size_t hostname_len;
  const char *username; size_t username_len;
  int64_t  time_password_changed;
  uint32_t flags;
} keywise_entry;

/* Pass buf=NULL to learn the size through *needed. */
size_t      keywise_profile_count(void);
keywise_status keywise_profile_at(uint32_t i, char *buf, size_t cap, size_t *needed);

/* Opens profile_path and tries an empty Primary Password immediately, since
 * most profiles carry none. On KEYWISE_OK *out is ready to use.
 * KEYWISE_ERR_NEEDS_PASSWORD means the profile has a Primary Password. *out is
 * a valid handle then too. keywise_unlock must succeed on it before
 * keywise_count, keywise_search, keywise_entry_at or keywise_reveal. Every handle
 * written to *out is released with keywise_close. Other failures set *out to
 * NULL. */
keywise_status keywise_open(const char *profile_path, keywise_store **out);
keywise_status keywise_unlock(keywise_store *, const char *pw, size_t pw_len);
void        keywise_close(keywise_store *);

size_t      keywise_count(keywise_store *);
/* Writes at most cap indices. Returns the total match count. That total
   may exceed cap. */
size_t      keywise_search(keywise_store *, const char *q, size_t q_len,
                        uint32_t *out, size_t cap);
keywise_status keywise_entry_at(keywise_store *, uint32_t i, keywise_entry *out);
/* Writes at most cap entries, in index order starting at 0. Returns the
 * total entry count. That total may exceed cap. keywise_open and keywise_unlock
 * decrypt every hostname and username before they return, so this call
 * costs one struct copy per entry. Calling keywise_entry_at per row costs one
 * FFI call per row. */
size_t      keywise_entries(keywise_store *, keywise_entry *out, size_t cap);

/* On failure, sets *out to NULL and *len to 0 when those pointers are valid. */
keywise_status keywise_reveal(keywise_store *, uint32_t i, char **out, size_t *len);
/* Zeroes the buffer, then frees it with the store's allocator. A
 * keywise_reveal buffer is released here and nowhere else. */
void        keywise_secret_free(keywise_store *, char *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* KEYWISE_H */
