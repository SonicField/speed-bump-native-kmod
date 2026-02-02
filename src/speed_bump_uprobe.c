// SPDX-License-Identifier: GPL-2.0
/*
 * Speed Bump - Uprobe Management
 *
 * Handles uprobe registration, symbol resolution, and uprobe handlers.
 */

#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/uprobes.h>
#include <linux/namei.h>
#include <linux/fs.h>
#include <linux/elf.h>
#include <linux/file.h>

#include "speed_bump.h"
#include "speed_bump_internal.h"

/* ============================================================
 * Uprobe Handler
 * ============================================================ */

/*
 * Uprobe handler called when a probed function is entered.
 * Executes the spin delay configured for this target.
 */
static int speed_bump_uprobe_handler(struct uprobe_consumer *uc,
				     struct pt_regs *regs,
				     __u64 *data)
{
	struct speed_bump_target *target;

	if (!atomic_read(&speed_bump_enabled))
		return 0;

	target = container_of(uc, struct speed_bump_target, uc);

	/* Execute the delay */
	speed_bump_spin_delay_ns(target->delay_ns);

	/* Update statistics */
	atomic64_inc(&target->hit_count);
	atomic64_add(target->delay_ns, &target->total_delay_ns);
	atomic64_inc(&speed_bump_total_hits);
	atomic64_add(target->delay_ns, &speed_bump_total_delay);

	return 0;
}

/* ============================================================
 * ELF Symbol Resolution
 * ============================================================
 *
 * These functions resolve a symbol name to an offset within an ELF file.
 * Note: This is a simplified implementation that handles common cases.
 * Production use may need additional validation and error handling.
 */

/*
 * Read ELF symbol table and find the offset for a symbol.
 * Returns the symbol offset on success, 0 on failure.
 */
static loff_t resolve_symbol_offset(struct file *file,
				    const char *symbol_name)
{
	struct elf64_hdr ehdr;
	struct elf64_shdr *shdrs = NULL;
	char *shstrtab = NULL;
	char *strtab = NULL;
	struct elf64_sym *symtab = NULL;
	loff_t offset = 0;
	loff_t pos = 0;
	ssize_t ret;
	int i, j;
	unsigned int symcount;
	size_t shstrtab_size, strtab_size, symtab_size;

	/* Read ELF header */
	ret = kernel_read(file, &ehdr, sizeof(ehdr), &pos);
	if (ret != sizeof(ehdr))
		return 0;

	/* Verify ELF magic */
	if (memcmp(ehdr.e_ident, ELFMAG, SELFMAG) != 0)
		return 0;

	/* Only support 64-bit ELF */
	if (ehdr.e_ident[EI_CLASS] != ELFCLASS64)
		return 0;

	/* Allocate and read section headers */
	shdrs = kmalloc_array(ehdr.e_shnum, sizeof(*shdrs), GFP_KERNEL);
	if (!shdrs)
		goto out;

	pos = ehdr.e_shoff;
	ret = kernel_read(file, shdrs, ehdr.e_shnum * sizeof(*shdrs), &pos);
	if (ret != ehdr.e_shnum * sizeof(*shdrs))
		goto out;

	/* Read section header string table */
	if (ehdr.e_shstrndx >= ehdr.e_shnum)
		goto out;

	shstrtab_size = shdrs[ehdr.e_shstrndx].sh_size;
	shstrtab = kmalloc(shstrtab_size, GFP_KERNEL);
	if (!shstrtab)
		goto out;

	pos = shdrs[ehdr.e_shstrndx].sh_offset;
	ret = kernel_read(file, shstrtab, shstrtab_size, &pos);
	if (ret != shstrtab_size)
		goto out;

	/* Find .symtab or .dynsym and their string tables */
	for (i = 0; i < ehdr.e_shnum; i++) {
		if (shdrs[i].sh_type != SHT_SYMTAB &&
		    shdrs[i].sh_type != SHT_DYNSYM)
			continue;

		/* Get the associated string table */
		if (shdrs[i].sh_link >= ehdr.e_shnum)
			continue;

		strtab_size = shdrs[shdrs[i].sh_link].sh_size;
		strtab = kmalloc(strtab_size, GFP_KERNEL);
		if (!strtab)
			continue;

		pos = shdrs[shdrs[i].sh_link].sh_offset;
		ret = kernel_read(file, strtab, strtab_size, &pos);
		if (ret != strtab_size) {
			kfree(strtab);
			strtab = NULL;
			continue;
		}

		/* Read symbol table */
		symtab_size = shdrs[i].sh_size;
		symtab = kmalloc(symtab_size, GFP_KERNEL);
		if (!symtab) {
			kfree(strtab);
			strtab = NULL;
			continue;
		}

		pos = shdrs[i].sh_offset;
		ret = kernel_read(file, symtab, symtab_size, &pos);
		if (ret != symtab_size) {
			kfree(symtab);
			kfree(strtab);
			symtab = NULL;
			strtab = NULL;
			continue;
		}

		/* Search for the symbol */
		symcount = symtab_size / sizeof(struct elf64_sym);
		for (j = 0; j < symcount; j++) {
			if (symtab[j].st_name >= strtab_size)
				continue;

			if (strcmp(&strtab[symtab[j].st_name], symbol_name) == 0) {
				/* Found it - return the value (offset) */
				offset = symtab[j].st_value;
				kfree(symtab);
				kfree(strtab);
				goto out;
			}
		}

		kfree(symtab);
		kfree(strtab);
		symtab = NULL;
		strtab = NULL;
	}

out:
	kfree(shstrtab);
	kfree(shdrs);
	return offset;
}

/* ============================================================
 * Uprobe Registration
 * ============================================================ */

/*
 * Register a uprobe for a target.
 * Caller must hold speed_bump_mutex.
 */
int speed_bump_register_uprobe(struct speed_bump_target *target)
{
	struct path path;
	struct file *file;
	int ret;

	if (target->registered)
		return 0;

	/* Resolve the path */
	ret = kern_path(target->path, LOOKUP_FOLLOW, &path);
	if (ret)
		return ret;

	/* Get inode */
	target->inode = igrab(d_inode(path.dentry));
	path_put(&path);

	if (!target->inode)
		return -ENOENT;

	/* Resolve symbol to offset */
	file = filp_open(target->path, O_RDONLY, 0);
	if (IS_ERR(file)) {
		iput(target->inode);
		target->inode = NULL;
		return PTR_ERR(file);
	}

	target->offset = resolve_symbol_offset(file, target->symbol);
	filp_close(file, NULL);

	if (target->offset == 0) {
		iput(target->inode);
		target->inode = NULL;
		return -ENOENT;
	}

	/* Set up uprobe consumer */
	target->uc.handler = speed_bump_uprobe_handler;
	target->uc.ret_handler = NULL;

	/* Register the uprobe (ref_ctr_offset = 0 means no semaphore) */
	target->uprobe = uprobe_register(target->inode, target->offset, 0,
					 &target->uc);
	if (IS_ERR(target->uprobe)) {
		int err = PTR_ERR(target->uprobe);
		target->uprobe = NULL;
		iput(target->inode);
		target->inode = NULL;
		return err;
	}

	target->registered = true;
	return 0;
}

/*
 * Unregister a uprobe for a target.
 * Caller must hold speed_bump_mutex.
 */
void speed_bump_unregister_uprobe(struct speed_bump_target *target)
{
	if (!target->registered)
		return;

	uprobe_unregister_nosync(target->uprobe, &target->uc);
	uprobe_unregister_sync();
	target->uprobe = NULL;
	iput(target->inode);
	target->inode = NULL;
	target->registered = false;
}
