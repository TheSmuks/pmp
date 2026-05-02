constant PMP_VERSION = "0.5.0";

// Exit codes: distinguish user errors from internal failures for CI
constant EXIT_OK = 0;
constant EXIT_ERROR = 1;       // User error: invalid input, missing deps, usage
constant EXIT_INTERNAL = 2;    // Internal error: invariant violation, store corruption

// Verbosity: env vars or --verbose/--quiet flags.
// Uses getenv/putenv so all modules share the same state
// (inherit .Config copies variables, breaking shared mutable state).
int _verbose() { return (int)(getenv("PMP_VERBOSE") || "0"); }
int _quiet() { return (int)(getenv("PMP_QUIET") || "0"); }
void set_verbose(int v) { putenv("PMP_VERBOSE", (string)v); }
void set_quiet(int v) { putenv("PMP_QUIET", (string)v); }
