# go-ftrace 架構說明

## 一、整體架構區塊圖

```
使用者輸入
  sudo ftrace -u 'main.add' ./main
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                      User Space（Go 程式）                       │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  cmd/（CLI 入口）                                         │   │
│  │    root.go   → 解析 flag（-u wildcard, -d, -D, -P）      │   │
│  │    tracer.go → 協調整個流程                               │   │
│  └─────────────────────┬────────────────────────────────────┘   │
│                        │                                         │
│          ┌─────────────┼──────────────────┐                     │
│          ▼             ▼                  ▼                     │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐    │
│  │   elf/ 套件  │ │ uprobe/ 套件 │ │     bpf/ 套件         │    │
│  │              │ │              │ │                        │    │
│  │ 解析目標 ELF │ │ 比對 wildcard│ │ 載入 BPF 程式         │    │
│  │ 取得：       │ │ 找出所有匹配 │ │ 設定 CONFIG 常數       │    │
│  │ • 函式位址   │ │ 的函式       │ │ 掛載 uprobe            │    │
│  │ • 回傳指令   │ │ 建立 Uprobe  │ │ Poll BPF maps          │    │
│  │   位址       │ │ 結構清單     │ │                        │    │
│  │ • DWARF      │ └──────┬───────┘ └──────────┬───────────┘    │
│  │   source map │        │                    │                  │
│  │ • TLS offset │        └────────────────────┘                  │
│  │ • goroutine  │                 │                              │
│  │   ID offset  │                 ▼                              │
│  └──────────────┘   ┌─────────────────────────┐                 │
│          ▲           │   eventmanager/ 套件     │                 │
│          │           │                          │                 │
│          └───────────│ • 接收 BPF 事件          │                 │
│  解析 source:line    │ • 依 goroutine ID 分組   │                 │
│                      │ • 重建 call stack        │                 │
│                      │ • 配對 entry / ret       │                 │
│                      │ • 印出彩色呼叫樹 + 時間  │                 │
│                      └─────────────────────────┘                 │
│                                  │                               │
└──────────────────────────────────┼───────────────────────────────┘
                                   │ 輸出
                                   ▼
             05 01:04:58.2797           main.add() { ...
             05 01:04:58.8810 000.6014  } main.add+154 ...


┌──────────────────────────────────────────────────────────────────┐
│                    Kernel Space（BPF 程式）                       │
│                                                                   │
│  當目標函式被呼叫時，kernel 觸發 uprobe：                         │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  ftrace.c 編譯出的 BPF 程式（嵌入在 goftrace_x86_bpfel.go）│   │
│  │                                                           │    │
│  │  ent 程式（函式入口）                                     │    │
│  │    1. bpf_get_current_task()                              │    │
│  │    2. 讀 task_struct->thread.fsbase（TLS base）           │    │
│  │    3. 讀 TLS + g_offset → runtime.g 指標                  │    │
│  │    4. 讀 runtime.g + goid_offset → goroutine ID           │    │
│  │    5. 記錄 ip, bp, caller_ip, caller_bp, timestamp        │    │
│  │    6. 寫入 event_queue（BPF QUEUE map）                   │    │
│  │                                                           │    │
│  │  ret 程式（函式回傳）                                     │    │
│  │    同上流程，location 標記為 RETPOINT                     │    │
│  │                                                           │    │
│  │  goroutine_exit 程式（goroutine 結束）                    │    │
│  │    清除 should_trace_goid map                             │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                   │
│  BPF Maps（User Space ↔ Kernel Space 共享記憶體）：              │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │  event_queue    │  │  event_stack     │  │  arg_queue     │  │
│  │  (QUEUE)        │  │  (PERCPU_ARRAY)  │  │  (QUEUE)       │  │
│  │  跨 space 傳遞  │  │  per-CPU 暫存    │  │  傳遞抓取的    │  │
│  │  完整事件       │  │  進行中事件      │  │  函式參數      │  │
│  └─────────────────┘  └──────────────────┘  └────────────────┘  │
│  ┌─────────────────┐  ┌──────────────────┐                       │
│  │ arg_rules_map   │  │should_trace_goid │                       │
│  │ (HASH)          │  │  (HASH)          │                       │
│  │ 函式參數抓取    │  │  追蹤哪些 goid   │                       │
│  │ 規則            │  │                  │                       │
│  └─────────────────┘  └──────────────────┘                       │
└──────────────────────────────────────────────────────────────────┘
```

