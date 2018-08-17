# Zig futex over optimization

*NOTE: To compile the zig file they expect ../zig to contain the
zig sources.*

While trying to optimize futex use I discovered
that entire loops can be optimized away and performance
was 10x slower for release modes as compared to debug mode.

Here is how I compile & test in debug mode and then use objdump to disassemble test.
As you can see it took about 3s to complete 20,000,000 incrments of gCounter using two threads.
Also, note futex_wait counts=0 and futex_wake counts=11.
```
$ zig test futex.zig
Test 1/1 Futex...
test Futex:+
test Futex: time=2.824703
test Futex:- futex_wait counts=0 futex_wake counts=11
OK
All tests passed.

$ objdump --source -d -M intel ./zig-cache/test > futex.debug.asm
```

Next I compile & test in release-fast mode. Here it takes about 25s to complete the 20,000,000 increments.
The reason is the huge number of calls to the kernel, there were 11million futex_wait's and 20million
futex_wake's.
```
$ zig test --release-fast futex.zig
Test 1/1 Futex...
test Futex:+
test Futex: time=25.229019
test Futex:- futex_wait counts=11638813 futex_wake counts=19999925
OK
All tests passed.

$ objdump --source -d -M intel ./zig-cache/test > futex.fast.asm
```

As eluided to above the reason for the huge number of futex wake/wait calls is the "Stall" loops are
being optimized away in futex.zig producer and consuer fn's.  As an example here is the
source for the begining of producer:
```
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
```

And here is the corresponding X86 assembly code from futex.debug.zig. Here you can
clearly see the count is initialized to 10,000 at 20d26b. The top of the loop condition
is at 20d27b and the bottom of the loop is at 20d3ba.
```
000000000020d230 <producer>:
fn producer(pContext: *ThreadContext) void {
  20d230:	55                   	push   rbp
  20d231:	48 89 e5             	mov    rbp,rsp
  20d234:	48 81 ec 80 00 00 00 	sub    rsp,0x80
  20d23b:	48 89 7d f8          	mov    QWORD PTR [rbp-0x8],rdi
    while (pContext.counter < max_counter) {
  20d23f:	48 8b 45 f8          	mov    rax,QWORD PTR [rbp-0x8]
  20d243:	48 8b 08             	mov    rcx,QWORD PTR [rax]
  20d246:	48 8b 40 08          	mov    rax,QWORD PTR [rax+0x8]
  20d24a:	ba 7f 96 98 00       	mov    edx,0x98967f
  20d24f:	89 d6                	mov    esi,edx
  20d251:	31 d2                	xor    edx,edx
  20d253:	48 29 ce             	sub    rsi,rcx
  20d256:	89 d1                	mov    ecx,edx
  20d258:	48 19 c1             	sbb    rcx,rax
  20d25b:	48 89 75 e8          	mov    QWORD PTR [rbp-0x18],rsi
  20d25f:	48 89 4d e0          	mov    QWORD PTR [rbp-0x20],rcx
  20d263:	0f 82 38 01 00 00    	jb     20d3a1 <producer+0x171>
  20d269:	eb 00                	jmp    20d26b <producer+0x3b>
        var count = stallCountWait;
  20d26b:	c7 45 f4 10 27 00 00 	mov    DWORD PTR [rbp-0xc],0x2710
        var produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
  20d272:	8b 05 c0 6d 03 00    	mov    eax,DWORD PTR [rip+0x36dc0]        # 244038 <produce>
  20d278:	89 45 f0             	mov    DWORD PTR [rbp-0x10],eax
        while ((produce_val != produceSignal) and (count > 0)) {
  20d27b:	83 7d f0 01          	cmp    DWORD PTR [rbp-0x10],0x1
  20d27f:	0f 95 c0             	setne  al
  20d282:	a8 01                	test   al,0x1
  20d284:	88 45 df             	mov    BYTE PTR [rbp-0x21],al
  20d287:	75 02                	jne    20d28b <producer+0x5b>
  20d289:	eb 0a                	jmp    20d295 <producer+0x65>
  20d28b:	83 7d f4 00          	cmp    DWORD PTR [rbp-0xc],0x0
  20d28f:	0f 97 c0             	seta   al
  20d292:	88 45 df             	mov    BYTE PTR [rbp-0x21],al
  20d295:	8a 45 df             	mov    al,BYTE PTR [rbp-0x21]
  20d298:	a8 01                	test   al,0x1
  20d29a:	75 02                	jne    20d29e <producer+0x6e>
  20d29c:	eb 23                	jmp    20d2c1 <producer+0x91>
            produce_val = @atomicLoad(@typeOf(produce), &produce, AtomicOrder.SeqCst);
  20d29e:	8b 05 94 6d 03 00    	mov    eax,DWORD PTR [rip+0x36d94]        # 244038 <produce>
  20d2a4:	89 45 f0             	mov    DWORD PTR [rbp-0x10],eax
            count -= 1;
  20d2a7:	8b 45 f4             	mov    eax,DWORD PTR [rbp-0xc]
  20d2aa:	83 e8 01             	sub    eax,0x1
  20d2ad:	0f 92 c1             	setb   cl
  20d2b0:	89 45 d8             	mov    DWORD PTR [rbp-0x28],eax
  20d2b3:	88 4d d7             	mov    BYTE PTR [rbp-0x29],cl
  20d2b6:	0f 82 ee 00 00 00    	jb     20d3aa <producer+0x17a>
  20d2bc:	e9 f9 00 00 00       	jmp    20d3ba <producer+0x18a>
        while (produce_val != produceSignal) {
  20d2c1:	eb 00                	jmp    20d2c3 <producer+0x93>
  20d2c3:	83 7d f0 01          	cmp    DWORD PTR [rbp-0x10],0x1
  20d2c7:	74 20                	je     20d2e9 <producer+0xb9>
            gProducer_wait_count += 1;
  20d2c9:	48 8b 05 30 6d 03 00 	mov    rax,QWORD PTR [rip+0x36d30]        # 244000 <gProducer_wait_count>
  20d2d0:	48 83 c0 01          	add    rax,0x1
  20d2d4:	0f 92 c1             	setb   cl
  20d2d7:	48 89 45 c8          	mov    QWORD PTR [rbp-0x38],rax
  20d2db:	88 4d c7             	mov    BYTE PTR [rbp-0x39],cl
  20d2de:	0f 82 e1 00 00 00    	jb     20d3c5 <producer+0x195>
  20d2e4:	e9 ec 00 00 00       	jmp    20d3d5 <producer+0x1a5>
        _ = @atomicRmw(@typeOf(gCounter), &gCounter, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
  20d2e9:	f0 48 81 05 2b 6d 03 	lock add QWORD PTR [rip+0x36d2b],0x1        # 244020 <gCounter>
  20d2f0:	00 01 00 00 00 

...

  20d3ba:	8b 45 d8             	mov    eax,DWORD PTR [rbp-0x28]
  20d3bd:	89 45 f4             	mov    DWORD PTR [rbp-0xc],eax
        while ((produce_val != produceSignal) and (count > 0)) {
  20d3c0:	e9 b6 fe ff ff       	jmp    20d27b <producer+0x4b>
```

