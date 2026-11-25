/*
 * honor_boost.ko - Runtime RAM-only GKI 6.18.21-android17-5 kernel monkey-patch LKM
 * Target: Honor Magic 9 Pro Max (SM8975 / Adreno 850, 6.18.21-android17-5-4k)
 *
 * Pure RAM load (never modifies /boot or locked-bootloader partitions; never auto-loaded
 * on boot; cleanly unloadable via `rmmod honor_boost`).
 *
 * Hardened Hooks (all gated by /sys/module/honor_boost/parameters/*; default SAFE/OBSERVE):
 *   1. gen8_hwsched_gmu_based_dcvs_pwr_ops [msm_kgsl]:
 *        - Verified in init_module() by checking live ARM64 opcodes before registering:
 *            max_pwrlevel_show + 0x20 == 0xb9730903 (ldr w3, [x8, #0x3308])
 *            gen8_hwsched_gmu_based_dcvs_pwr_ops + 0x84 == 0xb9731408 (ldr w8, [x0, #0x3314])
 *          If an Honor vendor_dlkm OTA moves these offsets, the KGSL hook refuses to enable!
 *        - gpu_unclamp=1: intercepts op==2 (max_pwrlevel_store, called under device rt_mutex)
 *          only — lifts Honor's software max_pwrlevel cap (>0 -> 0 = 1450 MHz) before GMU HFI.
 *          Leaves op==0 (thermal_pwrlevel) and op==1 (min_pwrlevel) completely untouched.
 *   2. freq_qos_update_request [vmlinux]:
 *        - Caller-allowlisted via live return address (regs->regs[30] / LR):
 *          ONLY lifts FREQ_QOS_MAX requests originating from Honor software limiters:
 *            * set_frame_freq_max_v1 [honor_fas]
 *            * set_frame_freq_max    [honor_fas]
 *            * set_cpu_max_freq      [msm_performance]
 *          GKI cpufreq_cooling (cpufreq_set_cur_state), Qualcomm qti_cpufreq_cdev,
 *          Honor hn_shell_temp, user scaling_max_freq writes, hardware CPUCP/LMh, and all
 *          non-CPU freq_constraints stay 100% UNTOUCHED!
 *   3. udmabuf_create [vmlinux]:
 *        - Read-only telemetry counter for Venus / Wayland / crosvm zero-copy DMA-BUF creates.
 *
 * Built with native clang `-fsanitize=kcfi -fsanitize-cfi-icall-experimental-normalize-integers
 * -mbranch-protection=pac-ret+bti -ffixed-x18 -fno-stack-protector`.
 */

typedef unsigned char      u8;
typedef signed char        s8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef signed int         s32;
typedef unsigned long      u64;
typedef unsigned long      size_t;

#define NULL   ((void *)0)
#define ENODEV 19
#define KERN_INFO "\0016"
#define KERN_WARN "\0014"

/* Exact GKI 6.18.21-android17-5 struct layouts verified via pahole on /sys/kernel/btf/vmlinux */
struct pt_regs {
    u64 regs[31];
    u64 sp;
    u64 pc;
    u64 pstate;
    u64 orig_x0;
    s32 syscallno;
    u32 pmr;
    u64 sdei_ttbr1;
};

struct kprobe;
typedef int (*kprobe_pre_handler_t)(struct kprobe *, struct pt_regs *);
typedef void (*kprobe_post_handler_t)(struct kprobe *, struct pt_regs *, unsigned long);

/* sizeof(struct kprobe) == 120 */
struct kprobe {
    void                 *hlist_next;   /*   0 */
    void                 *hlist_pprev;  /*   8 */
    void                 *list_next;    /*  16 */
    void                 *list_prev;    /*  24 */
    unsigned long         nmissed;      /*  32 */
    u32                  *addr;         /*  40 */
    const char           *symbol_name;  /*  48 */
    unsigned int          offset;       /*  56 */
    u32                   _pad0;        /*  60 */
    kprobe_pre_handler_t  pre_handler;  /*  64 */
    kprobe_post_handler_t post_handler; /*  72 */
    u32                   opcode;       /*  80 */
    u32                   _pad1;        /*  84 */
    u64                   ainsn[3];     /*  88..111 */
    u32                   flags;        /* 112 */
    u32                   _pad2;        /* 116 */
};

