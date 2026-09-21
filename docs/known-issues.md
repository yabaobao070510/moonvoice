# 已知问题与绕行

## moonc 编译期 ICE：高位置位字节字面量做索引赋值

- **版本**：moonc v0.10.14+7d59c7ec9（moon 0.1.20260920），目标 wasm
- **最小复现**：

```moonbit
fn main {
  let fa : FixedArray[Byte] = FixedArray::make(1, b'\x00')
  fa[0] = b'\x80'   // 编译器崩溃
}
```

- **现象**：

```
Oops, the compiler has encountered an unexpected situation.
Error: Invalid_argument("Moonc.Basic_ba_int.get")
```

- **触发条件**：`fa[i] = <高位置位的字节字面量>`（`b'\x80'`、`b'\xAA'` 等）。
  低位置位字面量（`b'\x00'`）与直接绑定（`let x : Byte = b'\xAA'`）均正常。
- **绕行**：走一层函数，不要在该位置直接写字面量。

```moonbit
fn byte_of(v : Int) -> Byte { v.to_byte() }
fa[0] = byte_of(0x80)
```

- **影响范围**：`audio/wav.mbt` 的 WAVE_FORMAT_EXTENSIBLE GUID 写入与测试数据构造。
- **状态**：已在代码中绕开并加注释；复现件保留在 `docs/`，待上游修复后可移除绕行。
