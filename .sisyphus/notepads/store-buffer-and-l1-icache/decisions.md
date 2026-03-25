# Decisions

- Reused `comp_test/module_list_v2` as the V2 compile source of truth and updated the Python regression entrypoints to parse that manifest, because it preserves the existing curated module order/set and avoids widening task 1 into a full `rtl/*.v` compile-policy change.
- Kept success/failure reporting machine-parseable by retaining ASCII `PASS`/`FAIL` results and the existing `Total:` summary lines; removed decorative Unicode status glyphs from `run_all_tests.py` because they broke the acceptance command under the current Windows GBK shell.
