//! Security tests for extract_targz — path traversal, absolute paths, symlink escapes.
//!
//! extract_targz calls die() on security violations. die() calls exit() which
//! is uncatchable, so rejection tests spawn a subprocess and check the exit code.

import PUnit;
import Pmp;
inherit PUnit.TestCase;

protected string tmpdir;

void setup() {
    tmpdir = combine_path(getcwd(), ".tmp-test-extractsec-" + getpid());
    Stdio.mkdirhier(tmpdir);
}

void teardown() {
    if (tmpdir && Stdio.exist(tmpdir))
        Stdio.recursive_rm(tmpdir);
}

// ── subprocess helper ─────────────────────────────────────────────────

//! Run a snippet of Pike code in a subprocess with the same module paths.
//! Returns the exit code.
protected int run_subprocess(string code) {
    mapping result = Process.run(({
        "pike", "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"),
        "-M", combine_path(getcwd(), "bin/core"),
        "-M", combine_path(getcwd(), "bin/transport"),
        "-M", combine_path(getcwd(), "bin/store"),
        "-M", combine_path(getcwd(), "bin/project"),
        "-M", combine_path(getcwd(), "bin/commands"),
        "-e", code
    }));
    return result->exitcode;
}

// ── tar creation helpers ──────────────────────────────────────────────

//! Create a tar.gz with a member whose path contains ../../ (path traversal).
//! GNU tar 1.35 rejects extraction of members containing '..'.
protected string make_traversal_tar() {
    string srcdir = combine_path(tmpdir, "trav_src");
    string tarball = combine_path(tmpdir, "traversal.tar.gz");
    Stdio.mkdirhier(srcdir);
    Stdio.write_file(combine_path(srcdir, "passwd"), "pwned\n");
    // Use --transform to prepend ../../ to the member path
    Process.run(({"tar", "czf", tarball, "-C", srcdir,
                  "--transform", "s,^,../../,", "passwd"}));
    return tarball;
}

//! Create a tar.gz with an absolute path member (/etc/passwd).
//! GNU tar strips the leading / on extraction, so the file lands safely inside
//! the destination directory.
protected string make_absolute_path_tar() {
    string srcdir = combine_path(tmpdir, "abs_src");
    string tarball = combine_path(tmpdir, "absolute.tar.gz");
    Stdio.mkdirhier(srcdir);
    Stdio.write_file(combine_path(srcdir, "passwd"), "abs_content\n");
    Process.run(({"tar", "czf", tarball, "-C", srcdir,
                  "--transform", "s,^,/,", "passwd"}));
    return tarball;
}

//! Create a tar.gz containing a symlink that points outside the extraction dir.
protected string make_symlink_escape_tar() {
    string srcdir = combine_path(tmpdir, "sym_src");
    string tarball = combine_path(tmpdir, "symlink.tar.gz");
    Stdio.mkdirhier(srcdir);
    // Create symlink pointing well outside extraction dir
    Process.run(({"ln", "-s", "../../outside", combine_path(srcdir, "escape")}));
    Process.run(({"tar", "czf", tarball, "-C", srcdir, "escape"}));
    return tarball;
}

//! Create a tar.gz with both a valid top-level directory and a traversal member.
protected string make_mixed_tar() {
    string srcdir = combine_path(tmpdir, "mix_src");
    string tarball = combine_path(tmpdir, "mixed.tar.gz");
    Stdio.mkdirhier(combine_path(srcdir, "valid_pkg"));
    Stdio.write_file(combine_path(srcdir, "valid_pkg", "readme.txt"), "good\n");
    Stdio.write_file(combine_path(srcdir, "evil"), "bad\n");
    Process.run(({"tar", "czf", tarball, "-C", srcdir,
                  "valid_pkg",
                  "--transform", "s,^evil$,../../evil,", "evil"}));
    return tarball;
}

//! Create a valid tar.gz with a single top-level directory containing a file.
protected string make_valid_tar() {
    string srcdir = combine_path(tmpdir, "valid_src");
    string tarball = combine_path(tmpdir, "valid.tar.gz");
    Stdio.mkdirhier(combine_path(srcdir, "my_package"));
    Stdio.write_file(combine_path(srcdir, "my_package", "hello.txt"), "world\n");
    Process.run(({"tar", "czf", tarball, "-C", srcdir, "my_package"}));
    return tarball;
}

