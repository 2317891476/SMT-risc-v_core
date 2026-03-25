# Issues

- The first `python verification/run_all_tests.py --basic --tests test1.s test2.S test_rv32i_full.s` run crashed in `print_summary()` with `UnicodeEncodeError: 'gbk' codec can't encode character '\u2713'`; fixing the summary output to ASCII PASS/FAIL text resolved the task-1 gate failure without changing the `Total:` marker format.
- The first `python verification/run_riscv_tests.py --suite riscv-arch-test` attempt hit `Download failed: IncompleteRead(0 bytes read)` from GitHub; a direct retry succeeded and produced `Total: 47/47 passed`, so this was an external fetch transient rather than an RTL/testbench regression.
