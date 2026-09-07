#import "GuestRuntime.h"

#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

static NSBundle *gLCTVHostGuestBundle = nil;
static IMP gLCTVOriginalMainBundleIMP = NULL;
static CFBundleRef gLCTVHostGuestCFBundle = NULL;
static char *gLCTVHostGuestExecutable = NULL;
static NSString *gLCTVHostGuestHome = nil;
static int (*gLCTVOriginalNSGetExecutablePath)(char *, uint32_t *) = NULL;
static NSString *(*gLCTVOriginalNSHomeDirectory)(void) = NULL;

static NSString *LCTVExistingStatus(void) {
    const char *value = getenv("LCTV_HOST_RUNTIME_STATUS");
    return value ? ([NSString stringWithUTF8String:value] ?: @"") : @"";
}

static void LCTVStoreStatus(NSArray<NSString *> *parts) {
    NSString *status = [parts componentsJoinedByString:@"; "];
    setenv("LCTV_HOST_RUNTIME_STATUS", status.UTF8String, 1);
}

static BOOL LCTVMakeWritable(void *address, NSString **errorOut) {
    vm_size_t pageSize = (vm_size_t)vm_page_size;
    vm_address_t page = (vm_address_t)((uintptr_t)address & ~((uintptr_t)pageSize - 1));
    kern_return_t kr = vm_protect(mach_task_self(),
                                  page,
                                  pageSize,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"vm_protect failed: %d", kr];
        return NO;
    }
    return YES;
}

static BOOL LCTVSymbolMatches(const char *machoName, const char *requested) {
    if (!machoName || !requested) return NO;
    if (strcmp(machoName, requested) == 0) return YES;
    return machoName[0] == '_' && strcmp(machoName + 1, requested) == 0;
}

static BOOL LCTVRebindGuestImport(const struct mach_header_64 *header,
                                  const char *symbolName,
                                  void *replacement,
                                  void **originalOut,
                                  NSUInteger *countOut,
                                  NSString **errorOut) {
    if (originalOut) *originalOut = NULL;
    if (countOut) *countOut = 0;
    if (!header || header->magic != MH_MAGIC_64 || !symbolName || !replacement) {
        if (errorOut) *errorOut = @"invalid guest import rebind arguments";
        return NO;
    }

    const struct segment_command_64 *textSegment = NULL;
    const struct segment_command_64 *linkeditSegment = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, SEG_TEXT, sizeof(seg->segname)) == 0) textSegment = seg;
            if (strncmp(seg->segname, SEG_LINKEDIT, sizeof(seg->segname)) == 0) linkeditSegment = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)lc;
        }
        cursor += lc->cmdsize;
    }

    if (!textSegment || !linkeditSegment) {
        if (errorOut) *errorOut = @"guest __TEXT/__LINKEDIT unavailable";
        return NO;
    }

    uintptr_t slide = (uintptr_t)header - (uintptr_t)textSegment->vmaddr;
    uintptr_t linkeditBase = slide + (uintptr_t)linkeditSegment->vmaddr - (uintptr_t)linkeditSegment->fileoff;

    const struct nlist_64 *symbols = NULL;
    const char *strings = NULL;
    const uint32_t *indirect = NULL;
    if (symtab && dysymtab) {
        symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
        strings = (const char *)(linkeditBase + symtab->stroff);
        indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);
    }

    void *resolvedOriginal = dlsym(RTLD_DEFAULT, symbolName);
    void *firstOriginal = NULL;
    NSUInteger count = 0;

    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd != LC_SEGMENT_64) {
            cursor += lc->cmdsize;
            continue;
        }

        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *sections = (const struct section_64 *)(seg + 1);
        for (uint32_t sectionIndex = 0; sectionIndex < seg->nsects; sectionIndex++) {
            const struct section_64 *section = &sections[sectionIndex];
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS &&
                type != S_NON_LAZY_SYMBOL_POINTERS &&
                type != S_THREAD_LOCAL_VARIABLE_POINTERS) {
                continue;
            }

            size_t pointerCount = (size_t)(section->size / sizeof(void *));
            void **slots = (void **)(slide + (uintptr_t)section->addr);
            for (size_t slotIndex = 0; slotIndex < pointerCount; slotIndex++) {
                BOOL matches = NO;
                if (symbols && strings && indirect) {
                    uint32_t symbolIndex = indirect[section->reserved1 + (uint32_t)slotIndex];
                    if ((symbolIndex & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) == 0 &&
                        symbolIndex < symtab->nsyms) {
                        uint32_t stringOffset = symbols[symbolIndex].n_un.n_strx;
                        if (stringOffset < symtab->strsize) {
                            matches = LCTVSymbolMatches(strings + stringOffset, symbolName);
                        }
                    }
                }
                if (!matches && resolvedOriginal && slots[slotIndex] == resolvedOriginal) matches = YES;
                if (!matches) continue;

                NSString *protectError = nil;
                if (!LCTVMakeWritable(&slots[slotIndex], &protectError)) {
                    if (errorOut) *errorOut = protectError;
                    return NO;
                }
                if (!firstOriginal) firstOriginal = slots[slotIndex];
                slots[slotIndex] = replacement;
                count++;
            }
        }
        cursor += lc->cmdsize;
    }

    if (!count) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"guest import not found: %s", symbolName];
        return NO;
    }
    if (originalOut) *originalOut = firstOriginal ?: resolvedOriginal;
    if (countOut) *countOut = count;
    return YES;
}

