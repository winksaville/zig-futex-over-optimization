const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;

const builtin = @import("builtin");
const AtomicOrder = builtin.AtomicOrder;
const AtomicRmwOp = builtin.AtomicRmwOp;

const linux = switch(builtin.os) {
    builtin.Os.linux => std.os.linux,
    else => @compileError("Only builtin.os.linux is supported"),
};

pub use switch(builtin.arch) {
    builtin.Arch.x86_64 => @import("../zig/std/os/linux/x86_64.zig"),
    else => @compileError("unsupported arch"),
};


pub fn futex_wait(pVal: *u32, expected_value: u32) void {
    //warn("futex_wait: {*}\n", pVal);
    _ = syscall4(SYS_futex, @ptrToInt(pVal), linux.FUTEX_WAIT, expected_value, 0);
}

var gValue: u32 = undefined;

pub fn setValue(v: u32) void {
    gValue = v;
}

pub fn waitWhileExpectedValue(expectedValue: u32, stallCount: u64) u32 {
    var count = stallCount;
    var val: u32 = undefined;

    val = @atomicLoad(u32, &gValue, AtomicOrder.SeqCst);
    while ((val == expectedValue) and (count > 0)) {
        val = @atomicLoad(u32, &gValue, AtomicOrder.SeqCst);
        count -= 1;
    }
    while (val == expectedValue) {
        futex_wait(&gValue, expectedValue);
        val = @atomicLoad(u32, &gValue, AtomicOrder.SeqCst);
    }
    return val;
}

test "loop_opt" {
    var prng = std.rand.DefaultPrng.init(12345678);
    setValue(prng.random.scalar(u32));

    var new_value = waitWhileExpectedValue(1, 1000);
    warn("new_value={}\n", new_value);
    assert(new_value != 1);
}
