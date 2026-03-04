# 升級 cilium/ebpf v0.9.0 → v0.20.0 移植說明

## 背景

Linux kernel 6.0 引入了 `BTF_KIND_ENUM64`（BTF type kind = 19）。
`cilium/ebpf v0.9.0` 不認識這個 kind，導致在 kernel 6.x 上執行時直接報錯：

```
Error: field Ent: program ent: apply CO-RE relocations:
       can't read types: type id 2487: unknown kind: Unknown (19)
```

升級至 v0.20.0 後，library 有三個破壞性 API 改變，以及 bpf2go 工具的行為改變，
需要對應修改 Go 程式碼與 BPF C 程式碼。

---

## 一、Go 程式碼修改（`internal/bpf/bpf.go`）

### 1. `LogSize` → `LogSizeStart`

```go
// 舊
Programs: ebpf.ProgramOptions{LogSize: ebpf.DefaultVerifierLogSize * 4},

// 新
Programs: ebpf.ProgramOptions{LogSizeStart: 64 * 1024 * 4},
```

**原因：** v0.20.0 改名並移除了 `DefaultVerifierLogSize` 常數。
`LogSizeStart` 是 verifier log buffer 的初始大小，library 會自動成倍擴大直到 `maxVerifierLogSize`。

---

### 2. `UprobeOptions.Offset` → `UprobeOptions.Address`

```go
// 舊
up, err := ex.Uprobe("", prog, &link.UprobeOptions{Offset: up.AbsOffset})

// 新
up, err := ex.Uprobe("", prog, &link.UprobeOptions{Address: up.AbsOffset})
```

**原因：** 新版 API 語意改變：

| 欄位 | 語意 |
|------|------|
| `Address` | **絕對** file offset（不需要 symbol name） |
| `Offset`  | 相對於 symbol 的 offset（需要搭配 symbol name 使用） |

原本傳空字串 `""` 當 symbol name 並用 `Offset` 傳絕對位址，
新版會嘗試在 ELF symbol table 找空字串，找不到就報錯：

```
Error: symbol : not found
```

改成 `Address` 後，library 直接用絕對位址，不查 symbol table。

---

### 3. 新增 `GoftraceArgRule` type alias

```go
// bpf.go 新增
type GoftraceArgRule = struct {
    _           structs.HostLayout
    Type        uint8
    Reg         uint8
    Size        uint8
    Length      uint8
    Offsets     [8]int16
    Dereference [8]uint8
}
```

**原因：** 舊版 bpf2go 用 `-type arg_rule` flag 會生成獨立的 `GoftraceArgRule` struct。
新版 bpf2go 移除了 `-type` flag，改從 map 的 BTF 型別自動生成。
`arg_rule` 沒有直接當 map value，所以沒有被獨立生成，
它被內嵌在 `GoftraceArgRules.Rules [8]struct{...}` 裡。
用 type alias 讓 `bpf.go` 裡的 `GoftraceArgRule{...}` 寫法繼續有效。

---

## 二、BPF C 程式碼修改（`internal/bpf/ftrace.c`）

### 1. 移除 `CONFIG` 的 `static`

```c
// 舊
static volatile const struct config CONFIG = {};

// 新
volatile const struct config CONFIG = {};
```

**原因：**

`RewriteConstants()` 在 v0.9.0 直接讀 ELF 的 `.rodata` section 來改常數值。
v0.20.0 改成透過 `cs.Variables` map：

```go
// v0.20.0 內部實作
func (cs *CollectionSpec) RewriteConstants(consts map[string]interface{}) error {
    v, ok := cs.Variables[n]  // 從 Variables map 查找
    if !ok {
        missing = append(missing, n)  // 找不到就報錯
    }
```

`cs.Variables` 由 BPF 程式的 BTF 資訊建立。`static` 關鍵字讓 clang 把變數標記為
file-scope only，bpf2go 掃描 BTF 時不把它加入 `Variables`，
所以出現 `some constants are missing from .rodata: CONFIG`。

移除 `static` 後，bpf2go 生成：