static NSBundle *LCTVHostMainBundleOverride(id self, SEL _cmd) {
    if (gLCTVHostGuestBundle) return gLCTVHostGuestBundle;
    if (gLCTVOriginalMainBundleIMP) {
        NSBundle *(*original)(id, SEL) = (NSBundle *(*)(id, SEL))gLCTVOriginalMainBundleIMP;
        return original(self, _cmd);
    }
    return nil;
}

static BOOL LCTVInstallNSBundleOverride(NSBundle *guestBundle, NSString *expectedID, NSString **errorOut) {
    Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    if (!method) {
        if (errorOut) *errorOut = @"+[NSBundle mainBundle] unavailable";
        return NO;
    }
    gLCTVHostGuestBundle = guestBundle;
    if (!gLCTVOriginalMainBundleIMP) {
        gLCTVOriginalMainBundleIMP = method_setImplementation(method, (IMP)LCTVHostMainBundleOverride);
    } else {
        method_setImplementation(method, (IMP)LCTVHostMainBundleOverride);
    }
    BOOL ok = [NSBundle.mainBundle.bundleIdentifier isEqualToString:expectedID];
    if (!ok && errorOut) {
        *errorOut = [NSString stringWithFormat:@"NSBundle still reports %@", NSBundle.mainBundle.bundleIdentifier ?: @"(nil)"];
    }
    return ok;
}

static uint64_t LCTVGetTbnzTarget(uint32_t instruction, uint64_t pc) {
    if ((instruction & 0xFF000000) != 0x37000000) return 0;
    int64_t imm14 = (int64_t)((instruction >> 5) & 0x3FFF);
    if (imm14 & 0x2000) imm14 |= ~0x3FFFLL;
    return (uint64_t)((int64_t)pc + (imm14 << 2));
}

static uint64_t LCTVEmulateAdrp(uint32_t instruction, uint64_t pc) {
    if ((instruction & 0x9F000000) != 0x90000000) return 0;
    int32_t immHiLo = (instruction & 0xFFFFE0) >> 3;
    immHiLo |= (instruction & 0x60000000) >> 29;
    if (instruction & 0x800000) immHiLo |= 0xFFE00000;
    return (pc & ~0xFFFULL) + ((int64_t)immHiLo << 12);
}

static uint64_t LCTVEmulateAdrpLdr(uint32_t adrp, uint32_t ldr, uint64_t pc) {
    uint64_t target = LCTVEmulateAdrp(adrp, pc);
    if (!target) return 0;
    if ((adrp & 0x1F) != ((ldr >> 5) & 0x1F)) return 0;
    if ((ldr & 0xFFC00000) != 0xF9400000) return 0;
    uint32_t imm12 = ((ldr >> 10) & 0xFFF) << 3;
    return target + imm12;
}

