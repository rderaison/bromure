// SPDX-License-Identifier: GPL-2.0
/*
 * bromure_zeropages — zero the guest's freed pages so macOS can compress them.
 *
 * WHY NOT THE OBVIOUS THINGS (all three were tried and measured):
 *
 *   init_on_free=1 on the cmdline works but zeroes all of RAM while freeing
 *   memblock to the buddy allocator, so every page is touched before userspace
 *   starts (4.2 GB host footprint on a 4 GB VM).
 *
 *   Flipping the init_on_free static key AFTER boot keeps boot memory
 *   untouched -- and CORRUPTS USERSPACE. post_alloc_hook() computes
 *
 *       init = !want_init_on_free() && want_init_on_alloc(gfp) && ...
 *
 *   so once that key is on, the allocator stops zeroing on allocation,
 *   including for __GFP_ZERO: it is entitled to assume every free page is
 *   already zero. Pages freed BEFORE the flip still hold data, so processes
 *   receive garbage "zeroed" pages -- measured as every new process taking
 *   SIGSEGV, and it is a cross-process data leak as well. Never do this.
 *
 *   Page reporting cannot be used to find the dirty pages either: on VZ a
 *   guest READ of a page the guest never used commits a host page (measured:
 *   1.0 GB -> 4.15 GB within 20 s of a read-only sweep). So nothing may even
 *   look at memory the guest has not used.
 *
 * WHAT THIS DOES
 *
 *   Probes the mm_page_free tracepoint and zeroes the pages being freed. That
 *   tracepoint fires from free_pages_prepare(), which is the single path every
 *   buddy free goes through (pcp, bulk, __free_pages_ok) -- the very place the
 *   kernel's own kernel_init_pages() runs when init_on_free is set. So this is
 *   init_on_free's zeroing, at init_on_free's own point, WITHOUT touching the
 *   key -- which means post_alloc_hook keeps zeroing on allocation and the
 *   allocator's assumption is never broken.
 *
 * WHY IT CANNOT TOUCH NEVER-USED MEMORY
 *
 *   Two independent reasons, and the second is the load-bearing one:
 *
 *   1. A page the guest never used is never freed, so the probe never sees it.
 *      Boot's memblock release does fire this tracepoint, but that happened
 *      before this module loaded.
 *   2. CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y: post_alloc_hook zeroes every page at
 *      ALLOCATION, so every page that can reach a free has already been
 *      written, and is therefore already resident on the host. Zeroing it
 *      commits nothing new -- it only makes an already-committed page
 *      compressible.
 *
 *   If init_on_alloc is ever turned off in this image, reason 2 lapses and a
 *   page could be allocated, never written, freed, and zeroed by us -- which
 *   would dirty a host page. The module refuses to load in that case.
 */

#include <linux/atomic.h>
#include <linux/debugfs.h>
#include <linux/init.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/page-flags.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/tracepoint.h>

#ifdef CONFIG_HIGHMEM
#error "bromure_zeropages assumes every page is in the linear map (arm64/x86_64)"
#endif

static char *mode = "free";
module_param(mode, charp, 0444);
MODULE_PARM_DESC(mode, "free (zero pages as they are freed) or off");

static bool dry_run;
module_param(dry_run, bool, 0644);
MODULE_PARM_DESC(dry_run, "count what would be zeroed, write nothing");

static bool force;
module_param(force, bool, 0444);
MODULE_PARM_DESC(force, "load even without init_on_alloc (UNSAFE: may dirty never-written host pages)");

static atomic64_t pages_zeroed, bytes_zeroed, calls, skipped_poison;

static struct tracepoint *free_tp;
static struct dentry *debug_dir;

/*
 * Runs from free_pages_prepare() with preemption disabled, from any context
 * including hard IRQ -- so no sleeping and no cond_resched() here. A memset of
 * up to (PAGE_SIZE << MAX_PAGE_ORDER) is the same work the kernel itself does
 * at this point under init_on_free, which is what makes it acceptable.
 */