---

## 二、執行流程時序圖

```
User        cmd/tracer    elf/      uprobe/    bpf/      Kernel(BPF)   Target Binary
 │               │          │          │         │             │              │
 │ ftrace -u ... │          │          │         │             │              │
 │──────────────>│          │          │         │             │              │
 │               │ New(bin) │          │         │             │              │
 │               │─────────>│          │         │             │              │
 │               │          │ 解析 ELF │         │             │              │
 │               │          │ symtab   │         │             │              │
 │               │          │ DWARF    │         │             │              │
 │               │<─────────│          │         │             │              │
 │               │          │          │         │             │              │
 │               │     Parse(elf, opts)│         │             │              │
 │               │─────────────────── >│         │             │              │
 │               │          │          │比對wildcard            │              │
 │               │          │          │找entry/ret位址         │              │
 │               │<──────────────────  │         │             │              │
 │               │          │          │         │             │              │
 │ [Y/n]?        │          │          │         │             │              │
 │<─────────────>│          │          │         │             │              │
 │               │          │          │         │             │              │
 │               │              Load(uprobes)     │             │              │
 │               │─────────────────────────────> │             │              │
 │               │          │          │         │載入BPF bytecode             │
 │               │          │          │         │寫入CONFIG常數               │
 │               │          │          │         │建立BPF maps                │
 │               │          │          │         │載入BPF程式到kernel          │
 │               │<──────────────────────────── │             │              │
 │               │          │          │         │             │              │
 │               │             Attach(bin, uprobes)            │              │
 │               │─────────────────────────────> │             │              │
 │               │          │          │         │ uprobe掛載  │              │
 │               │          │          │         │─────────────>              │
 │               │<──────────────────────────── │             │              │
 │               │          │          │         │             │              │
 │               │          "start tracing"       │             │              │
 │               │                               │             │              │
 │               │（另一個終端機）               │             │ ./main 執行  │
 │               │                               │             │ <────────────│
 │               │                               │             │              │
 │               │                               │             │ 呼叫 main.add│
 │               │                               │             │ <────────────│
 │               │                               │             │              │
 │               │                               │             │ 觸發 uprobe  │
 │               │                               │             │ BPF ent 程式執行
 │               │                               │             │ 讀 goid, ip, bp...
 │               │                               │             │ 寫入 event_queue
 │               │                               │             │              │
 │               │      PollEvents() loop        │             │              │
 │               │─────────────────────────────> │             │              │
 │               │          │          │         │ LookupAndDelete            │
 │               │          │          │         │ event_queue                │
 │               │          │          │         │<────────────│              │
 │               │          │ Handle(event)       │             │              │
 │               │<─────────────────────────────  │             │              │
 │               │          │重建callstack         │             │              │
 │               │          │PrintStack()          │             │              │
 │               │          │  ResolveAddress(ip)  │             │              │
 │               │          │─────────────>│       │             │              │
 │               │          │<─────────────│       │             │              │
 │               │          │  LineInfoForPc(ip)   │             │              │
 │               │          │─────────────>│       │             │              │
 │               │          │<─────────────│       │             │              │
 │               │          │              │       │             │              │
 ▼               ▼          ▼              ▼       ▼             ▼              ▼
```

---

## 三、各 Go 套件的用途

### `cmd/`（CLI 入口）

| 檔案 | 用途 |
|------|------|
| `ftrace/main.go` | 程式進入點，呼叫 `cmd.Execute()` |
| `root.go` | 定義 CLI flags（`-u`, `-d`, `-D`, `-P`），設定 log level |
| `tracer.go` | 協調整個流程：Parse → Load → Attach → PollEvents |

---

### `elf/`（目標二進位解析）

