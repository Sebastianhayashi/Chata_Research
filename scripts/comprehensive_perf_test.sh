#!/usr/bin/env bash
set -e

###############################################################################
# comprehensive_perf_test.sh 
# 1) 收集 perf 事件: instructions, cycles, cache-misses, branch-misses
# 2) 在 CSV 中输出 perf_instructions, perf_cycles, perf_cachemiss, perf_branchmiss
# 3) 扩大 SCALES 到 1,4,8,16,32,64 并设置 RUNS=10
# 4) 保持子目录 structure: generated_s/, logs/, out_bin/
###############################################################################

echo "=== [A] 安装/检测依赖 ==="

# perf
if ! command -v perf &>/dev/null; then
  echo "[perf 不存在] 尝试 dnf 安装 perf..."
  sudo dnf install -y perf || echo "在 openEuler 上找不到 perf 包，请手工安装后重试。"
fi

# cargo/just
if ! command -v cargo &>/dev/null; then
  echo "[Cargo 不存在] 尝试用 dnf 安装 Rust 与 Cargo..."
  sudo dnf install -y rust cargo || {
    echo "在 openEuler 上找不到 rust/cargo 包，请手工安装后重试。"
    exit 1
  }
fi

if ! command -v just &>/dev/null; then
  echo "[Just 不存在] 使用 cargo 安装 just..."
  cargo install just
  if ! echo "$PATH" | grep -q "$HOME/.cargo/bin"; then
    echo 'export PATH=$HOME/.cargo/bin:$PATH' >> ~/.bashrc
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
fi

# cmake / g++
if ! command -v cmake &>/dev/null; then
  echo "[CMake 不存在] sudo dnf install -y cmake"
  sudo dnf install -y cmake
fi
if ! command -v g++ &>/dev/null; then
  echo "[g++ 不存在] sudo dnf install -y gcc-c++"
  sudo dnf install -y gcc-c++
fi

echo "=== [B] 编译并安装 libchata (通过 just build) ==="
cd /home/yuyu/Chata
just build type='Release'

echo "=== [C] 将 /usr/local/lib 加入动态库搜索路径 ==="
if [ ! -f /etc/ld.so.conf.d/usr-local-lib.conf ]; then
  echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/usr-local-lib.conf
fi
sudo ldconfig

echo "=== [D] 回到 testfiles 目录 ==="
cd testfiles

###############################################################################
# 建立子目录：generated_s/, logs/, out_bin/
###############################################################################
GEN_S_DIR="generated_s"
LOG_DIR="logs"
BIN_DIR="out_bin"

mkdir -p "$GEN_S_DIR" "$LOG_DIR" "$BIN_DIR"

###############################################################################
# (E) 生成多种规模的 .s 文件
###############################################################################
echo "=== [E] 生成大规模 .s 文件 ==="

# 回到跟以前类似的 1,4,8,16,32,64
SCALES=(1 4 8 16 32 64)
BASE_S="16kinstrs.s"

rm -f "$GEN_S_DIR"/big_*.s

for scale in "${SCALES[@]}"; do
  OUTFILE="$GEN_S_DIR/big_${scale}x.s"
  echo "生成 $OUTFILE (scale=${scale})..."
  cat /dev/null > "$OUTFILE"
  for (( i=0; i<scale; i++ )); do
    cat "$BASE_S" >> "$OUTFILE"
  done
done

ls -lh "$GEN_S_DIR"

###############################################################################
# (F) 编译 test_libchata_perf.cpp
###############################################################################
echo "=== [F] 编写 test_libchata_perf.cpp 并编译 ==="
cat << 'EOF' > test_libchata_perf.cpp
#include <libchata.hpp>
#include <fstream>
#include <iostream>
#include <string>
#include <chrono>

static std::string readFile(const std::string &filename) {
    std::ifstream ifs(filename, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(ifs)),
                       std::istreambuf_iterator<char>());
}

int main(int argc, char** argv) {
    if(argc < 3) {
        std::cerr << "Usage: " << argv[0] << " <input.s> <outputDir>" << std::endl;
        return 1;
    }
    std::string input_file = argv[1];
    std::string out_dir = argv[2];

    std::string code = readFile(input_file);
    if (code.empty()) {
        std::cerr << "Error: " << input_file << " is empty or not found.\n";
        return 1;
    }

    auto start = std::chrono::high_resolution_clock::now();
    auto machine_code = libchata_assemble(code);
    auto end = std::chrono::high_resolution_clock::now();

    // output bin
    size_t pos = input_file.find_last_of('/');
    std::string pureName = (pos == std::string::npos) ? input_file : input_file.substr(pos+1);
    std::string out_bin = out_dir + "/" + pureName + ".chata.bin";

    std::ofstream ofs(out_bin, std::ios::binary);
    ofs.write((const char*)machine_code.data(), machine_code.size());
    ofs.close();

    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
    std::cout << "[libchata] " << input_file << " => " << out_bin
              << ", size=" << machine_code.size() 
              << ", time=" << ms << " ms" << std::endl;

    return 0;
}
EOF

