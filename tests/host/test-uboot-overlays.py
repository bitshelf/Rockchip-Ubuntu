#!/usr/bin/env python3
"""Compile the shipped overlay helper and exercise its failure handling."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
patch = (repo / 'docs/patches/u-boot/0001-rockchip-extlinux-fdtoverlays.patch').read_text()
added = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))
start = added.index('static int label_boot_fdtoverlay(')
end = added.index('\n}\n', start) + 3
helper = added[start:end]
assert 'label_boot_fdtoverlay(cmdtp, label)) {' in patch
source = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned long ulong;
typedef int cmd_tbl_t;
struct fdt_header { int unused; };
struct pxe_label { char *fdtoverlays; };
static const char *base, *overlay;
static int no_memory, bad_base, bad_overlay, load_error, shrink_error, apply_error;
static int loaded, applied;
static char names[64];
static char *env_get(const char *name) { return (char *)(!strcmp(name,"fdt_addr_r") ? base : overlay); }
static int strict_strtoul(const char *text, unsigned int radix, ulong *value) {
    char *end;
    if (!text || !*text) return -EINVAL;
    *value=strtoul(text,&end,radix);
    return *end ? -EINVAL : 0;
}
static void *map_sysmem(ulong addr, int unused) { (void)unused; return (void *)addr; }
static int fdt_check_header(void *ptr) { return ptr == (void *)0x1000 ? -bad_base : -bad_overlay; }
static void *qa_malloc(size_t size) { return no_memory ? NULL : malloc(size); }
#define malloc qa_malloc
static int get_relfile_envaddr(cmd_tbl_t *cmd, const char *file, const char *env) {
    (void)cmd; (void)env; ++loaded;
    strncat(names, file, sizeof(names)-strlen(names)-2); strcat(names,";");
    return load_error ? -EIO : 1;
}
static int fdt_shrink_to_minimum(void *ptr, int extra) {
    (void)ptr; (void)extra; return shrink_error ? -ENOSPC : 8192;
}
static int fdt_overlay_apply_verbose(void *ptr, void *blob) {
    (void)ptr; (void)blob; ++applied; return apply_error ? -EINVAL : 0;
}
'''+helper+r'''
static void reset(void) {
    base="1000"; overlay="2000"; no_memory=bad_base=bad_overlay=load_error=shrink_error=apply_error=0;
    loaded=applied=0; names[0]=0;
}
int main(void) {
    char list[]="  a  b  ";
    struct pxe_label label={list};
    reset(); assert(label_boot_fdtoverlay(NULL,&label)==0); assert(applied==2); assert(!strcmp(names,"a;b;"));
    reset(); base=NULL; assert(label_boot_fdtoverlay(NULL,&label)==-EINVAL); assert(!loaded);
    reset(); overlay=NULL; assert(label_boot_fdtoverlay(NULL,&label)==-EINVAL); assert(!loaded);
    reset(); base="1000junk"; assert(label_boot_fdtoverlay(NULL,&label)==-EINVAL);
    reset(); overlay="1000"; assert(label_boot_fdtoverlay(NULL,&label)==-EINVAL);
    reset(); overlay="0"; assert(label_boot_fdtoverlay(NULL,&label)==-EINVAL);
    reset(); no_memory=1; assert(label_boot_fdtoverlay(NULL,&label)==-ENOMEM);
    reset(); bad_base=1; assert(label_boot_fdtoverlay(NULL,&label)<0); assert(!loaded);
    reset(); bad_overlay=1; assert(label_boot_fdtoverlay(NULL,&label)<0); assert(!applied);
    reset(); load_error=1; assert(label_boot_fdtoverlay(NULL,&label)==-EIO); assert(loaded==1 && !applied);
    reset(); shrink_error=1; assert(label_boot_fdtoverlay(NULL,&label)==-ENOSPC); assert(!applied);
    reset(); apply_error=1; assert(label_boot_fdtoverlay(NULL,&label)==-EINVAL); assert(loaded==1 && applied==1);
    reset(); label.fdtoverlays=" "; assert(label_boot_fdtoverlay(NULL,&label)==0); assert(!loaded);
    puts("U-Boot overlay helper: upstream order/space handling and 11 failure/empty cases passed");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / 'test.c').write_text(source)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-o', str(root / 'test'), str(root / 'test.c')], check=True)
    subprocess.run([str(root / 'test')], check=True)
