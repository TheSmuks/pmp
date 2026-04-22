---
name: review
description: Review staged git changes for issues before committing
---

Review the currently staged git changes (`git diff --cached`). Focus on:

1. **Correctness**: Logic errors, off-by-one, missing null/edge case handling
2. **Security**: Hardcoded secrets, path traversal, unsafe input handling
3. **Performance**: Unnecessary allocations, redundant HTTP calls, O(n^2) where O(n) is possible
4. **Pike Style**: Arrays `({})`, mappings `([])`, multisets `(<>)`, 4-space indent. Check for common Pike mistakes like using `String.trim` instead of `String.trim_all_whites`

Output a concise summary with:
- List of issues found (or confirmation that changes look clean)
- Severity level for each issue (critical / warning / nit)
- Suggested fix for each issue

Do NOT suggest changes that are out of scope for the current diff.