g++ -std=c++20 test_libchata_perf.cpp -o test_libchata_perf \
    -I/usr/local/include -L/usr/local/lib -lchata

###############################################################################
# (G) 多轮测试
###############################################################################
echo "=== [G] 多轮性能测试  ==="

OUT_CSV="$LOG_DIR/results.csv"

# 新增 2 列: perf_cachemiss, perf_branchmiss
echo "file,lines,tool,run_index,real_time_sec,user_time_sec,sys_time_sec,perf_instructions,perf_cycles,perf_cachemiss,perf_branchmiss,output_size_bytes" > "$OUT_CSV"

RUNS=10

# 要收集四个事件: instructions,cycles,cache-misses,branch-misses
PERF_EVENTS="instructions,cycles,cache-misses,branch-misses"

for scale in "${SCALES[@]}"; do
  SFILE="$GEN_S_DIR/big_${scale}x.s"
  LINES=$(wc -l < "$SFILE" | awk '{print $1}')

  #############################################################################
  # 1) 测试 libchata
  #############################################################################
  for ((i=1; i<=RUNS; i++)); do
    echo "---- [libchata] $SFILE, run=$i ----"
    PERF_LOG="$LOG_DIR/perf_libchata_${scale}x_run${i}.log"

    /usr/bin/time -p perf stat \
      -e "$PERF_EVENTS" \
      -o "$PERF_LOG" -x ',' -- \
      ./test_libchata_perf "$SFILE" "$BIN_DIR" \
    2> time_tmp.log

    REAL_T=$(grep "^real " time_tmp.log | awk '{print $2}')
    USER_T=$(grep "^user " time_tmp.log | awk '{print $2}')
    SYS_T=$(grep "^sys " time_tmp.log | awk '{print $2}')

    # 解析 perf 输出: grep 'instructions:' / 'cycles:' / 'cache-misses:' / 'branch-misses:'
    INS=$(grep 'instructions:' "$PERF_LOG" | awk -F',' '{print $1}')
    CYC=$(grep 'cycles:'       "$PERF_LOG" | awk -F',' '{print $1}')
    CMISS=$(grep 'cache-misses:' "$PERF_LOG" | awk -F',' '{print $1}')
    BMISS=$(grep 'branch-misses:' "$PERF_LOG" | awk -F',' '{print $1}')

    # bin file
    PURE_NAME="big_${scale}x.s"
    BINFILE="$BIN_DIR/${PURE_NAME}.chata.bin"
    SIZE=0
    if [ -f "$BINFILE" ]; then
      SIZE=$(stat -c %s "$BINFILE")
    fi

    echo "${SFILE},${LINES},libchata,${i},${REAL_T},${USER_T},${SYS_T},${INS},${CYC},${CMISS},${BMISS},${SIZE}" >> "$OUT_CSV"
  done

  #############################################################################
  # 2) 测试 as + objcopy
  #############################################################################
  for ((i=1; i<=RUNS; i++)); do
    echo "---- [as+objcopy] $SFILE, run=$i ----"
    PERF_LOG="$LOG_DIR/perf_as_${scale}x_run${i}.log"

    /usr/bin/time -p perf stat \
      -e "$PERF_EVENTS" \
      -o "$PERF_LOG" -x ',' -- \
      sh -c "riscv64-unknown-elf-as $SFILE -o tmp.o && riscv64-unknown-elf-objcopy -O binary tmp.o $BIN_DIR/big_${scale}x.s.as.bin" \
    2> time_tmp.log

    REAL_T=$(grep "^real " time_tmp.log | awk '{print $2}')
    USER_T=$(grep "^user " time_tmp.log | awk '{print $2}')
    SYS_T=$(grep "^sys " time_tmp.log | awk '{print $2}')

    INS=$(grep 'instructions:' "$PERF_LOG" | awk -F',' '{print $1}')
    CYC=$(grep 'cycles:'       "$PERF_LOG" | awk -F',' '{print $1}')
    CMISS=$(grep 'cache-misses:' "$PERF_LOG" | awk -F',' '{print $1}')
    BMISS=$(grep 'branch-misses:' "$PERF_LOG" | awk -F',' '{print $1}')

    BINFILE="$BIN_DIR/big_${scale}x.s.as.bin"
    SIZE=0
    if [ -f "$BINFILE" ]; then
      SIZE=$(stat -c %s "$BINFILE")
    fi

    echo "${SFILE},${LINES},as+objcopy,${i},${REAL_T},${USER_T},${SYS_T},${INS},${CYC},${CMISS},${BMISS},${SIZE}" >> "$OUT_CSV"
  done

done

# 清理
rm -f time_tmp.log tmp.o

echo ""
echo "=== 测试完成，结果写到 $OUT_CSV ==="
echo "格式: file,lines,tool,run_index,real_time_sec,user_time_sec,sys_time_sec,perf_instructions,perf_cycles,perf_cachemiss,perf_branchmiss,output_size_bytes"
echo ""
echo "生成的 .s 文件在: $GEN_S_DIR"
echo "生成的 .bin 文件在: $BIN_DIR"
echo "所有日志和 CSV 在: $LOG_DIR"