/* sizeof(struct kernel_param) == 40 */
struct kernel_param_ops;
struct module;
struct kernel_param {
    const char                     *name;  /*  0 */
    struct module                  *mod;   /*  8 */
    const struct kernel_param_ops  *ops;   /* 16 */
    const u16                       perm;  /* 24 */
    s8                              level; /* 26 */
    u8                              flags; /* 27 */
    u32                             _pad;  /* 28 */
    void                           *arg;   /* 32 */
};

/* sizeof(struct module) == 0x680 (1664), name @ +0x18, init @ +0x178, exit @ +0x600 */
struct module_stub {
    u8    pad0[0x18];
    char  name[56];
    u8    pad1[0x178 - 0x18 - 56];
    int (*init)(void);
    u8    pad2[0x600 - 0x178 - 8];
    void (*exit)(void);
    u8    pad3[0x680 - 0x600 - 8];
};

/* External GKI 6.18.21 exported kernel symbols (exact CRCs in __versions) */
extern int _printk(const char *fmt, ...);
extern int register_kprobe(struct kprobe *p);
extern void unregister_kprobe(struct kprobe *p);
extern const struct kernel_param_ops param_ops_uint;

/* Module control parameters & live telemetry counters (/sys/module/honor_boost/parameters/*) */
static u32 gpu_unclamp       = 0;   /* 1 = clear KGSL software max_pwrlevel (op==2 only) */
static u32 cpu_unclamp_khz   = 0;   /* >0 (<= 10000000) = ceiling floor for allowlisted Honor callers */

static u32 kgsl_hits         = 0;
static u32 kgsl_clamps       = 0;
static u32 kgsl_verified     = 0;   /* 1 = live msm_kgsl.ko opcodes matched reviewed build */
static u32 fq_hits           = 0;
static u32 fq_lifted         = 0;
static u32 fq_thermal_skip   = 0;   /* count of non-allowlisted / thermal callers left untouched */
static u32 udmabuf_hits      = 0;

/* Active registration flags */
static u8 kp_kgsl_ok         = 0;
static u8 kp_fq_ok           = 0;
static u8 kp_udmabuf_ok      = 0;

/* Caller allowlist ranges resolved at init_module() via kprobe symbol lookup */
static u64 allow_fas_v1_addr = 0;
static u64 allow_fas_v2_addr = 0;
static u64 allow_mperf_addr  = 0;

/* Verified KGSL offsets & expected live ARM64 opcodes from phone's msm_kgsl.ko */
#define KGSL_OFF_MAX_PWRLEVEL          0x3308UL
#define KGSL_OFF_NUM_PWRLEVELS         0x3314UL
#define EXPECTED_INSN_MAX_PL_SHOW_20   0xb9730903U /* ldr w3, [x8, #0x3308] */
#define EXPECTED_INSN_GEN8_DCVS_84     0xb9731408U /* ldr w8, [x0, #0x3314] */

#define FREQ_QOS_MAX                   2U
#define MAX_VALID_KHZ                  10000000U
#define KERNEL_VA_FLOOR                0xffffff8000000000UL

static u64 resolve_sym_addr(const char *sym_name) {
    struct kprobe tmp = { 0 };
    tmp.symbol_name = sym_name;
    if (register_kprobe(&tmp) != 0) {
        return 0;
    }
    u64 addr = (u64)tmp.addr;
    unregister_kprobe(&tmp);
    return addr;
}

static int in_range(u64 addr, u64 base, u64 span) {
    return (base != 0ULL) && (addr >= base) && (addr < base + span);
}