static void bz_probe_free(void *data, struct page *page, unsigned int order)
{
	void *va;

	atomic64_inc(&calls);

	if (unlikely(!page))
		return;

	/*
	 * The tracepoint fires BEFORE free_pages_prepare() decides. A hwpoisoned
	 * page is not actually freed (it returns false to keep it off the
	 * freelists), and writing known-bad memory is how you turn a contained
	 * fault into a machine check.
	 */
	if (unlikely(PageHWPoison(page))) {
		atomic64_inc(&skipped_poison);
		return;
	}

	va = page_address(page);
	if (unlikely(!va))
		return;

	if (!READ_ONCE(dry_run))
		memset(va, 0, PAGE_SIZE << order);

	atomic64_add(1UL << order, &pages_zeroed);
	atomic64_add(PAGE_SIZE << order, &bytes_zeroed);
}

static void bz_find_tp(struct tracepoint *tp, void *priv)
{
	if (!free_tp && !strcmp(tp->name, "mm_page_free"))
		free_tp = tp;
}

static int bz_stats_show(struct seq_file *m, void *v)
{
	seq_printf(m,
		   "mode            %s\n"
		   "dry_run         %d\n"
		   "init_on_alloc   %d\n"
		   "init_on_free    %d   (must be 0: see the header)\n"
		   "frees_seen      %lld\n"
		   "pages_zeroed    %lld\n"
		   "bytes_zeroed    %lld\n"
		   "skipped_poison  %lld\n",
		   mode, dry_run,
		   want_init_on_alloc(0), want_init_on_free(),
		   atomic64_read(&calls),
		   atomic64_read(&pages_zeroed),
		   atomic64_read(&bytes_zeroed),
		   atomic64_read(&skipped_poison));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(bz_stats);

static int __init bz_init(void)
{
	int err;

	if (!strcmp(mode, "initfree")) {
		pr_err("bromure_zeropages: mode=initfree is REMOVED -- flipping the init_on_free key after boot makes the allocator skip zeroing on allocation and hands userspace garbage. See the header.\n");
		return -EINVAL;
	}
	if (!strcmp(mode, "off"))
		return 0;
	if (strcmp(mode, "free")) {
		pr_err("bromure_zeropages: unknown mode '%s'\n", mode);
		return -EINVAL;
	}

	/* Reason 2 in the header: without init_on_alloc a page can reach us
	 * never having been written, and zeroing it would cost a host page. */
	/*
	 * want_init_on_alloc(0), not (__GFP_ZERO): with __GFP_ZERO it returns
	 * true whatever the key, so this check would never see init_on_alloc=0
	 * (which Settings > Hardware > Kernel Boot Options can set).
	 */
	if (!want_init_on_alloc(0) && !force) {
		pr_err("bromure_zeropages: init_on_alloc is off, so a freed page may never have been written; zeroing it would dirty a host page. Boot with init_on_alloc=1, or load with force=1 if you have measured that this is acceptable.\n");
		return -EOPNOTSUPP;
	}
	if (want_init_on_free())
		pr_warn("bromure_zeropages: init_on_free is already on; this module is redundant and the kernel has already touched all of RAM.\n");

	for_each_kernel_tracepoint(bz_find_tp, NULL);
	if (!free_tp) {
		pr_err("bromure_zeropages: tracepoint mm_page_free not found\n");
		return -ENOENT;
	}

	err = tracepoint_probe_register(free_tp, (void *)bz_probe_free, NULL);
	if (err) {
		pr_err("bromure_zeropages: tracepoint_probe_register: %d\n", err);
		free_tp = NULL;
		return err;
	}

	debug_dir = debugfs_create_dir("bromure_zeropages", NULL);
	debugfs_create_file("stats", 0444, debug_dir, NULL, &bz_stats_fops);

	pr_info("bromure_zeropages: zeroing freed pages (dry_run=%d)\n", dry_run);
	return 0;
}

static void __exit bz_exit(void)
{
	debugfs_remove_recursive(debug_dir);
	if (free_tp) {
		tracepoint_probe_unregister(free_tp, (void *)bz_probe_free, NULL);
		/* Probes can still be running on other CPUs until this returns. */
		tracepoint_synchronize_unregister();
	}
	pr_info("bromure_zeropages: unloaded\n");
}

module_init(bz_init);
module_exit(bz_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Zero freed guest pages so the macOS compressor can reclaim them");
MODULE_VERSION("2.0");
