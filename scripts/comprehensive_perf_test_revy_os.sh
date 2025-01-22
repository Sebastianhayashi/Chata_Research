#!/usr/bin/env bash
set -e

###############################################################################
# comprehensive_fixed_test.sh
#
# 针对“行数统计不准确”问题进行了改进：
# 1) 检查 16kinstrs.s 是否确实有 16k 行以上；
# 2) 使用 cat "$SFILE" | wc -l 来统计行数；
# 3) 其余逻辑与原脚本类似：在 Debian/Ubuntu/RevyOS 上装依赖 -> 编译 Chatassembler ->
#    生成多倍 .s -> 多次测试 (RUNS=10, SCALES=1..64) -> 用 perf 收集 -> 结果写 logs/results.csv
###############################################################################

echo "=== [A] 检测并安装依赖 (apt-get) ==="

# perf
if ! command -v perf &>/dev/null; then
  echo "[perf 不存在] 尝试 apt-get 安装 perf (或 linux-perf, linux-tools-*)..."
  sudo apt-get update
  sudo apt-get install -y linux-perf || {
    echo "在 Debian/Ubuntu 环境中可能需安装 'linux-tools-common' 或 'linux-perf-<内核版本>' 等，请根据报错调整。"
    exit 1
  }
fi

# cargo + rust
if ! command -v cargo &>/dev/null; then
  echo "[Cargo 不存在] 尝试用 apt-get 安装 rustc + cargo..."
  sudo apt-get update
  sudo apt-get install -y rustc cargo || {
    echo "无法安装 rust/cargo, 请手动安装后再试。"
    exit 1
  }
fi

# just
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
  echo "[CMake 不存在] sudo apt-get install -y cmake"
  sudo apt-get update
  sudo apt-get install -y cmake
fi
if ! command -v g++ &>/dev/null; then
  echo "[g++ 不存在] sudo apt-get install -y g++ build-essential"
  sudo apt-get update
  sudo apt-get install -y g++ build-essential
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
# 确保 16kinstrs.s 真的有足够行数 (至少 16000 行)
###############################################################################
BASE_S="16kinstrs.s"
MIN_LINES=16000  # 期望至少 16k 行
actual_lines=$(cat "$BASE_S" | wc -l || echo 0)

if [ "$actual_lines" -lt "$MIN_LINES" ]; then
  echo "错误：$BASE_S 实际只有 $actual_lines 行，低于 $MIN_LINES 行，无法做大规模测试。"
  echo "请检查是否使用了正确的 16kinstrs.s (应该有至少 16k 行)."
  exit 1
else
  echo "$BASE_S 文件行数=$actual_lines, 符合预期."
fi

###############################################################################
# 创建目录：generated_s/, logs/, out_bin/
###############################################################################
GEN_S_DIR="generated_s"
LOG_DIR="logs"
BIN_DIR="out_bin"

mkdir -p "$GEN_S_DIR" "$LOG_DIR" "$BIN_DIR"

###############################################################################
# (E) 生成多种规模的 .s 文件
###############################################################################
echo "=== [E] 生成多种规模 .s 文件 ==="

SCALES=(1 4 8 16 32 64)

rm -f "$GEN_S_DIR"/big_*.s

for scale in "${SCALES[@]}"; do
  OUTFILE="$GEN_S_DIR/big_${scale}x.s"
  echo "生成 $OUTFILE (scale=${scale})..."
  > "$OUTFILE"  # 清空或创建
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

    // 写出到 bin/xxx.chata.bin
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
# (G) 多轮性能测试
###############################################################################
echo "=== [G] 多轮性能测试 ==="

OUT_CSV="$LOG_DIR/results.csv"

echo "file,lines,tool,run_index,real_time_sec,user_time_sec,sys_time_sec,perf_instructions,perf_cycles,perf_cachemiss,perf_branchmiss,output_size_bytes" > "$OUT_CSV"

RUNS=10
PERF_EVENTS="instructions,cycles,cache-misses,branch-misses"

for scale in "${SCALES[@]}"; do
  SFILE="$GEN_S_DIR/big_${scale}x.s"

  # 改用 cat "$SFILE" | wc -l 来统计行数
  LINES=$(cat "$SFILE" | wc -l)

  #-----------------------------
  # 1) libchata
  #-----------------------------
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

    INS=$(grep 'instructions:' "$PERF_LOG" | awk -F',' '{print $1}')
    CYC=$(grep 'cycles:'       "$PERF_LOG" | awk -F',' '{print $1}')
    CMISS=$(grep 'cache-misses:' "$PERF_LOG" | awk -F',' '{print $1}')
    BMISS=$(grep 'branch-misses:' "$PERF_LOG" | awk -F',' '{print $1}')

    PURE_NAME="big_${scale}x.s"
    BINFILE="$BIN_DIR/${PURE_NAME}.chata.bin"
    SIZE=0
    if [ -f "$BINFILE" ]; then
      # 注意: 在某些系统, stat用法可能不同
      SIZE=$(stat -c %s "$BINFILE" 2>/dev/null || stat -f %z "$BINFILE")
    fi

    echo "${SFILE},${LINES},libchata,${i},${REAL_T},${USER_T},${SYS_T},${INS},${CYC},${CMISS},${BMISS},${SIZE}" >> "$OUT_CSV"
  done

  #-----------------------------
  # 2) as + objcopy
  #-----------------------------
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
      SIZE=$(stat -c %s "$BINFILE" 2>/dev/null || stat -f %z "$BINFILE")
    fi

    echo "${SFILE},${LINES},as+objcopy,${i},${REAL_T},${USER_T},${SYS_T},${INS},${CYC},${CMISS},${BMISS},${SIZE}" >> "$OUT_CSV"
  done

done

rm -f time_tmp.log tmp.o

echo ""
echo "=== 测试完成，结果已写到 $OUT_CSV ==="
echo "格式: file,lines,tool,run_index,real_time_sec,user_time_sec,sys_time_sec,perf_instructions,perf_cycles,perf_cachemiss,perf_branchmiss,output_size_bytes"
echo ""
echo "生成的 .s 文件在: $GEN_S_DIR"
echo "生成的 .bin 文件在: $BIN_DIR"
echo "所有日志和 CSV 在: $LOG_DIR"