#import "GuestImportRebinder.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <stdint.h>
#import <string.h>

extern const char *LCTVUIKitGuestMarker(void);

static BOOL LCTVSymbolNameMatches(const char *machoName, const char *requestedName) {
    if (!machoName || !requestedName) return NO;
    if (strcmp(machoName, requestedName) == 0) return YES;
    // Mach-O nlist names have the ABI leading underscore. dlsym-style names do not.
    if (machoName[0] == '_' && strcmp(machoName + 1, requestedName) == 0) return YES;
    return NO;
}

static BOOL LCTVMakeImportSlotWritable(void *address, NSString **errorOut) {
    vm_size_t pageSize = (vm_size_t)vm_page_size;
    vm_address_t page = (vm_address_t)((uintptr_t)address & ~((uintptr_t)pageSize - 1));
    kern_return_t kr = vm_protect(mach_task_self(),
                                  page,
                                  pageSize,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"vm_protect(import slot) failed: %d", kr];
        }
        return NO;
    }
    return YES;
}

BOOL LCTVRebindGuestImport(const char *symbolName,
                           void *replacement,
                           void **originalOut,
                           NSUInteger *reboundCountOut,
                           NSString **errorOut) {
    if (originalOut) *originalOut = NULL;
    if (reboundCountOut) *reboundCountOut = 0;
    if (!symbolName || !replacement) {
        if (errorOut) *errorOut = @"invalid import rebind arguments";
        return NO;
    }

    Dl_info imageInfo = {0};
    if (dladdr((const void *)&LCTVUIKitGuestMarker, &imageInfo) == 0 || !imageInfo.dli_fbase) {
        if (errorOut) *errorOut = @"dladdr could not resolve UIKitGuestTV image";
        return NO;
    }

    const struct mach_header_64 *header = (const struct mach_header_64 *)imageInfo.dli_fbase;
    if (header->magic != MH_MAGIC_64) {
        if (errorOut) *errorOut = @"UIKitGuestTV image is not MH_MAGIC_64";
        return NO;
    }

    const struct segment_command_64 *textSegment = NULL;
    const struct segment_command_64 *linkeditSegment = NULL;
    const struct symtab_command *symtabCommand = NULL;
    const struct dysymtab_command *dysymtabCommand = NULL;

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (seg->fileoff == 0 && !textSegment) textSegment = seg;
            if (strncmp(seg->segname, SEG_LINKEDIT, sizeof(seg->segname)) == 0) linkeditSegment = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtabCommand = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtabCommand = (const struct dysymtab_command *)lc;
        }
        cursor += lc->cmdsize;
    }

    if (!textSegment || !linkeditSegment) {
        if (errorOut) *errorOut = @"guest __TEXT/__LINKEDIT segments unavailable";
        return NO;
    }

    uintptr_t slide = (uintptr_t)header - (uintptr_t)textSegment->vmaddr;
    uintptr_t linkeditBase = slide + (uintptr_t)linkeditSegment->vmaddr - (uintptr_t)linkeditSegment->fileoff;

    const struct nlist_64 *symbols = NULL;
    const char *strings = NULL;
    const uint32_t *indirectSymbols = NULL;
    if (symtabCommand && dysymtabCommand) {
        symbols = (const struct nlist_64 *)(linkeditBase + symtabCommand->symoff);
        strings = (const char *)(linkeditBase + symtabCommand->stroff);
        indirectSymbols = (const uint32_t *)(linkeditBase + dysymtabCommand->indirectsymoff);
    }

    void *resolvedOriginal = dlsym(RTLD_DEFAULT, symbolName);
    NSUInteger reboundCount = 0;
    void *firstOriginal = NULL;

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
            uint32_t sectionType = section->flags & SECTION_TYPE;
            if (sectionType != S_LAZY_SYMBOL_POINTERS &&
                sectionType != S_NON_LAZY_SYMBOL_POINTERS &&
                sectionType != S_THREAD_LOCAL_VARIABLE_POINTERS) {
                continue;
            }

            size_t pointerCount = (size_t)(section->size / sizeof(void *));
            void **slots = (void **)(slide + (uintptr_t)section->addr);

            for (size_t slotIndex = 0; slotIndex < pointerCount; slotIndex++) {
                BOOL matches = NO;

                if (symbols && strings && indirectSymbols) {
                    uint32_t symbolIndex = indirectSymbols[section->reserved1 + (uint32_t)slotIndex];
                    if ((symbolIndex & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) == 0 &&
                        symbolIndex < symtabCommand->nsyms) {
                        uint32_t stringOffset = symbols[symbolIndex].n_un.n_strx;
                        if (stringOffset < symtabCommand->strsize) {
                            const char *machoName = strings + stringOffset;
                            matches = LCTVSymbolNameMatches(machoName, symbolName);
                        }
                    }
                }

                // Fallback for modern chained-fixup layouts where indirect metadata can be sparse.
                if (!matches && resolvedOriginal && slots[slotIndex] == resolvedOriginal) {
                    matches = YES;
                }

                if (!matches) continue;

                NSString *protectError = nil;
                if (!LCTVMakeImportSlotWritable(&slots[slotIndex], &protectError)) {
                    if (errorOut) *errorOut = protectError;
                    return NO;
                }

                if (!firstOriginal) firstOriginal = slots[slotIndex];
                slots[slotIndex] = replacement;
                reboundCount++;
            }
        }

        cursor += lc->cmdsize;
    }

    if (reboundCount == 0) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"guest import not found: %s", symbolName];
        }
        return NO;
    }

    if (originalOut) *originalOut = firstOriginal ?: resolvedOriginal;
    if (reboundCountOut) *reboundCountOut = reboundCount;
    return YES;
}
