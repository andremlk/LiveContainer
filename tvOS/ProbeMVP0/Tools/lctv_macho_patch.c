#include <errno.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/*
 * Minimal tvOS Mach-O executable-to-dylib patcher.
 *
 * The transformation mirrors the core LCPatchExecSlice strategy used by
 * LiveContainer/LCMachOUtils.m in this AGPL-3.0 repository, intentionally
 * limited to a thin arm64 MH_MAGIC_64 binary for the MVP1 probe.
 */

static int fail(const char *message) {
    fprintf(stderr, "lctv_macho_patch: %s\n", message);
    return 1;
}

static int patch_macho(void *mapping, size_t file_size) {
    if (file_size < sizeof(struct mach_header_64)) {
        return fail("file is too small for mach_header_64");
    }

    struct mach_header_64 *header = (struct mach_header_64 *)mapping;
    if (header->magic != MH_MAGIC_64) {
        return fail("MVP1 supports thin little-endian 64-bit Mach-O only");
    }
    if (header->cputype != CPU_TYPE_ARM64) {
        return fail("MVP1 supports arm64 only");
    }
    if (header->filetype != MH_EXECUTE) {
        return fail("input is not MH_EXECUTE");
    }

    const uint64_t commands_end = sizeof(*header) + (uint64_t)header->sizeofcmds;
    if (commands_end > file_size) {
        return fail("load commands extend beyond file size");
    }

    struct segment_command_64 *pagezero = NULL;
    struct dylinker_command *dylinker = NULL;
    int has_main = 0;

    uint8_t *cursor = (uint8_t *)mapping + sizeof(*header);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if ((size_t)(cursor - (uint8_t *)mapping) + sizeof(struct load_command) > file_size) {
            return fail("truncated load command");
        }

        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command) ||
            (size_t)(cursor - (uint8_t *)mapping) + lc->cmdsize > file_size) {
            return fail("invalid load command size");
        }

        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__PAGEZERO", sizeof(seg->segname)) == 0) {
                pagezero = seg;
            }
        } else if (lc->cmd == LC_LOAD_DYLINKER) {
            dylinker = (struct dylinker_command *)lc;
        } else if (lc->cmd == LC_MAIN) {
            has_main = 1;
        }

        cursor += lc->cmdsize;
    }

    if (!pagezero) {
        return fail("__PAGEZERO segment not found");
    }
    if (!dylinker) {
        return fail("LC_LOAD_DYLINKER not found");
    }
    if (!has_main) {
        return fail("LC_MAIN not found");
    }

    if (dylinker->cmdsize < sizeof(struct dylib_command) + 2) {
        return fail("LC_LOAD_DYLINKER command is too small to reuse as LC_ID_DYLIB");
    }

    header->filetype = MH_DYLIB;
    header->flags |= MH_NO_REEXPORTED_DYLIBS;
    header->flags &= ~MH_PIE;

    pagezero->vmaddr = 0x100000000ULL - 0x4000ULL;
    pagezero->vmsize = 0x4000ULL;

    const uint32_t preserved_cmdsize = dylinker->cmdsize;
    memset(dylinker, 0, preserved_cmdsize);
    struct dylib_command *id = (struct dylib_command *)dylinker;
    id->cmd = LC_ID_DYLIB;
    id->cmdsize = preserved_cmdsize;
    id->dylib.name.offset = sizeof(struct dylib_command);
    id->dylib.timestamp = 2;
    id->dylib.current_version = 0x10000;
    id->dylib.compatibility_version = 0x10000;

    const char *install_name = "guest";
    const size_t capacity = preserved_cmdsize - sizeof(struct dylib_command);
    if (strlen(install_name) + 1 > capacity) {
        return fail("reused command has insufficient room for install name");
    }
    memcpy((uint8_t *)id + id->dylib.name.offset, install_name, strlen(install_name) + 1);

    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <thin-arm64-macho>\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    struct stat st;
    if (fstat(fd, &st) != 0) {
        perror("fstat");
        close(fd);
        return 1;
    }

    if (st.st_size <= 0) {
        close(fd);
        return fail("empty input file");
    }

    void *mapping = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    int result = patch_macho(mapping, (size_t)st.st_size);
    if (result == 0 && msync(mapping, (size_t)st.st_size, MS_SYNC) != 0) {
        perror("msync");
        result = 1;
    }

    munmap(mapping, (size_t)st.st_size);
    close(fd);

    if (result == 0) {
        printf("patched %s: MH_EXECUTE -> MH_DYLIB, __PAGEZERO adjusted, LC_ID_DYLIB installed\n", path);
    }
    return result;
}
