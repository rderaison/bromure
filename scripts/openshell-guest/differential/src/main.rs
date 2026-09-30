// Differential harness: OpenShell's REAL enforcement.
//
// `prepare`/`enforce` below are ported from the reference sources in
// openshell/sandbox-linux/{landlock,seccomp}.rs with only the OCSF emission and
// miette wrappers removed, and let-chains rewritten for rustc 1.75. Everything
// that touches the kernel — the `landlock` crate calls, the seccompiler rule
// map, the filter install order — is upstream's, unchanged.
//
// Protocol: one JSON job on stdin, one JSON result on stdout. ../diff.py feeds
// the identical job to the Python implementation and compares.

use landlock::{
    ABI, Access, AccessFs, BitFlags, CompatLevel, Compatible, PathBeneath, PathFd, Ruleset,
    RulesetAttr, RulesetCreatedAttr,
};
use seccompiler::{
    apply_filter, BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition,
    SeccompFilter, SeccompRule,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::convert::TryInto;
use std::os::fd::AsFd;
use std::path::PathBuf;

const SECCOMP_SET_MODE_FILTER: u64 = 1;

#[derive(Deserialize, Default, Clone)]
struct FilesystemPolicy {
    #[serde(default)]
    read_only: Vec<PathBuf>,
    #[serde(default)]
    read_write: Vec<PathBuf>,
    #[serde(default = "default_true")]
    include_workdir: bool,
}
fn default_true() -> bool {
    true
}

#[derive(Deserialize, Default, Clone)]
struct LandlockPolicy {
    #[serde(default)]
    compatibility: String,
}

#[derive(Deserialize, Clone)]
struct Job {
    #[serde(default)]
    filesystem_policy: Option<FilesystemPolicy>,
    #[serde(default)]
    landlock: Option<LandlockPolicy>,
    #[serde(default)]
    workdir: Vec<String>,
    #[serde(default)]
    probes: Vec<Probe>,
    #[serde(default)]
    apply_seccomp: bool,
    #[serde(default = "default_true")]
    allow_inet: bool,
}

#[derive(Deserialize, Clone)]
#[serde(tag = "kind")]
enum Probe {
    #[serde(rename = "fs")]
    Fs { op: String, path: String },
    #[serde(rename = "syscall")]
    Syscall { nr: i64, args: Vec<i64> },
}

#[derive(Serialize)]
struct Outcome {
    state: String,
    reason: Option<String>,
    rules_applied: usize,
    skipped: usize,
    abi: i32,
}

#[derive(Serialize)]
struct Output {
    prepare: Outcome,
    probes: Vec<String>,
}

fn is_hard(compat: &str) -> bool {
    compat == "hard_requirement"
}

fn compat_level(compat: &str) -> CompatLevel {
    if is_hard(compat) {
        CompatLevel::HardRequirement
    } else {
        CompatLevel::BestEffort
    }
}

fn probe_availability() -> i32 {
    const SYS_LANDLOCK_CREATE_RULESET: libc::c_long = 444;
    const LANDLOCK_CREATE_RULESET_VERSION: libc::c_uint = 1 << 0;
    let ret = unsafe {
        libc::syscall(
            SYS_LANDLOCK_CREATE_RULESET,
            std::ptr::null::<libc::c_void>(),
            0_usize,
            LANDLOCK_CREATE_RULESET_VERSION,
        )
    };
    ret as i32
}

/// landlock.rs::access_for_path_fd
fn access_for_path_fd(
    path_fd: &impl AsFd,
    requested: BitFlags<AccessFs>,
    abi: ABI,
) -> std::io::Result<BitFlags<AccessFs>> {
    let fd = path_fd.as_fd();
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::fstat(std::os::fd::AsRawFd::as_raw_fd(&fd), &mut stat) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(if stat.st_mode & libc::S_IFMT == libc::S_IFDIR {
        requested
    } else {
        requested & AccessFs::from_file(abi)
    })
}

/// landlock.rs::prepare_with_path_open_mode + enforce, fused (this process IS
/// the workload, so there is no fork between the two phases).
fn apply_landlock(job: &Job) -> Outcome {
    let abi_probe = probe_availability();
    let fs = match &job.filesystem_policy {
        // Bromure's divergence is implemented on the Python side only: here the
        // absent section is OpenShell's `Default::default()`, which the diff
        // driver exercises explicitly so the two behaviors stay distinguishable.
        None => FilesystemPolicy::default(),
        Some(fs) => fs.clone(),
    };
    let compat = job
        .landlock
        .as_ref()
        .map(|l| l.compatibility.clone())
        .unwrap_or_default();
    let compat = if compat.is_empty() {
        "best_effort".to_string()
    } else {
        compat
    };

    let read_only = fs.read_only.clone();
    let mut read_write = fs.read_write.clone();
    if fs.include_workdir {
        for dir in &job.workdir {
            let p = PathBuf::from(dir);
            if !read_write.contains(&p) {
                read_write.push(p);
            }
        }
    }
    if read_only.is_empty() && read_write.is_empty() {
        return Outcome {
            state: "off".into(),
            reason: Some("no paths configured".into()),
            rules_applied: 0,
            skipped: 0,
            abi: abi_probe,
        };
    }
    if abi_probe < 0 {
        if is_hard(&compat) {
            return Outcome {
                state: "failed".into(),
                reason: Some("landlock unavailable".into()),
                rules_applied: 0,
                skipped: 0,
                abi: abi_probe,
            };
        }
        return Outcome {
            state: "degraded".into(),
            reason: Some("landlock unavailable".into()),
            rules_applied: 0,
            skipped: 0,
            abi: abi_probe,
        };
    }

    let total_paths = read_only.len() + read_write.len();
    let abi = ABI::V3;
    let access_all = AccessFs::from_all(abi);
    let access_read = AccessFs::from_read(abi);

    let build = || -> Result<(landlock::RulesetCreated, usize), String> {
        let mut ruleset = Ruleset::default()
            .set_compatibility(compat_level(&compat))
            .handle_access(access_all)
            .map_err(|e| e.to_string())?
            .create()
            .map_err(|e| e.to_string())?;
        let mut rules_applied = 0usize;
        for (paths, access) in [(&read_only, access_read), (&read_write, access_all)] {
            for path in paths {
                let path_fd = match PathFd::new(path) {
                    Ok(fd) => fd,
                    Err(err) => {
                        if is_hard(&compat) {
                            return Err(format!(
                                "Landlock path unavailable in hard_requirement mode: {}: {err}",
                                path.display()
                            ));
                        }
                        continue;
                    }
                };
                let allowed =
                    access_for_path_fd(&path_fd, access, abi).map_err(|e| e.to_string())?;
                ruleset = ruleset
                    .add_rule(PathBeneath::new(path_fd, allowed))
                    .map_err(|e| e.to_string())?;
                rules_applied += 1;
            }
        }
        if rules_applied == 0 {
            return Err(format!(
                "Landlock ruleset has zero valid paths — all {total_paths} path(s) failed to open."
            ));
        }
        Ok((ruleset, rules_applied))
    };

    match build() {
        Err(err) => {
            if is_hard(&compat) {
                Outcome {
                    state: "failed".into(),
                    reason: Some(err),
                    rules_applied: 0,
                    skipped: 0,
                    abi: abi_probe,
                }
            } else {
                Outcome {
                    state: "degraded".into(),
                    reason: Some(err),
                    rules_applied: 0,
                    skipped: 0,
                    abi: abi_probe,
                }
            }
        }
        Ok((ruleset, rules_applied)) => {
            // no_new_privs first: OpenShell inherits it from the launcher
            // thread; here it has to be explicit or restrict_self gets EPERM.
            unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
            match ruleset.restrict_self() {
                Ok(_) => Outcome {
                    state: "enforced".into(),
                    reason: None,
                    rules_applied,
                    skipped: total_paths - rules_applied,
                    abi: abi_probe,
                },
                Err(err) => {
                    if is_hard(&compat) {
                        Outcome {
                            state: "failed".into(),
                            reason: Some(err.to_string()),
                            rules_applied,
                            skipped: 0,
                            abi: abi_probe,
                        }
                    } else {
                        Outcome {
                            state: "degraded".into(),
                            reason: Some(err.to_string()),
                            rules_applied,
                            skipped: 0,
                            abi: abi_probe,
                        }
                    }
                }
            }
        }
    }
}

// --- seccomp.rs, ported verbatim ---------------------------------------------

fn compile(
    rules: BTreeMap<i64, Vec<SeccompRule>>,
    blocked: SeccompAction,
) -> Result<BpfProgram, String> {
    let arch = std::env::consts::ARCH
        .try_into()
        .map_err(|_| "unsupported arch".to_string())?;
    let filter = SeccompFilter::new(rules, SeccompAction::Allow, blocked, arch)
        .map_err(|e| e.to_string())?;
    filter.try_into().map_err(|e: seccompiler::BackendError| e.to_string())
}

fn add_socket_domain_rule(rules: &mut BTreeMap<i64, Vec<SeccompRule>>, domain: i32) {
    let c = SeccompCondition::new(0, SeccompCmpArgLen::Dword, SeccompCmpOp::Eq, domain as u64)
        .unwrap();
    rules
        .entry(libc::SYS_socket)
        .or_default()
        .push(SeccompRule::new(vec![c]).unwrap());
}

fn add_masked_arg_rule(
    rules: &mut BTreeMap<i64, Vec<SeccompRule>>,
    syscall: i64,
    arg_index: u8,
    flag_bit: u64,
) {
    let c = SeccompCondition::new(
        arg_index,
        SeccompCmpArgLen::Dword,
        SeccompCmpOp::MaskedEq(flag_bit),
        flag_bit,
    )
    .unwrap();
    rules
        .entry(syscall)
        .or_default()
        .push(SeccompRule::new(vec![c]).unwrap());
}

fn build_filter_rules(allow_inet: bool) -> BTreeMap<i64, Vec<SeccompRule>> {
    let mut rules: BTreeMap<i64, Vec<SeccompRule>> = BTreeMap::new();
    let mut blocked_domains = vec![libc::AF_PACKET, libc::AF_BLUETOOTH, libc::AF_VSOCK];
    if !allow_inet {
        blocked_domains.push(libc::AF_INET);
        blocked_domains.push(libc::AF_INET6);
    }
    for domain in blocked_domains {
        add_socket_domain_rule(&mut rules, domain);
    }
    // AF_NETLINK except NETLINK_ROUTE
    let domain_condition = SeccompCondition::new(
        0,
        SeccompCmpArgLen::Dword,
        SeccompCmpOp::Eq,
        libc::AF_NETLINK as u64,
    )
    .unwrap();
    let protocol_condition =
        SeccompCondition::new(2, SeccompCmpArgLen::Dword, SeccompCmpOp::Ne, 0).unwrap();
    rules
        .entry(libc::SYS_socket)
        .or_default()
        .push(SeccompRule::new(vec![domain_condition, protocol_condition]).unwrap());

    for syscall in [
        libc::SYS_memfd_create,
        libc::SYS_ptrace,
        libc::SYS_bpf,
        libc::SYS_process_vm_readv,
        libc::SYS_process_vm_writev,
        libc::SYS_pidfd_getfd,
        libc::SYS_pidfd_send_signal,
        libc::SYS_io_uring_setup,
        libc::SYS_mount,
        libc::SYS_fsopen,
        libc::SYS_fsconfig,
        libc::SYS_fsmount,
        libc::SYS_fspick,
        libc::SYS_move_mount,
        libc::SYS_open_tree,
        libc::SYS_setns,
        libc::SYS_umount2,
        libc::SYS_pivot_root,
        libc::SYS_userfaultfd,
        libc::SYS_perf_event_open,
    ] {
        rules.entry(syscall).or_default();
    }

    add_masked_arg_rule(&mut rules, libc::SYS_execveat, 4, libc::AT_EMPTY_PATH as u64);
    add_masked_arg_rule(&mut rules, libc::SYS_unshare, 0, libc::CLONE_NEWUSER as u64);
    add_masked_arg_rule(&mut rules, libc::SYS_clone, 0, libc::CLONE_NEWUSER as u64);

    let c = SeccompCondition::new(
        0,
        SeccompCmpArgLen::Dword,
        SeccompCmpOp::Eq,
        SECCOMP_SET_MODE_FILTER,
    )
    .unwrap();
    rules
        .entry(libc::SYS_seccomp)
        .or_default()
        .push(SeccompRule::new(vec![c]).unwrap());
    rules
}

fn build_compatibility_filter() -> BTreeMap<i64, Vec<SeccompRule>> {
    let mut rules: BTreeMap<i64, Vec<SeccompRule>> = BTreeMap::new();
    rules.entry(libc::SYS_clone3).or_default();
    rules.entry(libc::SYS_pidfd_open).or_default();
    rules
}

fn apply_seccomp(allow_inet: bool) -> Result<(), String> {
    let main = compile(
        build_filter_rules(allow_inet),
        SeccompAction::Errno(libc::EPERM as u32),
    )?;
    let compat = compile(
        build_compatibility_filter(),
        SeccompAction::Errno(libc::ENOSYS as u32),
    )?;
    unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    apply_filter(&compat).map_err(|e| e.to_string())?;
    apply_filter(&main).map_err(|e| e.to_string())?;
    Ok(())
}

// --- probes -------------------------------------------------------------------

fn errno_name(code: i32) -> String {
    match code {
        libc::EACCES => "EACCES".into(),
        libc::EPERM => "EPERM".into(),
        libc::ENOENT => "ENOENT".into(),
        libc::ENOSYS => "ENOSYS".into(),
        libc::EINVAL => "EINVAL".into(),
        libc::EISDIR => "EISDIR".into(),
        libc::ENOTDIR => "ENOTDIR".into(),
        libc::EBADF => "EBADF".into(),
        libc::EFAULT => "EFAULT".into(),
        libc::ESRCH => "ESRCH".into(),
        0 => "ok".into(),
        other => format!("errno{other}"),
    }
}

fn run_probe(probe: &Probe) -> String {
    match probe {
        Probe::Fs { op, path } => {
            let c = std::ffi::CString::new(path.as_str()).unwrap();
            let rc = unsafe {
                match op.as_str() {
                    "read" => libc::open(c.as_ptr(), libc::O_RDONLY),
                    "write" => libc::open(c.as_ptr(), libc::O_WRONLY),
                    "create" => libc::open(c.as_ptr(), libc::O_WRONLY | libc::O_CREAT, 0o644),
                    "listdir" => libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY),
                    "truncate" => libc::truncate(c.as_ptr(), 0),
                    "mkdir" => libc::mkdir(c.as_ptr(), 0o755),
                    "unlink" => libc::unlink(c.as_ptr()),
                    "symlink" => libc::symlink(b"target\0".as_ptr().cast(), c.as_ptr()),
                    "exec" => libc::access(c.as_ptr(), libc::X_OK),
                    _ => -1,
                }
            };
            if rc < 0 {
                errno_name(std::io::Error::last_os_error().raw_os_error().unwrap_or(0))
            } else {
                if matches!(op.as_str(), "read" | "write" | "create" | "listdir") {
                    unsafe { libc::close(rc) };
                }
                "ok".into()
            }
        }
        Probe::Syscall { nr, args } => {
            let mut a = [0i64; 6];
            for (index, value) in args.iter().take(6).enumerate() {
                a[index] = *value;
            }
            unsafe { *libc::__errno_location() = 0 };
            let rc = unsafe { libc::syscall(*nr, a[0], a[1], a[2], a[3], a[4], a[5]) };
            if rc < 0 {
                errno_name(std::io::Error::last_os_error().raw_os_error().unwrap_or(0))
            } else {
                "ok".into()
            }
        }
    }
}

fn main() {
    let mut input = String::new();
    std::io::Read::read_to_string(&mut std::io::stdin(), &mut input).unwrap();
    let job: Job = serde_json::from_str(&input).unwrap();

    let prepare = apply_landlock(&job);
    if job.apply_seccomp {
        if let Err(err) = apply_seccomp(job.allow_inet) {
            eprintln!("seccomp: {err}");
            std::process::exit(2);
        }
    }
    let probes = job.probes.iter().map(run_probe).collect();
    let out = Output { prepare, probes };
    println!("{}", serde_json::to_string(&out).unwrap());
}
