all: main.go
	protoc --go_out=:. hello.proto
	go build -o main -gcflags 'all=-N -l'
	objdump -dS main > main.s

trace_unmarshal:
	# proto.Unmarshal(b []byte, msg proto.Message)
	#
	# $ ../../scripts/offsets.py --bin ./main --expr 'runtime.slice'
	#
	# struct runtime.slice {
    #	void *                     array;                /*     0     8 */
    #    int                        len;                  /*     8     8 */
    #    int                        cap;                  /*    16     8 */
	#
   	#     /* size: 24, cachelines: 1, members: 3 */
   	#     /* last cacheline: 24 bytes */
	# };
	# _
	#
	#
	# How do we determine the fetch rules? We should understand how go pass func args. 
	#
	# There's several methods:
	# - method1: learn golang function call ABI convention 
	# - method2: read the main.s
	# - method3: run `dlv debug main.go`, `b proto.Unmarshal`, `continue`, `disass`
	#            then `regs` to watch how go pass args.
	#
	# Method3 is the easiest method! Let's try to do this.
	#
	# (dlv) regs
    # Rip = 0x0000000000627f2a
    # Rsp = 0x000000c000177e08
    # Rax = 0x000000c000136690 <=runtime.slice.data
    # Rbx = 0x000000000000000d <=runtime.slice.len=13
    # Rcx = 0x000000000000000d <=runtime.slice.cap=13
    # Rdx = 0x0000000000000000	
	# ...
	# (dlv) x -fmt dec -size 1 -count 13 0x000000c000136690
	# 0xc000136690:   010   011   104   101   108   108   111   032
	# 0xc000136698:   119   111   114   108   100
	# 
	# so we can determine the following:
	# - %ax: the address of runtime.slice.data
	# - %bx: the instant of runtime.slice.len=13
	# - %cx: the instant of runtime.slice.cap=13
	# 
	# runtime.slice.data => (+2(%ax)):c128, 13characters, including several heading invisible chars, skip them
	# runtime.slice.len => (%bx):u64
	# rutnime.slice.cap => (%cx):u64
	#
	# That's all, that's how we determine the fetching rules! It's not that easy !
	sudo ftrace -d -u 'main.main' -u 'github.com/golang/protobuf/proto.Unmarshal' ./main 'github.com/golang/protobuf/proto.Unmarshal(data=(+2(%ax)):c128,len=(%bx):u64,cap=(%cx):u64)' 

clean:
	rm -rf ./main ./main.s

.PHONY: clean trace_string trace_buybook
