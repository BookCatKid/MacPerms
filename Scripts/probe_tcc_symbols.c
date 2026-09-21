// Probe which private TCC.framework symbols exist on this system.
// Usage: clang probe_tcc_symbols.c -o probe && ./probe
#include <dlfcn.h>
#include <stdio.h>

int main(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    printf("dlopen ok: %p\n\n", h);

    const char *syms[] = {
        // documented/semi-documented request path
        "TCCAccessRequest",
        "TCCAccessRequestImplicit",
        "TCCAccessRequestIndirect",
        "TCCAccessPreflight",
        // audit-token based checking / setting (used by settings UI)
        "TCCAccessCheckAuditToken",
        "TCCAccessSetForAuditToken",
        "TCCAccessSetForResponsiblePid",
        "TCCAccessSetForBundle",
        "TCCAccessSetForPath",
        "TCCAccessResetForBundle",
        "TCCAccessGetInformation",
        "TCCAccessCopyInformation",
        "TCCAccessCopyBundleIdentifiersForService",
        "TCCAccessCopyBundleIdentifiersDisabledForService",
        "TCCAccessCopyBundleIdentifiersDisabledForServiceWithProfile",
        // policy / internal
        "TCCAccessSelectPolicyForExtension",
        "TCCAccessSelectPolicyForExtensionWithURL",
        "TCCAccessCopyBundleIdentifierForAuditToken",
        "TCCAccessReportPolicyForExtension",
        "kTCCAccessCheckOptionPrompt",
        "kTCCAccessCheckOptionShowUI",
        // older entry points
        "TCCAccessRequestIndirectWithoutExtension",
        "TCCAccessRequestSwitchboard",
        // misc
        "TCCRuntimeCheckEntitlement",
        "TCCCopyDesignatedRequirementIdentity",
        "TCCAccessRestartTCCD",
        "TCCAccessVersion",
        NULL
    };
    for (int i = 0; syms[i]; i++) {
        void *p = dlsym(h, syms[i]);
        printf("%-60s %s\n", syms[i], p ? "FOUND" : "-");
    }
    return 0;
}
