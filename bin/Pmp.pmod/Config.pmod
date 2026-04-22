constant PMP_VERSION = "0.4.0";

// Exit codes: distinguish user errors from internal failures for CI
constant EXIT_OK = 0;
constant EXIT_ERROR = 1;       // User error: invalid input, missing deps, usage
constant EXIT_INTERNAL = 2;    // Internal error: invariant violation, store corruption

// Verbosity: env vars or --verbose/--quiet flags
int PMP_VERBOSE = (int)(getenv("PMP_VERBOSE") || "0");
int PMP_QUIET = (int)(getenv("PMP_QUIET") || "0");

void set_verbose(int v) { PMP_VERBOSE = v; }
void set_quiet(int v) { PMP_QUIET = v; }