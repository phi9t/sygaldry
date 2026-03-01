#!/usr/bin/env python3
import json
import sys

from llvmlite import binding as llvm

IR = r"""
define i32 @foo(i32 %a, i32 %b) {
entry:
  %pa = alloca i32
  %pb = alloca i32
  store i32 %a, i32* %pa
  store i32 %b, i32* %pb
  %la = load i32, i32* %pa
  %lb = load i32, i32* %pb
  %sum = add i32 %la, %lb
  %mul = mul i32 %sum, 4
  %sub = sub i32 %mul, 2
  ret i32 %sub
}
"""


def main() -> int:
    llvm.initialize()
    llvm.initialize_native_target()
    llvm.initialize_native_asmprinter()

    mod = llvm.parse_assembly(IR)
    mod.verify()
    before = str(mod)

    pmb = llvm.create_pass_manager_builder()
    pmb.opt_level = 3
    pmb.loop_vectorize = True
    pmb.slp_vectorize = True

    pm = llvm.create_module_pass_manager()
    pmb.populate(pm)
    pm.run(mod)
    mod.verify()

    after = str(mod)
    changed = before != after

    payload = {
        "workload": "llvm_passes_check",
        "changed": changed,
        "before_len": len(before),
        "after_len": len(after),
    }
    print(json.dumps(payload))

    if not changed:
        print("LLVM optimization passes produced no changes", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