```go
type GoftraceVariableSpecs struct {
    CONFIG *ebpf.VariableSpec `ebpf:"CONFIG"`
}
```

---

### 2. 舊式 `bpf_map_def` → BTF 式 map 定義

```c
// 舊式（沒有 BTF 型別資訊）
struct bpf_map_def SEC("maps") event_queue = {
    .type        = BPF_MAP_TYPE_QUEUE,
    .key_size    = 0,
    .value_size  = sizeof(struct event),  // 只有 size，沒有型別
    .max_entries = 10000,
};

// BTF 式（含型別資訊）
struct {
    __uint(type, BPF_MAP_TYPE_QUEUE);
    __uint(value_size, sizeof(struct event));
    __uint(max_entries, 10000);
} event_queue SEC(".maps");

// 有 key/value 的 map 用 __type() 攜帶型別
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u64);
    __type(value, struct arg_rules);
    __uint(max_entries, 100);
} arg_rules_map SEC(".maps");
```

**原因：**

舊版 bpf2go 有 `-type` flag 可以強制生成指定型別的 Go struct：

```go
// 舊 gen.go
//go:generate ... -type event -type arg_rules -type arg_rule -type arg_data Goftrace ...
```

新版 bpf2go **移除了 `-type` flag**，改從 map 的 BTF 型別資訊**自動**生成 Go struct。

| 方式 | 型別資訊 | bpf2go 能否自動生成 Go struct |
|------|----------|-------------------------------|
| `bpf_map_def`（舊式）| 只有 `value_size`（數字）| 不能 |
| BTF map（`__type(value, ...)`）| 完整 struct 型別 | 可以 |

改成 BTF 式後，bpf2go 自動生成 `GoftraceEvent`、`GoftraceArgData`、`GoftraceArgRules`。

---

### 3. 移除 dummy 型別匯出變數

```c
// 移除這三行
const struct event     *_   __attribute__((unused));
const struct arg_rules *__  __attribute__((unused));
const struct arg_data  *___ __attribute__((unused));
```

**原因：**

這三行是舊版 bpf2go 的 workaround：當時沒有 `-type` flag，
就在 C 程式碼裡放 dummy 指標變數來強制 clang 把型別資訊寫進 ELF，
讓 bpf2go 能找到並生成對應的 Go struct。

新版 bpf2go 移除 `-type` 後，這些 dummy 變數被當作普通 global variable 處理，
bpf2go 嘗試為每個都生成 `GoftraceVariableSpecs` 裡的欄位，
但三個都是 `*ebpf.VariableSpec` 型別，Go 不允許同一 struct 內嵌相同型別多次：

```go
// bpf2go 生成的問題程式碼（無法編譯）
type GoftraceVariableSpecs struct {
    *ebpf.VariableSpec `ebpf:"_"`   // 重複
    *ebpf.VariableSpec `ebpf:"__"`  // 重複
    *ebpf.VariableSpec `ebpf:"___"` // 重複
}
// error: VariableSpec redeclared
```

移除後，已改用 BTF map 提供型別資訊，dummy 變數不再需要。

---

## 三、重新生成 bpf2go 產出檔

### 為什麼不能直接改舊的 `goftrace_bpfel_x86.go`？

這個檔案是 **code-generated**，不是手寫的。它由 bpf2go 從 `ftrace.c` 編譯產出，
包含兩樣東西：

1. **編譯後的 BPF bytecode**（以 Go byte literal 嵌入）
2. **map/program/variable 的 Go wrapper struct**

```
ftrace.c  →  [bpf2go 工具]  →  goftrace_x86_bpfel.go   (Go wrapper)
                                goftrace_x86_bpfel.o    (BPF bytecode)
```

直接改舊檔有兩個根本問題：

**問題 1：嵌入的 bytecode 是舊版編譯結果**

```go
var _GoftraceBytes = []byte{0x7f, 0x45, 0x4c, 0x46, ...} // 幾千個 bytes
```

這是用舊式 `bpf_map_def` 編譯出的 BPF bytecode，對應舊版 map 定義。
不重新編譯的話，kernel 載入的是舊格式 BPF 程式，與新版 API 行為不符。