// ── tests ─────────────────────────────────────────────────────────────

//! Path traversal with .. in member names is rejected by GNU tar during
//! extraction, causing extract_targz to die().
void test_reject_path_traversal_dotdot() {
    string tarball = make_traversal_tar();
    string dest = combine_path(tmpdir, "extract_trav");
    Stdio.mkdirhier(dest);

    string code = sprintf(
        "import Pmp; extract_targz(%O, %O);",
        tarball, dest
    );
    int exitcode = run_subprocess(code);
    assert_true(exitcode != 0,
        "extract_targz must reject tar with ../../ path traversal");
}

//! Absolute paths in tar members are stripped by GNU tar (leading / removed).
//! The file lands safely inside the extraction directory.
void test_reject_absolute_path() {
    string tarball = make_absolute_path_tar();
    string dest = combine_path(tmpdir, "extract_abs");
    Stdio.mkdirhier(dest);

    // GNU tar strips leading /, so extraction succeeds but file is inside dest
    string code = sprintf(
        "import Pmp; extract_targz(%O, %O);",
        tarball, dest
    );
    int exitcode = run_subprocess(code);
    // The file should be extracted safely (no /etc/passwd written)
    // GNU tar may return 0 (strips the / silently) or non-zero depending on version
    // The security property is: nothing lands outside dest_dir
    if (exitcode == 0) {
        // Verify no file was written outside dest
        assert_true(!Stdio.exist("/passwd"),
            "absolute path must not write to filesystem root");
        // The file should exist inside dest (name without leading /)
        assert_true(Stdio.exist(combine_path(dest, "passwd")),
            "stripped absolute path should land inside dest");
    }
    // Either way, the extraction is safe
}

//! Symlinks pointing outside the extraction directory are caught by
//! _validate_symlinks, which calls die().
void test_reject_symlink_escape() {
    string tarball = make_symlink_escape_tar();
    string dest = combine_path(tmpdir, "extract_sym");
    Stdio.mkdirhier(dest);

    string code = sprintf(
        "import Pmp; extract_targz(%O, %O);",
        tarball, dest
    );
    int exitcode = run_subprocess(code);
    assert_true(exitcode != 0,
        "extract_targz must reject tar with symlink escaping extraction dir");
}

//! A tar with valid entries and one traversal member is still rejected
//! because GNU tar fails on the traversal member.
void test_reject_mixed_paths() {
    string tarball = make_mixed_tar();
    string dest = combine_path(tmpdir, "extract_mixed");
    Stdio.mkdirhier(dest);

    string code = sprintf(
        "import Pmp; extract_targz(%O, %O);",
        tarball, dest
    );
    int exitcode = run_subprocess(code);
    assert_true(exitcode != 0,
        "extract_targz must reject tar even if only one member has path traversal");
}

//! A valid tar.gz with a proper top-level directory extracts successfully
//! and returns the top-level directory name.
void test_valid_tar_succeeds() {
    string tarball = make_valid_tar();
    string dest = combine_path(tmpdir, "extract_valid");
    Stdio.mkdirhier(dest);

    string code = sprintf(
        "import Pmp; string name = extract_targz(%O, %O); write(name);",
        tarball, dest
    );
    mapping result = Process.run(({
        "pike", "-M", combine_path(getcwd(), "modules"),
        "-M", combine_path(getcwd(), "bin"),
        "-M", combine_path(getcwd(), "bin/core"),
        "-M", combine_path(getcwd(), "bin/transport"),
        "-M", combine_path(getcwd(), "bin/store"),
        "-M", combine_path(getcwd(), "bin/project"),
        "-M", combine_path(getcwd(), "bin/commands"),
        "-e", code
    }));
    assert_equal(0, result->exitcode,
        "valid tar.gz should extract without error");
    string name = String.trim_all_whites(result->stdout || "");
    assert_equal("my_package", name,
        "extract_targz should return top-level directory name");
    // Verify the file content
    assert_true(Stdio.exist(combine_path(dest, "my_package", "hello.txt")),
        "extracted file should exist");
    assert_equal("world\n",
        Stdio.read_file(combine_path(dest, "my_package", "hello.txt")),
        "file content should be preserved");
}