But in futex.fast.asm that loop doesn't exist instead we just see the
`while (produce_val != produceSignal) {` with the top of the loop at 20b800
and the bottom at 20b816. Thus release-fast is SLOWER.
```
000000000020b7d0 <MainFuncs_linuxThreadMain>:
            const arg = if (@sizeOf(Context) == 0) {} else @intToPtr(*const Context, ctx_addr).*;
  20b7d0:	4c 8b 07             	mov    r8,QWORD PTR [rdi]
    while (pContext.counter < max_counter) {
  20b7d3:	b8 7f 96 98 00       	mov    eax,0x98967f
  20b7d8:	31 c9                	xor    ecx,ecx
  20b7da:	49 3b 00             	cmp    rax,QWORD PTR [r8]
  20b7dd:	49 8b 40 08          	mov    rax,QWORD PTR [r8+0x8]
  20b7e1:	48 19 c1             	sbb    rcx,rax
  20b7e4:	0f 82 88 00 00 00    	jb     20b872 <MainFuncs_linuxThreadMain+0xa2>
  20b7ea:	48 8d 3d 47 58 01 00 	lea    rdi,[rip+0x15847]        # 221038 <produce>
  20b7f1:	83 3d 40 58 01 00 01 	cmp    DWORD PTR [rip+0x15840],0x1        # 221038 <produce>
        while (produce_val != produceSignal) {
  20b7f8:	74 25                	je     20b81f <MainFuncs_linuxThreadMain+0x4f>
  20b7fa:	66 0f 1f 44 00 00    	nop    WORD PTR [rax+rax*1+0x0]
            gProducer_wait_count += 1;
  20b800:	48 83 05 f8 57 01 00 	add    QWORD PTR [rip+0x157f8],0x1        # 221000 <gProducer_wait_count>
  20b807:	01 
        : "rcx", "r11"
    );
}

pub fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("syscall"
  20b808:	b8 ca 00 00 00       	mov    eax,0xca
  20b80d:	31 f6                	xor    esi,esi
  20b80f:	31 d2                	xor    edx,edx
  20b811:	45 31 d2             	xor    r10d,r10d
  20b814:	0f 05                	syscall 
  20b816:	83 3d 1b 58 01 00 01 	cmp    DWORD PTR [rip+0x1581b],0x1        # 221038 <produce>
        while (produce_val != produceSignal) {
  20b81d:	75 e1                	jne    20b800 <MainFuncs_linuxThreadMain+0x30>
        _ = @atomicRmw(@typeOf(gCounter), &gCounter, AtomicRmwOp.Add, 1, AtomicOrder.SeqCst);
  20b81f:	f0 48 81 05 f5 57 01 	lock add QWORD PTR [rip+0x157f5],0x1        # 221020 <gCounter>
  20b826:	00 01 00 00 00 
```

I did try to create a simpler example, loop_opt.zig, but was unsuccessful as it wasn't over optimized.
