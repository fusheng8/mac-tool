# Archive compatibility fixtures

- `rar5-basic.rar` and `rar5-encrypted.rar` were generated with RAR 7.11 from
  the small JSONL payload used by `ArchiveActionExecutorTests`.
- `rar-legacy-v2.rar` is decoded from libarchive 3.8.7's
  `libarchive/test/test_read_format_rar.rar.uu` fixture and retains its upstream
  test-data license provenance: https://github.com/libarchive/libarchive

The ZIP encoding, AES ZIP, TAR and 7Z fixtures are generated deterministically
inside the tests to keep the repository fixture set small.
