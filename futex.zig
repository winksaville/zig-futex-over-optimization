const std = @import("std");
const assert = std.debug.assert;
const warn = std.debug.warn;
const mem = std.mem;
const math = std.math;
const Queue = std.atomic.Queue;
const Timer = std.os.time.Timer;

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



pub fn futex_wait(pVal: *i32, expected_value: u32) void {
    //warn("futex_wait: {*}\n", pVal);
    _ = syscall4(SYS_futex, @ptrToInt(pVal), linux.FUTEX_WAIT, expected_value, 0);
}

pub fn futex_wake(pVal: *i32, num_threads_to_wake: u32) void {
    //warn("futex_wake: {*}\n", pVal);
    _ = syscall4(SYS_futex, @ptrToInt(pVal), linux.FUTEX_WAKE, num_threads_to_wake, 0);
}


const ThreadContext = struct {
    const Self = this;

    counter: u128,

    pub fn init(pSelf: *Self) void {
        pSelf.counter = 0;
    }
};

var gProducer_context: ThreadContext = undefined;
var gConsumer_context: ThreadContext = undefined;

const consumeSignal = 0;
const produceSignal = 1;
var produce: i32 = consumeSignal;
var gCounter: u64 = 0;
var gProducer_wait_count: u64 = 0;
var gConsumer_wait_count: u64 = 0;
var gProducer_wake_count: u64 = 0;
var gConsumer_wake_count: u64 = 0;

const max_counter = 10000000;
const stallCountWait: u32 = 10000;
const stallCountWake: u32 = 2000;

fn producer(pContext: *ThreadContext) void {
    while (pContext.counter < max_counter) {
        // Stall to see if the consumer changes produce to produceSignal
        var count = stallCountWait;
        var produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
        while ((produce_val != produceSignal) and (count > 0)) {
            produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
            count -= 1;
        }
        // If consumer hasn't changed it call futex_wait until it does
        while (produce_val != produceSignal) {
            gProducer_wait_count += 1;
            futex_wait(&produce, consumeSignal);
            produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
        }

        // Produce as produce == produceSignal
        _ = @atomicRmw(@typeOf(gCounter), &gCounter, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
        pContext.counter += 1;

        // Set produce to consumeSignal
        _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, consumeSignal, AtomicOrder.SeqCst);

        // Stall to see if consumer changes produce to produceSignal
        count = stallCountWake;
        produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
        while ((produce_val != produceSignal) and (count > 0)) {
            produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
            count -= 1;
        }
        // If consumer hasn't changed it call futex_wake and continue
        if (produce_val != produceSignal) {
            gProducer_wake_count += 1;
            futex_wake(&produce, 1);
        }
    }
}

fn consumer(pContext: *ThreadContext) void {
    while (pContext.counter < max_counter) {
        // Set produce to produceSignal
        _ = @atomicRmw(@typeOf(produce), &produce, AtomicRmwOp.Xchg, produceSignal, AtomicOrder.SeqCst);

        // Stall to see if the producer changes produce to consumeSignal
        var count = stallCountWake;
        var produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
        while ((produce_val != consumeSignal) and (count > 0)) {
            produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
            count -= 1;
        }
        // If producer hasn't changed it call futex_wake and continue
        if (produce_val != consumeSignal) {
            gConsumer_wake_count += 1;
            futex_wake(&produce, 1);
        }

        // Stall to see if the producer changes produce to consumeSignal
        count = stallCountWait;
        produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
        while ((produce_val != consumeSignal) and (count > 0)) {
            produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
            count -= 1;
        }
        // If producer hasn't changed it call futex_wait until it does
        while (produce_val != consumeSignal) {
            gConsumer_wait_count += 1;
            futex_wait(&produce, produceSignal);
            produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
        }

        // Consume as produce == consumeSignal
        _ = @atomicRmw(@typeOf(gCounter), &gCounter, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
        pContext.counter += 1;
    }
}

test "Futex" {
    warn("\ntest Futex:+\n");
    defer warn("test Futex:- futex_wait counts={} futex_wake counts={}\n",
        gProducer_wait_count + gConsumer_wait_count, gProducer_wake_count + gConsumer_wake_count);

    gProducer_context.init();
    gConsumer_context.init();

    var timer = try Timer.start();
    var start_time = timer.read();

    var producer_thread = try std.os.spawnThread(&gProducer_context, producer);
    var consumer_thread = try std.os.spawnThread(&gConsumer_context, consumer);

    producer_thread.wait();
    consumer_thread.wait();

    var end_time = timer.read();
    var duration = end_time - start_time;
    warn("test Futex: time={.6}\n", @intToFloat(f64, end_time - start_time) / @intToFloat(f64, std.os.time.ns_per_s));

    assert(gCounter == max_counter * 2);
}