| 檔案 | 用途 |
|------|------|
| `elf.go` | 開啟 ELF 檔，讀取 DWARF debug section |
| `symtab.go` | 從 `.symtab` 找函式符號與位址 |
| `text.go` | 從 `.text` section 反組譯找 `RET` 指令位址（用於掛 ret uprobe）|
| `dwarf.go` | 從 `.debug_info` 解析 DWARF → IP 對應 source file:line |
| `tls.go` | 從 DWARF 找 `runtime.g` 在 TLS 的 offset（g_offset）|
| `header.go` | 從 DWARF 找 `g.goid` 的 offset（goid_offset）|
| `asm.go` | x86 組語輔助工具 |

---

### `internal/uprobe/`（uprobe 結構建立）

| 檔案 | 用途 |
|------|------|
| `uprobe.go` | 定義 `Uprobe` struct（函式名、位址、location、FetchArgs）|
| `parser.go` | 遍歷所有符號，比對 wildcard，找 entry/ret 位址，建 Uprobe 清單 |
| `fetcharg.go` | 解析 `main.add(a=(+0(%ax)):s64)` 語法，建立參數抓取規則 |
| `utils.go` | Wildcard 比對工具（支援 `*` 與 `?`）|

---

### `internal/bpf/`（BPF 程式管理）

| 檔案 | 用途 |
|------|------|
| `bpf.go` | Load BPF bytecode、設定 CONFIG、Attach uprobe、Poll maps |
| `gen.go` | `//go:generate` 指令（供開發者重新編譯 BPF 用）|
| `goftrace_x86_bpfel.go` | **bpf2go 生成**：BPF bytecode（Go byte literal）+ map/program Go wrapper |
| `goftrace_x86_bpfel.o` | bpf2go 生成的中間 BPF ELF 物件（建置時使用）|

---

### `internal/eventmanager/`（事件處理與輸出）

| 檔案 | 用途 |
|------|------|
| `eventmanager.go` | 維護 per-goroutine 事件佇列，分發 arg 事件 |
| `handler.go` | 接收 BPF 事件，配對 entry/ret，判斷是否印出 |
| `print.go` | 印出彩色縮排呼叫樹 + elapsed time + source:line |

---

## 四、`ftrace.c` 與 `vmlinux.h` 有被用到嗎？

### `ftrace.c` — 有用到，但執行時已是 bytecode

```
開發時（一次性）：
  ftrace.c  ──[clang 編譯]──>  BPF bytecode
                                     │
                    ──[bpf2go 嵌入]──>  goftrace_x86_bpfel.go
                                         var _GoftraceBytes = []byte{...}

執行時：
  goftrace_x86_bpfel.go 裡的 _GoftraceBytes
    ──[ebpf.LoadCollectionSpecFromReader()]──> kernel 載入並執行
```

**`ftrace.c` 在執行期不存在**，它早已被編譯成 BPF bytecode 並以 `[]byte` 的形式嵌入 Go 程式。
只有開發者要修改 BPF 邏輯時才需要重新編譯它。

`ftrace.c` 實際做的事：

```c
// 1. 讀取 goroutine ID（從 kernel task_struct 取得 TLS，再找 g.goid）
struct task_struct *task = bpf_get_current_task();
tls_base = task->thread.fsbase;          // ← 需要 vmlinux.h 才知道結構
bpf_probe_read_user(&g_addr, ..., tls_base + CONFIG.g_offset);
bpf_probe_read_user(&goid,  ..., g_addr  + CONFIG.goid_offset);

// 2. 紀錄事件（ip, bp, caller_ip, caller_bp, timestamp）
e->goid      = goid;
e->ip        = PT_REGS_IP(ctx);
e->bp        = PT_REGS_FP(ctx);
e->caller_ip = *(u64*)(e->bp + 8);
e->time_ns   = bpf_ktime_get_ns();

// 3. 推送到 event_queue（user space 的 Go 程式 poll 這個 map）
bpf_map_push_elem(&event_queue, e, 0);
```

---

### `vmlinux.h` — 有用到，提供 kernel struct 定義