**問題 2：生成檔命名規則也改了**

```
舊版 bpf2go: goftrace_bpfel_x86.go   (bpf + endian + arch)
新版 bpf2go: goftrace_x86_bpfel.go   (arch + bpf + endian)
```

這代表 generated 檔案**必須跟當前版本的 bpf2go 重新生成**，
才能和新版 `ebpf.LoadCollectionSpecFromReader()` 等 API 正確配合。

### 重新生成指令

```bash
cd internal/bpf
GOPACKAGE=bpf go run github.com/cilium/ebpf/cmd/bpf2go \
    -cc clang -no-strip -target native \
    Goftrace ./ftrace.c -- -I./headers
```

---

## 修改總結

| 檔案 | 修改內容 | 原因 |
|------|----------|------|
| `go.mod` | `cilium/ebpf v0.9.0 → v0.20.0` | 支援 kernel 6.x BTF_KIND_ENUM64 |
| `internal/bpf/bpf.go` | `LogSize` → `LogSizeStart` | API rename |
| `internal/bpf/bpf.go` | `Offset` → `Address`（uprobe 掛載）| 語意改變，Address 才是絕對 file offset |
| `internal/bpf/bpf.go` | 新增 `GoftraceArgRule` type alias | 新版 bpf2go 不獨立生成此 struct |
| `internal/bpf/ftrace.c` | 移除 `CONFIG` 的 `static` | 讓 bpf2go 把它放進 `cs.Variables` |
| `internal/bpf/ftrace.c` | 舊式 maps → BTF maps | 讓 bpf2go 從型別資訊自動生成 Go struct |
| `internal/bpf/ftrace.c` | 移除 dummy 變數 `_`, `__`, `___` | 舊版 `-type` flag workaround，新版不需要且會導致編譯錯誤 |
| `internal/bpf/goftrace_*.go/.o` | 重新用 bpf2go 生成 | bytecode 和 wrapper 必須同步更新 |

---

## 四、常見問題

### Q：bpf2go 需要額外安裝嗎？

**不需要。** `bpf2go` 是 `cilium/ebpf` module 的一部分，直接用 `go run` 執行即可：

```bash
go run github.com/cilium/ebpf/cmd/bpf2go
```

`go run` 會自動從 module cache 取得並執行，不需要 `go install`。

唯一需要系統安裝的外部相依是 **clang**（用來把 BPF C 程式碼編譯成 BPF bytecode）：

```bash
# 確認 clang 已安裝
which clang
clang --version
```

| 相依 | 來源 | 安裝方式 |
|------|------|----------|
| `bpf2go` 工具 | `cilium/ebpf` Go module | `go run` 自動處理，無需安裝 |
| `clang` 編譯器 | 系統套件 | `apt install clang` |

### Q：為什麼重新生成後檔名從 `goftrace_bpfel_x86` 變成 `goftrace_x86_bpfel`？

新版 bpf2go 改了 generated 檔案的命名規則：

```
舊版: goftrace_bpfel_x86.go   順序：bpf + endian + arch
新版: goftrace_x86_bpfel.go   順序：arch + bpf + endian
```

功能完全相同，只是 naming convention 改變。舊的 `goftrace_bpfel_x86.go` 可以直接刪除。

### Q：為什麼不直接手改舊的 `goftrace_bpfel_x86.go` 就好？

兩個根本原因：

1. **bytecode 已過期**：檔案裡嵌入的 `_GoftraceBytes` 是用舊式 `bpf_map_def` 編譯的 BPF bytecode。
   不重新編譯的話，kernel 載入的是舊格式 BPF 程式，和新版 API 不符。

2. **生成檔必須和 bpf2go 版本對齊**：新版 `ebpf.LoadCollectionSpecFromReader()` 等 API
   需要搭配新版 bpf2go 生成的格式，手動修改舊檔無法保證結構完全正確。

正確做法是修改 `ftrace.c`，再重新執行 bpf2go 讓它生成所有產出物。