static BOOL LCTVInstallCFBundleOverride(NSBundle *guestBundle, NSString *expectedID, NSString **errorOut) {
    if (!gLCTVHostGuestCFBundle) {
        gLCTVHostGuestCFBundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)guestBundle.bundleURL);
    }
    if (!gLCTVHostGuestCFBundle) {
        if (errorOut) *errorOut = @"CFBundleCreate failed";
        return NO;
    }

    CFBundleRef originalMain = CFBundleGetMainBundle();
    uint32_t *start = (uint32_t *)(uintptr_t)CFBundleGetMainBundle;
    void **slot = NULL;
    for (NSUInteger i = 1; i < 160; i++) {
        uint32_t *pc = start + i;
        uint64_t branch = LCTVGetTbnzTarget(*pc, (uint64_t)pc);
        if (!branch) continue;
        intptr_t distance = (intptr_t)branch - (intptr_t)start;
        if (distance < -0x10000 || distance > 0x10000 || (branch & 3)) continue;
        uint64_t candidateAddress = LCTVEmulateAdrpLdr(*(pc - 1),
                                                        *(uint32_t *)(uintptr_t)branch,
                                                        (uint64_t)(pc - 1));
        if (!candidateAddress || (candidateAddress & (sizeof(void *) - 1))) continue;
        void **candidate = (void **)(uintptr_t)candidateAddress;
        if (*candidate == (void *)originalMain) {
            slot = candidate;
            break;
        }
    }
    if (!slot) {
        if (errorOut) *errorOut = @"CoreFoundation main-bundle storage not found";
        return NO;
    }
    NSString *protectError = nil;
    if (!LCTVMakeWritable(slot, &protectError)) {
        if (errorOut) *errorOut = protectError;
        return NO;
    }
    *slot = (void *)gLCTVHostGuestCFBundle;

    CFStringRef cfID = CFBundleGetIdentifier(CFBundleGetMainBundle());
    NSString *observed = cfID ? (__bridge NSString *)cfID : nil;
    BOOL ok = [observed isEqualToString:expectedID];
    if (!ok && errorOut) *errorOut = [NSString stringWithFormat:@"CFBundle still reports %@", observed ?: @"(nil)"];
    return ok;
}

static int LCTVHostExecutablePathOverride(char *buf, uint32_t *bufsize) {
    if (!gLCTVHostGuestExecutable || !bufsize) return -1;
    size_t required = strlen(gLCTVHostGuestExecutable) + 1;
    if (!buf || *bufsize < required) {
        *bufsize = (uint32_t)required;
        return -1;
    }
    memcpy(buf, gLCTVHostGuestExecutable, required);
    *bufsize = (uint32_t)required;
    return 0;
}

static NSString *LCTVHostNSHomeDirectoryOverride(void) {
    if (gLCTVHostGuestHome) return gLCTVHostGuestHome;
    return gLCTVOriginalNSHomeDirectory ? gLCTVOriginalNSHomeDirectory() : @"/";
}

BOOL LCTVPrepareHostGuestIdentityBeforeLoad(NSString *guestBundlePath,
                                            NSString *guestExecutablePath,
                                            NSString *guestBundleIdentifier,
                                            NSString *guestProcessName,
                                            NSString *guestHomePath,
                                            NSString **errorOut) {
    if (!guestBundlePath.length || !guestExecutablePath.length ||
        !guestBundleIdentifier.length || !guestProcessName.length || !guestHomePath.length) {
        if (errorOut) *errorOut = @"host guest identity context is incomplete";
        return NO;
    }

    NSBundle *guestBundle = [NSBundle bundleWithPath:guestBundlePath];
    if (!guestBundle) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"NSBundle could not open guest at %@", guestBundlePath];
        return NO;
    }

    NSError *mkdirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:guestHomePath
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&mkdirError]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"guest HOME mkdir failed: %@", mkdirError];
        return NO;
    }

    NSMutableArray<NSString *> *status = [NSMutableArray array];
    BOOL ok = YES;

    gLCTVHostGuestHome = [guestHomePath copy];
    free(gLCTVHostGuestExecutable);
    gLCTVHostGuestExecutable = strdup(guestExecutablePath.fileSystemRepresentation);
    if (!gLCTVHostGuestExecutable) {
        ok = NO;
        [status addObject:@"executable strdup failed"];
    } else {
        [status addObject:@"executable context prepared"];
    }

    if (setenv("HOME", guestHomePath.fileSystemRepresentation, 1) != 0 ||
        setenv("CFFIXED_USER_HOME", guestHomePath.fileSystemRepresentation, 1) != 0) {
        ok = NO;
        [status addObject:@"HOME env failed"];
    } else {
        [status addObject:@"HOME env installed pre-dlopen"];
    }

    NSProcessInfo.processInfo.processName = guestProcessName;
    typedef const char **(*CFGetPrognameFn)(void);
    CFGetPrognameFn getProgname = (CFGetPrognameFn)dlsym(RTLD_DEFAULT, "_CFGetProgname");
    if (getProgname) {
        const char **slot = getProgname();
        if (slot) *slot = strdup(guestProcessName.UTF8String);
    }
    [status addObject:@"processName installed pre-dlopen"];

    NSString *stepError = nil;
    if (!LCTVInstallNSBundleOverride(guestBundle, guestBundleIdentifier, &stepError)) {
        ok = NO;
        [status addObject:[NSString stringWithFormat:@"NSBundle failed: %@", stepError ?: @"unknown"]];
    } else {
        [status addObject:@"NSBundle installed pre-dlopen"];
    }

    stepError = nil;
    if (!LCTVInstallCFBundleOverride(guestBundle, guestBundleIdentifier, &stepError)) {
        ok = NO;
        [status addObject:[NSString stringWithFormat:@"CFBundle failed: %@", stepError ?: @"unknown"]];
    } else {
        [status addObject:@"CFBundle installed pre-dlopen"];
    }

    LCTVStoreStatus(status);
    NSString *statusText = [status componentsJoinedByString:@"; "];
    if (errorOut) *errorOut = ok ? nil : statusText;
    return ok;
}

