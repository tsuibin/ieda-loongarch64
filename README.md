# iEDA 在龙芯 loongarch64 / AOSC OS 上的原生编译记录

本仓库记录开源 EDA 工具链 [iEDA](https://github.com/OSCC-Project/iEDA) 在龙芯 3B6000M（loongarch64）+ AOSC OS 14 上从源码原生编译成功所遇到的**全部问题与解决办法**，并附可直接使用的补丁与可复现构建脚本。

## 结果

- 编译成功时间：2026-11-20
- 产物：`~/iEDA/build/src/apps/iEDA`（47 MB，LoongArch PIE，无缺失动态库）
- 入口软链：`~/iEDA/bin/iEDA`
- 冒烟验证：`./bin/iEDA -script scripts/hello.tcl` → 输出 `Hello iEDA!`，退出码 0

## 环境

| 项 | 值 |
| --- | --- |
| CPU | 龙芯 3B6000M，8 核 |
| 架构 | loongarch64 |
| 系统 | AOSC OS 14.0.2，内核 7.1.13-aosc-main-16k |
| 编译器 | GCC 16.2.0（AOSC 源，非上游要求的 gcc-10） |
| CMake | 4.5.0 |
| Rust | rustc / cargo 1.100.0（镜像 tuna） |
| 内存 / 磁盘 | 14 GiB / 1.8 TB |
| 源码 | `git clone --depth 1 https://gitee.com/oscc-project/iEDA.git ~/iEDA` |

## 问题与解决（全部）

### 1. 上游 `build.sh` 硬编码 `gcc-10` / `g++-10`

**现象**：`build.sh` 内 `CPP_COMPILER_PATH="g++-10"`、`C_COMPILER_PATH="gcc-10"`，且版本检查要求 ≥10.0。本机 AOSC 只有 GCC 16，没有 gcc-10。

**解决**：不调用 `build.sh`，直接手写 CMake 配置命令（见下方“复现步骤”），用系统 `gcc` / `g++`。`build.sh` 只在安装依赖（`-i apt`）和包壳上有用，本机无 root 且非 Debian 系，这套流程整体不适用。

### 2. Eigen3 缺失，且 AOSC 包名不叫 `eigen3`

**现象**：CMake 报 `find_package(Eigen3 REQUIRED)` 失败；`oma download eigen3` 提示「无法找到匹配关键字 eigen3 的软件包」。

**解决**：AOSC 里 Eigen 3 的包名是 `eigen-3`（`eigen-5` 是另一个大版本）：

```bash
oma download -p /tmp/ieda-deps eigen-3
mkdir -p ~/opt/eigen3
dpkg-deb -x /tmp/ieda-deps/eigen-3_3.4.1-1_all.deb ~/opt/eigen3
```

CMake 增加 `CMAKE_PREFIX_PATH=/home/LoongBox/opt/eigen3/usr`（该目录含 `usr/include/eigen3` 与 `usr/share/eigen3/cmake/Eigen3Config.cmake`）。

### 3. CMake 找不到 ZLIB 库

**现象**：

```
Could NOT find ZLIB (missing: ZLIB_LIBRARY) (found version "1.3.1")
```

头文件在 `/usr/include/zlib.h`、`libz.so` 在 `/usr/lib/libz.so`，但 CMake 4.5 没找到。

**解决**：显式指定库路径：

```bash
-DZLIB_LIBRARY=/usr/lib/libz.so
```

### 4. 默认静态构建要求 `libz.a`，系统只有 `.so`

**现象**：

```
Found dynamic zlib, but static required: /usr/lib/libz.so
```

`src/third_party/lefdef/def/CMakeLists.txt` 在 `BUILD_STATIC_LIB=ON` 时把 `CMAKE_FIND_LIBRARY_SUFFIXES` 设为 `.a`，找不到静态 zlib 就报错。

**解决**：下载 AOSC 的 `zlib-static` 包，解到用户级目录：

```bash
oma download -p /tmp/ieda-deps zlib-static
mkdir -p ~/opt/zlib-static
dpkg-deb -x /tmp/ieda-deps/zlib-static_*.deb ~/opt/zlib-static
```

CMake 增加 `CMAKE_LIBRARY_PATH=/home/LoongBox/opt/zlib-static/usr/lib`。不要再传 `-DZLIB_LIBRARY=/usr/lib/libz.so`，否则第 3 步的显式值会覆盖静态库查找。

### 5. GCC 16：vendored yaml-cpp 缺 `<cstdint>`

**现象**：

```
src/third_party/yaml-cpp/src/emitterutils.cpp:221:11: error: ‘uint16_t’在此作用域中尚未声明
```

旧版 yaml-cpp 依赖 GCC 10 间接包含 `<cstdint>`，GCC 16 不再隐式包含。

**解决**：应用补丁 [`patches/0001-yaml-cpp-cstdint.patch`](patches/0001-yaml-cpp-cstdint.patch)，在文件头部加 `#include <cstdint>`。

### 6. GCC 16：vendored abseil 同样缺 `<cstdint>`

**现象**：

```
absl/container/internal/container_memory.h:66:27: error: ‘uintptr_t’不是一个类型名
```

与第 5 步同源，且这类问题会散落在多个头文件里。

**解决**：不逐个打补丁，统一在 CMake 加全局编译选项，一次覆盖所有老代码：

```bash
-DCMAKE_CXX_FLAGS="-include cstdint"
```

注意：CMakeLists 里 `set(CMAKE_CXX_FLAGS_RELEASE "$ENV{CXXFLAGS} -O3 ...")`，所以必须通过 `CMAKE_CXX_FLAGS`（而非 `CXXFLAGS` 环境变量）注入，该变量会拼到每个编译命令最前面。

### 7. GCC 16 对龙芯 CPUID 只报 note，可忽略

**现象**：大量编译行出现：

```
g++: note: unknown processor ID ‘0x14b020’, some tuning parameters will fall back to default
```

**结论**：只是 GCC 16 不认识龙芯 CPUID 的调优回退提示，不影响编译结果，无需处理。

### 8. `libiir.a` 缺失：Rust ExternalProject 未进入 iEDA 的依赖图

**现象**：C++ 全部 100% 编译完成后，最终链接报：

```
make[3]: *** 没有规则可制作目标“…/iir/target/release/libiir.a”，由“src/apps/iEDA” 需求。 停止。
```

**原因**：`src/operation/iIR/source/iir-rust/CMakeLists.txt` 中 `ADD_EXTERNAL_PROJ(iir)` 展开了 `add_dependencies(iir iir)`，形成自依赖而非把 `iir` 工程挂到主目标；`iEDA` 链接器需要该静态库却没人构建它。其余 Rust parser（verilog / liberty / spef / vcd）则正常自动构建。

**解决**：最终链接前手动构建一次：

```bash
cmake --build build --target iir
```

生成 `src/operation/iIR/source/iir-rust/iir/target/release/libiir.a` 后再执行主目标构建。

### 9. 最终链接找不到 glog：`-Wl,-Bstatic -lglog -lgflags`

**现象**：

```
/usr/bin/ld: 找不到 -lglog: 没有那个文件或目录
/usr/bin/ld: have you installed the static version of the glog library ?
```

**原因**：`src/utility/log/CMakeLists.txt` 在 `BUILD_STATIC_LIB=ON` 时写死 `LINK_glog "libglog.a"` / `LINK_gflags "libgflags.a"`，CMake 生成 `-Wl,-Bstatic -lglog -lgflags`；本机 AOSC 的 glog 0.7.1 与 gflags 2.2.2 只有 `.so`，无静态包（`oma search glog` 无 `glog-static`）。

**解决**：应用补丁 [`patches/0002-glog-gflags-dynamic-link.patch`](patches/0002-glog-gflags-dynamic-link.patch)，静态构建时也用动态名 `glog` / `gflags`。产物仍可正常运行，仅运行时依赖系统的 `libglog.so.0.7.1` / `libgflags.so`。

### 10. 无害告警（不用修）

| 告警 | 来源 | 说明 |
| --- | --- | --- |
| `Manually-specified variables were not used: CMD_BUILD` | 顶层 CMakeLists | 变量已定义即可，项目内未实际分支；保留不影响结果 |
| Policy `CMP0148 is not set` | pybind11 2.10.2 | CMake 4.5 移除了 FindPythonInterp/FindPythonLibs，旧 pybind11 的兼容告警 |
| `AUTOGEN: No valid Qt version found for target ivec_graph_dm` | vectorization | 默认不启用 GUI，AUTOMOC 自动关闭 |
| `Cargo.toml: unused manifest key: package.git` | 各 Rust parser | 上游 Cargo.toml 残留键 |
| `Cargo.toml: unused manifest key: build`；`-Z threads=8` 无效 | iir | 该 `[build]` 段应写在 `.cargo/config.toml`，当前被忽略；不影响构建 |
| `warning: hiding a lifetime that's elided elsewhere` | verilog-parser | Rust 新版本 lint 提示 |
| `-Wmaybe-uninitialized` / `-Woverloaded-virtual` / `-Wpessimizing-move` / `-Wsign-compare` 等 | 各处上游代码 | GCC 16 更严格的告警；项目只开 `-Werror=return-type`，均不构成错误 |

## 可复现构建步骤

```bash
# 0. 准备源码
git clone --depth 1 https://gitee.com/oscc-project/iEDA.git ~/iEDA
cd ~/iEDA

# 1. 打补丁
patch -p1 < ~/ieda-loongarch64/patches/0001-yaml-cpp-cstdint.patch
patch -p1 < ~/ieda-loongarch64/patches/0002-glog-gflags-dynamic-link.patch

# 2. 用户级依赖（不碰系统盘、不用 root）
oma download -p /tmp/ieda-deps eigen-3
oma download -p /tmp/ieda-deps zlib-static
mkdir -p ~/opt/eigen3 ~/opt/zlib-static
dpkg-deb -x /tmp/ieda-deps/eigen-3_3.4.1-1_all.deb ~/opt/eigen3
dpkg-deb -x /tmp/ieda-deps/zlib-static_*.deb ~/opt/zlib-static

# 3. 配置（注意 CMAKE_CXX_FLAGS 注入 cstdint）
CC=gcc CXX=g++ \
CMAKE_PREFIX_PATH=/home/LoongBox/opt/eigen3/usr \
CMAKE_LIBRARY_PATH=/home/LoongBox/opt/zlib-static/usr/lib \
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-include cstdint"

# 4. 先单独构建 iir 的 Rust 静态库
cmake --build build --target iir

# 5. 再构建主程序
cmake --build build -j8 --target iEDA

# 6. 验证
ln -s ../build/src/apps/iEDA bin/iEDA   # 可选，建立标准入口
./bin/iEDA -script scripts/hello.tcl    # 期望输出: Hello iEDA!
```

仓库根目录的 [`build.sh`](build.sh) 是以上步骤 2–5 的可执行版本（含前置检查）。

## 经验教训

1. **先把所有已知补丁一次性打完再启动编译。** iEDA 全量编译在 8 核上约 40 分钟；每次修改 CMakeLists 都会触发几乎所有目标重编，本次因逐个解决问题累计重编 4 次，耗时约 4 小时。
2. **GCC 16 编译老 C++ 工程**，遇到 `uint16_t` / `uintptr_t` / `int64_t` 未声明，优先用 `-include cstdint` 全局注入，比逐个改第三方头文件省事。
3. **AOSC 包名要和上游文档对账**：`eigen-3` 而非 `eigen3`；静态库常单独打包为 `<pkg>-static`（如 `zlib-static`），但 glog/gflags 没有静态包，只能改链接方式。
4. **用户级依赖统一放 `~/opt/<包名>/usr`**，通过 `CMAKE_PREFIX_PATH` / `CMAKE_LIBRARY_PATH` 注入，不写系统目录、不用 root。

## 许可

本仓库仅记录构建经验与对上游的微小补丁；iEDA 本体遵循 Mulan PSL v2，详见源码 `LICENSE`。
