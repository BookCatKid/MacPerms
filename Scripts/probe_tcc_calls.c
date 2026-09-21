// Probe behavior of private TCC.framework calls WITHOUT any private entitlements.
#include <dlfcn.h>
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>

typedef int (*preflight_fn)(CFStringRef, CFDictionaryRef);
typedef int (*checktoken_fn)(CFStringRef, void*, CFDictionaryRef);
typedef int (*setbundle_fn)(CFStringRef, CFStringRef, CFBooleanRef);
typedef CFArrayRef (*copyids_fn)(CFStringRef);
typedef CFPropertyListRef (*copyinfo_fn)(CFStringRef, CFStringRef, CFStringRef);
typedef int (*request_fn)(CFStringRef, CFDictionaryRef, void(^)(int));

int main(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY);
    if (!h) { printf("dlopen failed\n"); return 1; }

    CFStringRef mic = CFSTR("kTCCServiceMicrophone");

    // 1. copy bundle identifiers granted a service
    copyids_fn copyids = (copyids_fn)dlsym(h, "TCCAccessCopyBundleIdentifiersForService");
    if (copyids) {
        CFArrayRef r = copyids(mic);
        if (r) {
            CFShow(r);
        } else {
            printf("TCCAccessCopyBundleIdentifiersForService -> NULL\n");
        }
    }

    // 2. preflight for THIS process (should return 'unknown' or 'denied' without record)
    preflight_fn preflight = (preflight_fn)dlsym(h, "TCCAccessPreflight");
    if (preflight) {
        int r = preflight(mic, NULL);
        printf("TCCAccessPreflight(kTCCServiceMicrophone, self) = %d\n", r);
    }

    // 3. try a set for a fake bundle id — expect failure without entitlement
    setbundle_fn setbundle = (setbundle_fn)dlsym(h, "TCCAccessSetForBundle");
    if (setbundle) {
        int r = setbundle(CFSTR("kTCCServiceMicrophone"), CFSTR("com.devin.tccmgr-probe"), kCFBooleanTrue);
        printf("TCCAccessSetForBundle(grant fake) = %d\n", r);
    }

    return 0;
}