/* --- Hook 1: Adreno 850 Gen8 GMU DCVS gateway gen8_hwsched_gmu_based_dcvs_pwr_ops(dev, val, op) --- */
__attribute__((used, noinline))
int kp_kgsl_pre(struct kprobe *p, struct pt_regs *regs) {
    (void)p;
    __atomic_fetch_add(&kgsl_hits, 1, __ATOMIC_RELAXED);

    if (!__atomic_load_n(&gpu_unclamp, __ATOMIC_RELAXED) || !kgsl_verified) {
        return 0;
    }

    u32 op = (u32)regs->regs[2];
    /* op == 2 ONLY (max_pwrlevel_store, called under device rt_mutex at +0x5818).
     * Never touch op==0 (thermal_pwrlevel) or op==1 (min_pwrlevel). */
    if (op != 2U) {
        return 0;
    }

    u64 dev = regs->regs[0];
    if (dev < KERNEL_VA_FLOOR) {
        return 0;
    }

    /* Validate num_pwrlevels at verified offset 0x3314 (Adreno 850 has 26 levels -> max_idx=25) */
    u32 num_pl = *(volatile u32 *)(dev + KGSL_OFF_NUM_PWRLEVELS);
    if (num_pl < 6U || num_pl > 41U) {
        return 0;
    }

    u32 val = (u32)regs->regs[1];
    if (val > 0U && val < num_pl) {
        regs->regs[1] = 0ULL;
        *(volatile u32 *)(dev + KGSL_OFF_MAX_PWRLEVEL) = 0U;
        __atomic_fetch_add(&kgsl_clamps, 1, __ATOMIC_RELAXED);
    }
    return 0;
}

/* --- Hook 2: freq_qos_update_request(struct freq_qos_request *req, s32 new_value) --- */
__attribute__((used, noinline))
int kp_fq_pre(struct kprobe *p, struct pt_regs *regs) {
    (void)p;
    __atomic_fetch_add(&fq_hits, 1, __ATOMIC_RELAXED);

    u32 target_khz = __atomic_load_n(&cpu_unclamp_khz, __ATOMIC_RELAXED);
    if (target_khz == 0U) {
        return 0;
    }
    if (target_khz > MAX_VALID_KHZ) {
        target_khz = MAX_VALID_KHZ;
    }

    u64 req_ptr = regs->regs[0];
    if (req_ptr < KERNEL_VA_FLOOR) {
        return 0;
    }

    /* struct freq_qos_request.type is u32 at offset 0 (FREQ_QOS_MAX == 2) */
    if (*(volatile u32 *)req_ptr != FREQ_QOS_MAX) {
        return 0;
    }

    /* Strict caller allowlist via LR (regs[30]): ONLY Honor FAS & msm_performance caps.
     * Leaves cpufreq_cooling, qti_cpufreq_cdev, hn_shell_temp, user scaling_max_freq,
     * and all non-CPU freq_constraints 100% untouched. */
    u64 lr = regs->regs[30];
    int is_honor_caller =
        in_range(lr, allow_fas_v1_addr, 0x240UL) ||
        in_range(lr, allow_fas_v2_addr, 0x2c0UL) ||
        in_range(lr, allow_mperf_addr,  0x400UL);

    if (!is_honor_caller) {
        __atomic_fetch_add(&fq_thermal_skip, 1, __ATOMIC_RELAXED);
        return 0;
    }

    s32 new_val = (s32)regs->regs[1];
    if (new_val > 100000 && (u32)new_val < target_khz) {
        regs->regs[1] = (u64)target_khz;
        __atomic_fetch_add(&fq_lifted, 1, __ATOMIC_RELAXED);
    }
    return 0;
}

