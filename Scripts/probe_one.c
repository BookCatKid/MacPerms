// Probe a single TCC function by name, isolated so crashes are attributable.
// Usage: ./probe_one <function-name>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>

typedef int (*preflight_fn)(CFStringRef, CFDictionaryRef);
typedef CFArrayRef (*copyids_fn)(CFStringRef);
typedef int (*setbundle_fn)(CFStringRef, CFStringRef, CFBooleanRef);

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <sym>\n", argv[0]); return 2; }
    void *h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY);
    if (!h) { printf("dlopen failed\n"); return 1; }
    const char *sym = argv[1];

    if (!strcmp(sym, "TCCAccessCopyBundleIdentifiersForService")) {
        copyids_fn f = (copyids_fn)dlsym(h, sym);
        CFArrayRef r = f(CFSTR("kTCCServiceMicrophone"));
        printf("result=%p\n", (void*)r);
        if (r) { CFShow(r); }
    } else if (!strcmp(sym, "TCCAccessPreflight")) {
        preflight_fn f = (preflight_fn)dlsym(h, sym);
        int r = f(CFSTR("kTCCServiceMicrophone"), NULL);
        printf("preflight=%d\n", r);
    } else if (!strcmp(sym, "TCCAccessSetForBundle")) {
        setbundle_fn f = (setbundle_fn)dlsym(h, sym);
        int r = f(CFSTR("kTCCServiceMicrophone"), CFSTR("com.devin.tccmgr-probe"), kCFBooleanTrue);
        printf("set=%d\n", r);
    } else {
        printf("unknown sym\n"); return 2;
    }
    return 0;
}