`vmlinux.h` 是 Linux kernel 所有資料結構的定義檔（從 kernel BTF 自動生成），
在這個專案裡只用到兩個 struct：

```c
// vmlinux.h 裡定義的 kernel struct
struct thread_struct {
    ...
    unsigned long fsbase;   // ← TLS base address（FS register 指向的位置）
    ...
};

struct task_struct {
    ...
    struct thread_struct thread;   // ← 每個執行緒的 CPU 狀態
    ...
};
```

**為什麼需要它？**

BPF 程式要讀取 `task_struct->thread.fsbase` 來獲得 TLS base address，
進而找到 Go 的 `runtime.g`（goroutine 結構），再讀出 `goid`（goroutine ID）。

不包含 `vmlinux.h` 的話，clang 不知道 `task_struct` 的記憶體排列，
就無法正確計算 `fsbase` 的 offset。

**兩種 vmlinux.h 的差別：**

| | 用途 |
|--|------|
| `internal/bpf/headers/vmlinux.h`（專案內） | 提供給 clang 編譯 `ftrace.c` 用，是預先生成好的版本 |
| `/sys/kernel/btf/vmlinux`（當前系統） | kernel 執行時的 BTF 資訊，供 CO-RE（BPF 重定位）用 |

BPF CO-RE（Compile Once – Run Everywhere）的運作方式是：
1. **編譯時**：clang 用 `headers/vmlinux.h` 把 struct 存取轉成 CO-RE relocation
2. **執行時**：cilium/ebpf library 讀 `/sys/kernel/btf/vmlinux`，
   根據當前 kernel 的實際 struct layout 做重定位，
   確保在不同版本 kernel 上都能正確計算 offset

這正是升級前報錯的原因：
```
can't read types: type id 2487: unknown kind: Unknown (19)
```
舊版 library 讀 `/sys/kernel/btf/vmlinux` 時遇到 kernel 6.x 新增的 `BTF_KIND_ENUM64`，
不認識就直接失敗。

---

## 五、檔案角色一覽

```
go-ftrace/
├── cmd/
│   ├── ftrace/main.go          ← 程式進入點
│   ├── root.go                 ← CLI flag 定義
│   └── tracer.go               ← 主流程協調
│
├── elf/                        ← 解析目標 ELF 二進位
│   ├── elf.go                  ← ELF + DWARF 讀取
│   ├── symtab.go               ← 函式符號 → 位址
│   ├── text.go                 ← 找 RET 指令位址
│   ├── dwarf.go                ← IP → source file:line
│   ├── tls.go                  ← 找 g_offset（TLS → runtime.g）
│   └── header.go               ← 找 goid_offset（runtime.g → goid）
│
├── internal/
│   ├── uprobe/
│   │   ├── uprobe.go           ← Uprobe struct 定義
│   │   ├── parser.go           ← wildcard 比對，建立 uprobe 清單
│   │   ├── fetcharg.go         ← 解析參數抓取語法
│   │   └── utils.go            ← wildcard 工具
│   │
│   ├── bpf/
│   │   ├── ftrace.c            ← BPF 程式原始碼（開發時編譯用）
│   │   ├── headers/
│   │   │   ├── vmlinux.h       ← kernel struct 定義（編譯 ftrace.c 用）
│   │   │   └── bpf_helpers.h   ← BPF helper 函式宣告
│   │   ├── gen.go              ← //go:generate 指令
│   │   ├── goftrace_x86_bpfel.go  ← [generated] BPF bytecode + Go wrapper
│   │   ├── goftrace_x86_bpfel.o   ← [generated] BPF ELF 物件
│   │   └── bpf.go              ← Load / Attach / PollEvents
│   │
│   └── eventmanager/
│       ├── eventmanager.go     ← per-goroutine 事件管理
│       ├── handler.go          ← entry/ret 配對，判斷何時印出
│       └── print.go            ← 彩色呼叫樹輸出
│
└── examples/
    └── trace_funcs/
        └── main.go             ← 範例目標程式（被追蹤的程式）
```
