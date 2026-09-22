// 最小 WASI preview1 运行时 —— 只实现 moonvoice 技能实际用到的那 5 个函数。
//
// 为什么自己写而不是引第三方：本页要内嵌进单个 HTML 文件、离线双击可用，
// 引 npm 包会带来构建链与体积。而技能只 import 了
// args_get / args_sizes_get / fd_read / fd_write / proc_exit
// （可用 wasm 的 import 段核对：`python tools/dump` 同款脚本），
// 实现这 5 个就是全部工作量，且完全可审计。
//
// 参考：WASI preview1 规范（iovec = {ptr:u32, len:u32}，共 8 字节；
// fd 0=stdin 1=stdout 2=stderr；fd_read 返回 0 表示 EOF）。

function makeWASI(argv, stdinBytes) {
  const enc = new TextEncoder();
  const out = [];
  const err = [];
  let memory = null;
  let inPos = 0;

  const dv = () => new DataView(memory.buffer);
  const u8 = () => new Uint8Array(memory.buffer);

  function view(ptr, len) {
    return u8().slice(ptr, ptr + len);
  }

  const wasi = {
    args_sizes_get(argcPtr, bufSizePtr) {
      const n = argv.length;
      const bytes = argv.reduce((s, a) => s + enc.encode(a).length + 1, 0);
      dv().setUint32(argcPtr, n, true);
      dv().setUint32(bufSizePtr, bytes, true);
      return 0;
    },

    args_get(argvPtr, argvBufPtr) {
      let p = argvBufPtr;
      argv.forEach((a, i) => {
        dv().setUint32(argvPtr + i * 4, p, true);
        const b = enc.encode(a);
        u8().set(b, p);
        p += b.length;
        u8()[p++] = 0;
      });
      return 0;
    },

    fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = dv().getUint32(iovsPtr + i * 8, true);
        const len = dv().getUint32(iovsPtr + i * 8 + 4, true);
        (fd === 2 ? err : out).push(view(ptr, len));
        total += len;
      }
      dv().setUint32(nwrittenPtr, total, true);
      return 0;
    },

    fd_read(fd, iovsPtr, iovsLen, nreadPtr) {
      let total = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = dv().getUint32(iovsPtr + i * 8, true);
        const len = dv().getUint32(iovsPtr + i * 8 + 4, true);
        const avail = Math.min(len, stdinBytes.length - inPos);
        if (avail > 0) {
          u8().set(stdinBytes.subarray(inPos, inPos + avail), ptr);
          inPos += avail;
          total += avail;
        }
        if (avail < len) break;   // 已到 EOF
      }
      dv().setUint32(nreadPtr, total, true);
      return 0;
    },

    proc_exit(code) {
      const e = new Error("proc_exit");
      e.exitCode = code;
      throw e;
    },
  };

  return {
    imports: { wasi_snapshot_preview1: wasi },
    bind(m) { memory = m; },
    stdout() { return concat(out); },
    stderr() { return new TextDecoder().decode(concat(err)); },
  };
}

function concat(chunks) {
  const n = chunks.reduce((s, c) => s + c.length, 0);
  const r = new Uint8Array(n);
  let p = 0;
  for (const c of chunks) { r.set(c, p); p += c.length; }
  return r;
}
