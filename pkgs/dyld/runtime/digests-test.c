// SPDX-License-Identifier: MIT
// Independent hashlib reference vectors: empty, abc, and 1000 bytes.
#include <corecrypto/ccdigest.h>
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static const char *expected[3][3] = {
  {"da39a3ee5e6b4b0d3255bfef95601890afd80709", "a9993e364706816aba3e25717850c26c9cd0d89d", "291e9a6c66994949b57ba5e650361e98fc36b1ba"},
  {"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"},
  {"38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b", "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "f54480689c6b0b11d0303285d9a81b21a93bca6ba5a1b4472765dca4da45ee328082d469c650cd3b61b16d3266ab8ced"},
};
int main(void) {
  const struct ccdigest_info *infos[] = {ccsha1_di(), ccsha256_di(), ccsha384_di()};
  char thousand[1000]; memset(thousand, 'a', sizeof(thousand));
  const char *messages[] = {"", "abc", thousand};
  const size_t lengths[] = {0, 3, sizeof(thousand)};
  for (size_t i = 0; i < 3; i++) for (size_t j = 0; j < 3; j++) {
    const struct ccdigest_info *di = infos[i];
    size_t size = ccdigest_di_size(di);
    unsigned char *allocation = malloc(size + 16), out[48];
    memset(allocation + size, 0xa5, 16);
    ccdigest_ctx_t ctx = (ccdigest_ctx_t)allocation;
    ccdigest_init(di, ctx);
    ccdigest_update(di, ctx, 0, "");
    for (size_t off = 0; off < lengths[j];) {
      size_t n = lengths[j] - off; if (n > 17) n = 17;
      ccdigest_update(di, ctx, n, messages[j] + off); off += n;
    }
    ccdigest_final(di, ctx, out);
    char hex[97]; const char *digits = "0123456789abcdef";
    for (size_t n = 0; n < di->output_size; n++) {
      hex[2*n] = digits[out[n] >> 4]; hex[2*n+1] = digits[out[n] & 15];
    }
    hex[2 * di->output_size] = 0;
    assert(strcmp(hex, expected[i][j]) == 0);
    ccdigest_di_clear(di, ctx);
    for (size_t n = 0; n < size; n++) assert(allocation[n] == 0);
    for (size_t n = 0; n < 16; n++) assert(allocation[size + n] == 0xa5);
    free(allocation);
  }
  return 0;
}
