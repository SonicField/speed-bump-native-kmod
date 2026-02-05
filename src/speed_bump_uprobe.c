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
#include <linux/version.h>
#include <linux/sched.h>
#include <linux/rcupdate.h>

#include "speed_bump.h"
#include "speed_bump_internal.h"

/* ============================================================
 * Uprobe Handler
 * ============================================================ */

/*
 * Uprobe handler called when a probed function is entered.
 * Executes the spin delay configured for this target.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,13,0)
static int speed_bump_uprobe_handler(struct uprobe_consumer *uc,
				     struct pt_regs *regs,
				     __u64 *data)
#else
static int speed_bump_uprobe_handler(struct uprobe_consumer *uc,
				     struct pt_regs *regs)
#endif
{
	struct speed_bump_target *target;

	if (!atomic_read(&speed_bump_enabled))
		return 0;

	target = container_of(uc, struct speed_bump_target, uc);

	/* Check PID filter if set */
	if (target->pid_filter != 0) {
		struct task_struct *task = current;
		bool match = false;

		/* Walk up the process tree to find a match */
		rcu_read_lock();
		while (task->pid != 1) {  /* Stop at init */
			if (task->tgid == target->pid_filter) {
				match = true;
				break;
			}
			task = rcu_dereference(task->real_parent);
		}
		rcu_read_unlock();

		if (!match)
			return 0;  /* Not in target process tree, skip delay */
	}

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
 * Convert a virtual address to a file offset using ELF program headers.
 * Returns the file offset on success, 0 on failure.
 */
static loff_t vaddr_to_file_offset(struct file *file,
				   const struct elf64_hdr *ehdr,
				   Elf64_Addr vaddr)
{
	struct elf64_phdr *phdrs = NULL;
	loff_t file_offset = 0;
	loff_t pos;
	ssize_t ret;
	int i;

	if (ehdr->e_phnum == 0)
		return 0;

	/* Allocate and read program headers */
	phdrs = kmalloc_array(ehdr->e_phnum, sizeof(*phdrs), GFP_KERNEL);
	if (!phdrs)
		return 0;

	pos = ehdr->e_phoff;
	ret = kernel_read(file, phdrs, ehdr->e_phnum * sizeof(*phdrs), &pos);
	if (ret != ehdr->e_phnum * sizeof(*phdrs))
		goto out;

	/* Find PT_LOAD segment containing this virtual address */
	for (i = 0; i < ehdr->e_phnum; i++) {
		if (phdrs[i].p_type != PT_LOAD)
			continue;

		if (vaddr >= phdrs[i].p_vaddr &&
		    vaddr < phdrs[i].p_vaddr + phdrs[i].p_filesz) {
			file_offset = phdrs[i].p_offset +
				      (vaddr - phdrs[i].p_vaddr);
			break;
		}
	}

out:
	kfree(phdrs);
	return file_offset;
}

/*
 * Read ELF symbol table and find the file offset for a symbol.
 * Returns the symbol's file offset on success, 0 on failure.
 *
 * Note: Symbol st_value is a virtual address; we convert it to a file
 * offset using the program headers since uprobe_register() expects
 * a file offset.
 */
static loff_t resolve_symbol_offset(struct file *file,
				    const char *symbol_name)
{
	struct elf64_hdr ehdr;
	struct elf64_shdr *shdrs = NULL;
	char *shstrtab = NULL;
	char *strtab = NULL;
	struct elf64_sym *symtab = NULL;
	Elf64_Addr sym_vaddr = 0;
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
				/* Found symbol - get virtual address */
				sym_vaddr = symtab[j].st_value;
				kfree(symtab);
				kfree(strtab);
				goto convert_offset;
			}
		}

		kfree(symtab);
		kfree(strtab);
		symtab = NULL;
		strtab = NULL;
	}

convert_offset:
	/* Convert virtual address to file offset using program headers */
	if (sym_vaddr != 0)
		offset = vaddr_to_file_offset(file, &ehdr, sym_vaddr);

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
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,12,0)
	/* Kernel 6.12+: returns struct uprobe *, 4 args with ref_ctr_offset */
	target->uprobe = uprobe_register(target->inode, target->offset, 0,
					 &target->uc);
	if (IS_ERR(target->uprobe)) {
		int err = PTR_ERR(target->uprobe);
		target->uprobe = NULL;
		iput(target->inode);
		target->inode = NULL;
		return err;
	}
#else
	/* Kernel <6.12: returns int, 3 args (no ref_ctr_offset) */
	{
		int err = uprobe_register(target->inode, target->offset,
					  &target->uc);
		if (err) {
			iput(target->inode);
			target->inode = NULL;
			return err;
		}
		target->uprobe = NULL;  /* Not returned by this API */
	}
#endif

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

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,12,0)
	/* Kernel 6.12+: two-phase unregister */
	uprobe_unregister_nosync(target->uprobe, &target->uc);
	uprobe_unregister_sync();
#else
	/* Kernel <6.12: single-call unregister with inode/offset */
	uprobe_unregister(target->inode, target->offset, &target->uc);
#endif
	target->uprobe = NULL;
	iput(target->inode);
	target->inode = NULL;
	target->registered = false;
}
