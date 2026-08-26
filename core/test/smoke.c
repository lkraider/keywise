/* Links libkeywise.a and exercises every function in keywise.h once. Prints
 * lengths and counts only, never a hostname, a username or a password, so
 * this is safe to run against a real profile as well as a fixture.
 *
 * Run under `leaks --atExit --` to confirm keywise_close and keywise_secret_free
 * release everything they allocate.
 */

#include <keywise.h>

#include <stdio.h>
#include <string.h>

static int fail(const char *what, keywise_status status) {
  fprintf(stderr, "FAIL: %s (status %d)\n", what, (int)status);
  return 1;
}

int main(int argc, char **argv) {
  const char *profile_path = argc > 1 ? argv[1] : "core/testdata/fresh";

  size_t profile_count = keywise_profile_count();
  printf("profiles: %zu\n", profile_count);
  for (uint32_t i = 0; i < profile_count && i < 8; i++) {
    size_t needed = 0;
    keywise_status st = keywise_profile_at(i, NULL, 0, &needed);
    if (st != KEYWISE_OK) return fail("keywise_profile_at (size probe)", st);
    printf("  profile %u path length: %zu\n", i, needed);
  }

  keywise_store *store = (keywise_store *)profile_path;
  keywise_status st = keywise_open(NULL, &store);
  if (st != KEYWISE_ERR_NO_PROFILE || store != NULL) {
    fprintf(stderr, "FAIL: failed keywise_open did not clear its output\n");
    return 1;
  }
  st = keywise_open(profile_path, &store);
  if (st != KEYWISE_OK && st != KEYWISE_ERR_NEEDS_PASSWORD) {
    return fail("keywise_open", st);
  }
  if (!store) {
    fprintf(stderr, "FAIL: keywise_open returned no store\n");
    return 1;
  }

  if (st == KEYWISE_ERR_NEEDS_PASSWORD) {
    /* The fresh fixture needs no password; the primary fixture would. */
    st = keywise_unlock(store, "", 0);
    if (st != KEYWISE_OK) {
      fprintf(stderr, "note: profile needs a real Primary Password (status %d)\n", (int)st);
      keywise_close(store);
      return 0;
    }
  }

  size_t count = keywise_count(store);
  printf("entries: %zu\n", count);

  uint32_t matches[16];
  size_t total = keywise_search(store, "", 0, matches, 16);
  printf("empty query matches: %zu\n", total);

  size_t narrow = keywise_search(store, "example", strlen("example"), matches, 16);
  printf("'example' matches: %zu\n", narrow);

  if (count > 0) {
    keywise_entry entry;
    st = keywise_entry_at(store, 0, &entry);
    if (st != KEYWISE_OK) return fail("keywise_entry_at", st);
    printf("entry 0: hostname_len=%zu username_len=%zu flags=%u\n",
           entry.hostname_len, entry.username_len, entry.flags);

    keywise_entry all[16];
    size_t all_total = keywise_entries(store, all, 16);
    printf("keywise_entries: %zu total, entry 0 hostname_len=%zu\n",
           all_total, all[0].hostname_len);
    if (all[0].hostname_len != entry.hostname_len) {
      fprintf(stderr, "FAIL: keywise_entries disagrees with keywise_entry_at\n");
      return 1;
    }

    char *secret = (char *)profile_path;
    size_t secret_len = 1;
    st = keywise_reveal(store, UINT32_MAX, &secret, &secret_len);
    if (st != KEYWISE_ERR_RANGE || secret != NULL || secret_len != 0) {
      fprintf(stderr, "FAIL: failed keywise_reveal did not clear its outputs\n");
      return 1;
    }
    st = keywise_reveal(store, 0, &secret, &secret_len);
    if (st == KEYWISE_OK) {
      printf("revealed length: %zu\n", secret_len);
      keywise_secret_free(store, secret, secret_len);
    } else if (st == KEYWISE_ERR_LEGACY_3DES) {
      printf("entry 0 is legacy 3DES, correctly not revealed\n");
    } else {
      return fail("keywise_reveal", st);
    }
  }

  keywise_close(store);
  printf("ok\n");
  return 0;
}
