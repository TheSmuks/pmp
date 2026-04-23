//! Semver.pmod — semantic version parsing, comparison, and classification.
//! Follows Semantic Versioning 2.0.0 (https://semver.org/).
//!
//! Only tags matching MAJOR.MINOR.PATCH (with optional 'v' prefix and
//! -prerelease suffix) are sorted correctly. Non-semver tags are treated
//! as version 0.0.0 and sort last.

//! Parse a version string into a mapping.
//! Handles: "1.2.3", "v1.2.3", "1.2.3-alpha", "1.2.3-alpha.1", "1.2.3-alpha.1+build"
//! Returns 0 if not parseable as semver.
mapping parse_semver(string tag) {
    if (!tag || sizeof(tag) == 0) return 0;

    string v = tag;

    // Strip leading 'v' or 'V'
    if (sizeof(v) > 0 && (v[0] == 'v' || v[0] == 'V'))
        v = v[1..];

    // Split off build metadata (+suffix) — ignored per semver spec
    int plus_idx = search(v, "+");
    if (plus_idx >= 0)
        v = v[..plus_idx - 1];

    // Split off prerelease (-suffix)
    string pre = "";
    int pre_idx = search(v, "-");
    if (pre_idx >= 0) {
        pre = v[pre_idx + 1..];
        v = v[..pre_idx - 1];
    }

    // Validate: remaining must be digits separated by dots
    array(string) parts = v / ".";
    if (sizeof(parts) < 1 || sizeof(parts) > 3) return 0;

    // All parts must be non-empty digit-only strings
    foreach (parts; ; string p) {
        if (sizeof(p) == 0) return 0;
        int dig = 1;
        foreach (p / 1; ; string c)
            if (c < "0" || c > "9") { dig = 0; break; }
        if (!dig) return 0;
    }

    int major, minor, patch;
    if (sscanf(parts[0], "%d", major) != 1) return 0;
    minor = sizeof(parts) > 1 ? (int)parts[1] : 0;
    patch = sizeof(parts) > 2 ? (int)parts[2] : 0;

    return ([
        "major": major,
        "minor": minor,
        "patch": patch,
        "prerelease": pre,
        "original": tag
    ]);
}

//! Compare two prerelease strings per semver spec.
//! Numeric identifiers < alpha identifiers. Numeric compared as integers.
//! Alpha compared lexically. Shorter < longer when prefix matches.
//! Empty (no prerelease) > any prerelease (release > prerelease).
int compare_prerelease(string a, string b) {
    // Both empty — equal
    if (sizeof(a) == 0 && sizeof(b) == 0) return 0;
    // Empty means release — release > prerelease
    if (sizeof(a) == 0) return 1;
    if (sizeof(b) == 0) return -1;

    array(string) pa = a / ".";
    array(string) pb = b / ".";

    int len = min(sizeof(pa), sizeof(pb));
    for (int i = 0; i < len; i++) {
        int a_num = (sscanf(pa[i], "%d", int a_val) == 1) && pa[i] == (string)a_val;
        int b_num = (sscanf(pb[i], "%d", int b_val) == 1) && pb[i] == (string)b_val;

        if (a_num && b_num) {
            // Both numeric — compare as integers
            int av = (int)pa[i];
            int bv = (int)pb[i];
            if (av < bv) return -1;
            if (av > bv) return 1;
        } else if (a_num) {
            // Numeric < alpha
            return -1;
        } else if (b_num) {
            // Alpha > numeric
            return 1;
        } else {
            // Both alpha — compare lexically
            if (pa[i] < pb[i]) return -1;
            if (pa[i] > pb[i]) return 1;
        }
    }

    // Common prefix equal — shorter comes first
    if (sizeof(pa) < sizeof(pb)) return -1;
    if (sizeof(pa) > sizeof(pb)) return 1;
    return 0;
}

//! Compare two parsed semver mappings.
//! Returns: -1 if a < b, 0 if a == b, 1 if a > b.
//! Unparseable (0) sorts below everything.
int compare_semver(mapping|mixed a, mapping|mixed b) {
    // Handle unparseable: treat as 0.0.0 (below everything)
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;

    // Compare major.minor.patch
    if (a["major"] != b["major"])
        return a["major"] < b["major"] ? -1 : 1;
    if (a["minor"] != b["minor"])
        return a["minor"] < b["minor"] ? -1 : 1;
    if (a["patch"] != b["patch"])
        return a["patch"] < b["patch"] ? -1 : 1;

    // Same major.minor.patch — compare prerelease
    return compare_prerelease(a["prerelease"], b["prerelease"]);
}

//! Sort an array of tag strings by semver (highest first).
//! Non-semver tags sort last (lowest priority).
array(string) sort_tags_semver(array(string) tags) {
    if (sizeof(tags) <= 1) return tags + ({});

    // Build pairs: ({parsed_semver_or_0, original_tag})
    array(array) pairs = ({});
    foreach (tags; ; string t)
        pairs += ({ ({ parse_semver(t), t }) });

    // sort_array comparator: returns true when elements should be swapped.
    // We want highest-first. If a > b (compare returns 1), we DON'T swap (return false = 1 < 0 = false).
    // If a < b (compare returns -1), we DO swap (return true = -1 < 0 = true).
    // Result: higher versions sort to the front.
    pairs = Array.sort_array(pairs, lambda(array a, array b) {
        mixed pa = a[0];
        mixed pb = b[0];
        if (!pa && !pb) return 0;   // both non-semver: keep
        if (!pa) return 1;           // a non-semver: push to end
        if (!pb) return 0;           // b non-semver: keep a before
        return compare_semver(pa, pb) < 0;
    });

    return column(pairs, 1);
}

//! Classify the version change from old_tag to new_tag.
//! Returns: "none", "major", "minor", "patch", "prerelease", "downgrade", or "unknown".
string classify_bump(string|void old_tag, string|void new_tag) {
    if (!old_tag || !new_tag) return "unknown";

    mapping old_v = parse_semver(old_tag);
    mapping new_v = parse_semver(new_tag);

    if (!old_v || !new_v) return "unknown";

    int cmp = compare_semver(old_v, new_v);

    if (cmp > 0) return "downgrade";
    if (cmp == 0) return "none";

    if (new_v["major"] != old_v["major"]) return "major";
    if (new_v["minor"] != old_v["minor"]) return "minor";

    // Same major.minor — could be patch or prerelease change
    if (sizeof(old_v["prerelease"]) > 0 || sizeof(new_v["prerelease"]) > 0)
        return "prerelease";

    return "patch";
}