BOOL LCTVFinishHostGuestIdentityAfterLoad(const struct mach_header_64 *guestHeader,
                                          NSString **errorOut) {
    if (!guestHeader || guestHeader->magic != MH_MAGIC_64) {
        if (errorOut) *errorOut = @"loaded guest header is unavailable";
        return NO;
    }

    NSMutableArray<NSString *> *status = [NSMutableArray array];
    NSString *existing = LCTVExistingStatus();
    if (existing.length) [status addObject:existing];
    BOOL ok = YES;

    if (!gLCTVHostGuestExecutable) {
        ok = NO;
        [status addObject:@"_NSGetExecutablePath failed: executable context missing"];
    } else {
        void *original = NULL;
        NSUInteger count = 0;
        NSString *stepError = nil;
        if (!LCTVRebindGuestImport(guestHeader,
                                   "_NSGetExecutablePath",
                                   (void *)&LCTVHostExecutablePathOverride,
                                   &original,
                                   &count,
                                   &stepError)) {
            ok = NO;
            [status addObject:[NSString stringWithFormat:@"_NSGetExecutablePath failed: %@", stepError ?: @"unknown"]];
        } else {
            if (!gLCTVOriginalNSGetExecutablePath && original) {
                gLCTVOriginalNSGetExecutablePath = (int (*)(char *, uint32_t *))original;
            }
            [status addObject:[NSString stringWithFormat:@"_NSGetExecutablePath installed post-dlopen (%lu)", (unsigned long)count]];
        }
    }

    void *originalHome = NULL;
    NSUInteger homeCount = 0;
    NSString *homeError = nil;
    if (!LCTVRebindGuestImport(guestHeader,
                               "NSHomeDirectory",
                               (void *)&LCTVHostNSHomeDirectoryOverride,
                               &originalHome,
                               &homeCount,
                               &homeError)) {
        ok = NO;
        [status addObject:[NSString stringWithFormat:@"NSHomeDirectory failed: %@", homeError ?: @"unknown"]];
    } else {
        if (!gLCTVOriginalNSHomeDirectory && originalHome) {
            gLCTVOriginalNSHomeDirectory = (NSString *(*)(void))originalHome;
        }
        [status addObject:[NSString stringWithFormat:@"NSHomeDirectory installed post-dlopen (%lu)", (unsigned long)homeCount]];
    }

    LCTVStoreStatus(status);
    NSString *statusText = [status componentsJoinedByString:@"; "];
    if (errorOut) *errorOut = ok ? nil : statusText;
    return ok;
}

BOOL LCTVApplyHostGuestIdentity(const struct mach_header_64 *guestHeader,
                                NSString *guestBundlePath,
                                NSString *guestExecutablePath,
                                NSString *guestBundleIdentifier,
                                NSString *guestProcessName,
                                NSString *guestHomePath,
                                NSString **errorOut) {
    NSString *preError = nil;
    BOOL preOK = LCTVPrepareHostGuestIdentityBeforeLoad(guestBundlePath,
                                                        guestExecutablePath,
                                                        guestBundleIdentifier,
                                                        guestProcessName,
                                                        guestHomePath,
                                                        &preError);
    NSString *postError = nil;
    BOOL postOK = LCTVFinishHostGuestIdentityAfterLoad(guestHeader, &postError);
    BOOL ok = preOK && postOK;
    if (!ok && errorOut) {
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        if (preError.length) [errors addObject:preError];
        if (postError.length) [errors addObject:postError];
        *errorOut = [errors componentsJoinedByString:@" | "];
    } else if (errorOut) {
        *errorOut = nil;
    }
    return ok;
}
