/**
 * pmp-baseline-guard.ts
 * 
 * Guards pmp's test baseline and invariants:
 * 1. Test baseline: warns if test count shifts from expected 242
 * 2. pike.json version edit: reminds to sync Config.pmod
 * 3. gitignore edit: warns if pike.lock is being re-added
 */

const EXPECTED_PASSED = 242;

/**
 * Check test output for baseline drift
 */
export function onTestOutput(output: string): string | null {
    const match = output.match(/(\d+)\s+passed/);
    if (!match) return null;
    
    const actual = parseInt(match[1], 10);
    if (actual !== EXPECTED_PASSED) {
        return `[pmp-baseline-guard] WARNING: Test count shifted from ${EXPECTED_PASSED} to ${actual}. ` +
               `Update AGENTS.md test baseline if this is intentional.`;
    }
    return null;
}

/**
 * Check pike.json edits for version field changes
 */
export function onPikeJsonEdit(newContent: string, oldContent: string): string | null {
    const oldVersion = oldContent.match(/"version":\s*"([^"]+)"/)?.[1];
    const newVersion = newContent.match(/"version":\s*"([^"]+)"/)?.[1];
    
    if (oldVersion !== newVersion && newVersion) {
        return `[pmp-baseline-guard] Version change detected in pike.json (${newVersion}). ` +
               `Remember to also update PMP_VERSION in bin/Pmp.pmod/Config.pmod to match.`;
    }
    return null;
}

/**
 * Check gitignore edits for pike.lock re-addition
 */
export function onGitignoreEdit(newContent: string, oldContent: string): string | null {
    const hasPikeLock = (content: string) => /^pike\.lock$/m.test(content);
    
    if (hasPikeLock(newContent) && !hasPikeLock(oldContent)) {
        return `[pmp-baseline-guard] WARNING: pike.lock is being re-added to .gitignore. ` +
               `pmp.lock should remain committed for CI reproducibility. ` +
               `Do NOT gitignore pike.lock.`;
    }
    return null;
}