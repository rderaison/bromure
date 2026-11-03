#!/usr/bin/env python3
"""Assert every syscall number in bromure_openshell.py against the real headers.

The numbers are hardcoded rather than resolved through libc, because a seccomp
filter that quietly loses a rule because a name failed to resolve is a filter
that quietly stops blocking something. Hardcoding only helps if something checks
the constants, which is this.

Needs a C compiler and kernel headers (`linux-libc-dev`, always present on a
Bromure image). Run: tests/test_syscall_table.py
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import bromure_openshell as osh  # noqa: E402


def kernel_numbers(names):
    """Ask the compiler, not a table: __NR_fcntl on arm64 only exists through a
    define chain that `cpp -dM` does not expand."""
    body = "".join(
        '    printf("%s %%d\\n", __NR_%s);\n' % (name, name) for name in names)
    source = ('#include <asm/unistd.h>\n#include <stdio.h>\n'
              'int main(void) {\n%s    return 0;\n}\n' % body)
    compile_result = subprocess.run(
        ["cc", "-x", "c", "-o", "/tmp/.syscall-probe", "-"],
        input=source, text=True, capture_output=True)
    if compile_result.returncode != 0:
        missing = set(re.findall(r"__NR_(\w+)", compile_result.stderr))
        if missing:
            return None, missing
        raise SystemExit("cannot compile the probe:\n%s" % compile_result.stderr)
    out = subprocess.run(["/tmp/.syscall-probe"], capture_output=True, text=True)
    numbers = {}
    for line in out.stdout.splitlines():
        name, value = line.split()
        numbers[name] = int(value)
    return numbers, set()


def main():
    names = sorted(osh.SYS)
    numbers, missing = kernel_numbers(names)
    if numbers is None:
        print("FAIL these names do not exist in <asm/unistd.h>: %s"
              % ", ".join(sorted(missing)))
        return 1

    failures = []
    for name in names:
        expected = numbers.get(name)
        actual = osh.SYS[name]
        if expected != actual:
            failures.append("  %-22s table=%-5d kernel=%s" % (name, actual, expected))

    print("checked %d syscall numbers for %s" % (len(names), os.uname().machine))
    if failures:
        print("MISMATCH:")
        print("\n".join(failures))
        return 1
    print("ok   every number matches <asm/unistd.h>")

    # The filters must also compile and stay inside the kernel's instruction
    # limit on this arch. A filter that cannot be installed protects nothing.
    programs = {
        "main": (osh.build_main_filter_rules(True), osh.EPERM_ACTION),
        "main (no inet)": (osh.build_main_filter_rules(False), osh.EPERM_ACTION),
        "compatibility": (osh.build_compatibility_filter_rules(), osh.ENOSYS_ACTION),
        "supervisor prelude": (osh.build_supervisor_prelude_rules(), osh.EPERM_ACTION),
    }
    child_rules, child_compat = osh.build_child_hardening_rules(1234, 5678)
    programs["child hardening"] = (child_rules, osh.EPERM_ACTION)
    programs["child compatibility"] = (child_compat, osh.ENOSYS_ACTION)

    for label, (rules, action) in sorted(programs.items()):
        program = osh.compile_filter(rules, action)
        count = len(program) // 8
        status = "ok  " if count <= osh.BPF_MAXINSNS else "FAIL"
        print("%s %-22s %4d instructions (limit %d)"
              % (status, label, count, osh.BPF_MAXINSNS))
        if count > osh.BPF_MAXINSNS:
            failures.append(label)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