/* --- Hook 3: udmabuf_create (Venus / Wayland / crosvm zero-copy DMA-BUF telemetry) --- */
__attribute__((used, noinline))
int kp_udmabuf_pre(struct kprobe *p, struct pt_regs *regs) {
    (void)p;
    (void)regs;
    __atomic_fetch_add(&udmabuf_hits, 1, __ATOMIC_RELAXED);
    return 0;
}

static struct kprobe kp_kgsl = {
    .symbol_name = "gen8_hwsched_gmu_based_dcvs_pwr_ops",
    .pre_handler = kp_kgsl_pre,
};

static struct kprobe kp_fq = {
    .symbol_name = "freq_qos_update_request",
    .pre_handler = kp_fq_pre,
};

static struct kprobe kp_udmabuf = {
    .symbol_name = "udmabuf_create",
    .pre_handler = kp_udmabuf_pre,
};

__attribute__((section(".init.text"), used, noinline))
int init_module(void) {
    int r1 = -ENODEV, r2 = -ENODEV, r3 = -ENODEV;

    /* 1. OTA-safety verification of live msm_kgsl.ko opcodes before enabling KGSL hook */
    u64 show_addr = resolve_sym_addr("max_pwrlevel_show");
    u64 dcvs_addr = resolve_sym_addr("gen8_hwsched_gmu_based_dcvs_pwr_ops");
    if (show_addr >= KERNEL_VA_FLOOR && dcvs_addr >= KERNEL_VA_FLOOR) {
        u32 insn_max = *(volatile u32 *)(show_addr + 0x20UL);
        u32 insn_num = *(volatile u32 *)(dcvs_addr + 0x84UL);
        if (insn_max == EXPECTED_INSN_MAX_PL_SHOW_20 &&
            insn_num == EXPECTED_INSN_GEN8_DCVS_84) {
            kgsl_verified = 1;
            r1 = register_kprobe(&kp_kgsl);
            if (r1 == 0) kp_kgsl_ok = 1;
        } else {
            _printk(KERN_WARN "honor_boost: msm_kgsl opcode mismatch (0x%08x/0x%08x) — KGSL hook disabled\n",
                    insn_max, insn_num);
        }
    }

    /* 2. Resolve Honor software CPU cap callers (leave thermal cooling untouched) */
    allow_fas_v1_addr = resolve_sym_addr("set_frame_freq_max_v1");
    allow_fas_v2_addr = resolve_sym_addr("set_frame_freq_max");
    allow_mperf_addr  = resolve_sym_addr("set_cpu_max_freq");
    if (allow_fas_v1_addr || allow_fas_v2_addr || allow_mperf_addr) {
        r2 = register_kprobe(&kp_fq);
        if (r2 == 0) kp_fq_ok = 1;
    }

    /* 3. Zero-copy DMA-BUF telemetry */
    r3 = register_kprobe(&kp_udmabuf);
    if (r3 == 0) kp_udmabuf_ok = 1;

    if (!kp_kgsl_ok && !kp_fq_ok && !kp_udmabuf_ok) {
        _printk(KERN_WARN "honor_boost: no hooks registered, aborting load\n");
        return -ENODEV;
    }

    _printk(KERN_INFO "honor_boost: loaded (kgsl=%d[ver=%u] fq=%d[callers=%u] udmabuf=%d)\n",
            r1, kgsl_verified, r2,
            (u32)((allow_fas_v1_addr != 0) + (allow_fas_v2_addr != 0) + (allow_mperf_addr != 0)),
            r3);
    return 0;
}

__attribute__((section(".exit.text"), used, noinline))
void cleanup_module(void) {
    if (kp_udmabuf_ok) {
        unregister_kprobe(&kp_udmabuf);
        kp_udmabuf_ok = 0;
    }
    if (kp_fq_ok) {
        unregister_kprobe(&kp_fq);
        kp_fq_ok = 0;
    }
    if (kp_kgsl_ok) {
        unregister_kprobe(&kp_kgsl);
        kp_kgsl_ok = 0;
    }
    _printk(KERN_INFO "honor_boost: unloaded (kgsl=%u/%u fq=%u/%u/skip=%u udmabuf=%u)\n",
            kgsl_hits, kgsl_clamps, fq_hits, fq_lifted, fq_thermal_skip, udmabuf_hits);
}

