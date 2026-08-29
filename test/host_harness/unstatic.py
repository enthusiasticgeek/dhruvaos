#!/usr/bin/env python3
"""Strips `static ` off a whitelisted set of vani-generated C functions
so host_main.c (a separate translation unit) can call them directly.

vanic's --backend=c output makes every vani-defined top-level function
`static` (internal linkage) -- correct for a real build, where
everything links into one object anyway, but it means a SEPARATE host
test driver can't call fn_dharafs_append_raw etc. via a normal extern
declaration. Rather than #include the entire ~9500-line generated file
into host_main.c (which would also drag in its own trailing `int
main()`), this does a narrow, mechanical patch: for each name in
WHITELIST, drop the leading `static ` from every line starting with
`static <TYPE> fn_<name>(` -- both the forward declaration and the
definition share that exact shape, so one regex pass gets both. Also
removes the generated file's own `int main(void) { return
(int)fn_main(); }` trailing wrapper, since host_main.c supplies its
own main() and this harness never invokes the real kernel entry point
(fn_main starts networking/scheduling this harness has no interest in
exercising).

This is a deliberately minimal patch -- anything not in WHITELIST
stays static and simply isn't callable from host_main.c, which is
correct: those functions' own logic still runs (compiled into the
final object) but the harness has no test coverage for them yet.
"""
import re
import sys

WHITELIST = [
    "dharafs_check_permission",
    "dharafs_init",
    "dharafs_append_raw",
    "dharafs_append",
    "dharafs_read_raw_checked",
    "dharafs_write_raw_checked",
    "dharafs_delete_raw_checked",
    "dharafs_find_latest_block_raw",
    "dharafs_compact",
    "dharafs_stat_raw",
    "dharafs_stat",
    "dharafs_read_raw",
    "dharafs_read",
    "dharafs_delete_raw",
    "dharafs_delete",
    "dharafs_dirlist_seen_contains",
    "dharafs_dirlist_segment_equals",
    "dharafs_list_dir_raw",
    "dharafs_block_payload_cap",
    "dharafs_file_max_len",
    "dharafs_default_mode",
    "sha256_hash",
    "sha256_bytes_equal",
    "chacha20_encrypt",
    "chacha20_bytes_equal",
    "bignum_add_raw",
    "bignum_sub_raw",
    "bignum_mul_raw",
    "bignum_cmp_raw",
    "bignum_limbs_equal",
    "bignum_set_limbs4",
]


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <in.c> <out.c>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "r") as f:
        src = f.read()

    name_alt = "|".join(re.escape(n) for n in WHITELIST)
    pattern = re.compile(r"^static (?=\w[\w\s\*]*\bfn_(?:" + name_alt + r")\()", re.MULTILINE)
    patched, count = pattern.subn("", src)

    main_pattern = re.compile(r"\nint main\(void\) \{\n  return \(int\)fn_main\(\);\n\}\n")
    patched, main_count = main_pattern.subn("\n", patched)
    if main_count != 1:
        print(f"warning: expected exactly one trailing main() wrapper, found {main_count}", file=sys.stderr)

    with open(sys.argv[2], "w") as f:
        f.write(patched)

    print(f"unstatic'd {count} declarations/definitions across {len(WHITELIST)} whitelisted functions", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
