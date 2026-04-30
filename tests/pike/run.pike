//! PUnit test runner for pmp.
//!
//! Delegates to PUnit.TestRunner. Defaults to scanning tests/pike/.

int main(int argc, array(string) argv) {
    // Parse CLI options with same flags as PUnit's run_tests.pike
    mapping options = ([]);
    array(string) tags = ({});
    array(string) exclude_tags = ({});

    array opts = Getopt.find_all_options(argv, ({
        ({"verbose",   Getopt.NO_ARG,  ({"-v", "--verbose"}),   "V", 0}),
        ({"stop",      Getopt.NO_ARG,  ({"-s", "--stop"}),      "S", 0}),
        ({"no_color",  Getopt.NO_ARG,  ({"--no-color"}),        "N", 0}),
        ({"tag",       Getopt.HAS_ARG, ({"-t", "--tag"}),       "T", 0}),
        ({"exclude",   Getopt.HAS_ARG, ({"-e", "--exclude"}),   "E", 0}),
        ({"filter",    Getopt.HAS_ARG, ({"-f", "--filter"}),    "F", 0}),
        ({"junit",     Getopt.HAS_ARG, ({"--junit"}),           "J", 0}),
        ({"tap",       Getopt.NO_ARG,  ({"--tap"}),             "A", 0}),
    }));

    foreach (opts; ; array opt) {
        switch (opt[0]) {
            case "verbose":   options->verbose = 1; break;
            case "stop":      options->stop_on_failure = 1; break;
            case "no_color":  options->no_color = 1; break;
            case "tag":       tags += ({ opt[1] }); break;
            case "exclude":   exclude_tags += ({ opt[1] }); break;
            case "filter":    options->filter = opt[1]; break;
            case "junit":     options->junit = opt[1]; break;
            case "tap":       options->tap = 1; break;
        }
    }

    options->tags = tags;
    options->exclude_tags = exclude_tags;

    array(string) paths = Getopt.get_args(argv)[1..];

    // Default: scan tests/pike/
    if (sizeof(paths) == 0)
        paths = ({ combine_path(getcwd(), "tests/pike") });

    object runner = PUnit.TestRunner(options);
    return runner->run(paths);
}