/* --- __this_module (exact 0x680-byte struct module layout) --- */
__attribute__((section(".gnu.linkonce.this_module"), used, aligned(64)))
struct module_stub __this_module = {
    .name = "honor_boost",
    .init = init_module,
    .exit = cleanup_module,
};

/* --- Sysfs module parameters (/sys/module/honor_boost/parameters/*) --- */
#define DEF_PARAM_UINT(pname, var, mode) \
    static const char __param_str_##pname[] __attribute__((section(".rodata"), aligned(1))) = #pname; \
    static const struct kernel_param __param_##pname __attribute__((section("__param"), used, aligned(8))) = { \
        .name  = __param_str_##pname, \
        .mod   = (struct module *)&__this_module, \
        .ops   = &param_ops_uint, \
        .perm  = (mode), \
        .level = -1, \
        .flags = 0, \
        .arg   = &(var), \
    }

DEF_PARAM_UINT(gpu_unclamp,     gpu_unclamp,     0644);
DEF_PARAM_UINT(cpu_unclamp_khz, cpu_unclamp_khz, 0644);
DEF_PARAM_UINT(kgsl_verified,   kgsl_verified,   0444);
DEF_PARAM_UINT(kgsl_hits,       kgsl_hits,       0444);
DEF_PARAM_UINT(kgsl_clamps,     kgsl_clamps,     0444);
DEF_PARAM_UINT(fq_hits,         fq_hits,         0444);
DEF_PARAM_UINT(fq_lifted,       fq_lifted,       0444);
DEF_PARAM_UINT(fq_thermal_skip, fq_thermal_skip, 0444);
DEF_PARAM_UINT(udmabuf_hits,    udmabuf_hits,    0444);

/* --- .modinfo --- */
#define MODINFO_ENTRY(tag, str) \
    static const char __modinfo_##tag[] __attribute__((section(".modinfo"), used, aligned(1))) = str

MODINFO_ENTRY(license,  "license=GPL");
MODINFO_ENTRY(author,   "author=debian-adreno850-desktop");
MODINFO_ENTRY(desc,     "description=Runtime RAM-only KGSL/Honor-FAS/DMA-BUF kprobe boost & telemetry");
MODINFO_ENTRY(name,     "name=honor_boost");
MODINFO_ENTRY(depends,  "depends=");
MODINFO_ENTRY(vermagic, "vermagic=6.18.21-android17-5-gfee2325de189-abogki572422516-4k SMP preempt mod_unload modversions aarch64");

/* --- Exact GKI 6.18.21-android17-5 symbol CRCs (verified against phone's honor_lock.ko & zram.ko) --- */
struct modversion_info {
    u64  crc;
    char name[56];
};

__attribute__((section("__versions"), used, aligned(8)))
static const struct modversion_info ____versions[] = {
    { 0x60801db3ULL, "module_layout" },
    { 0x16b5b21dULL, "_printk" },
    { 0x100f01eaULL, "register_kprobe" },
    { 0x7ec06b6bULL, "unregister_kprobe" },
    { 0xae2dbea2ULL, "param_ops_uint" },
};

__attribute__((section("__version_ext_crcs"), used, aligned(4)))
static const u32 ____version_ext_crcs[] = {
    0x60801db3U,
    0x16b5b21dU,
    0x100f01eaU,
    0x7ec06b6bU,
    0xae2dbea2U,
};

__attribute__((section("__version_ext_names"), used, aligned(1)))
static const char ____version_ext_names[] =
    "module_layout\0"
    "_printk\0"
    "register_kprobe\0"
    "unregister_kprobe\0"
    "param_ops_uint\0";
