#!/usr/bin/env bash
set -e

###############################################################################
# comprehensive_new_test.sh
#
# 使用 yum 安装依赖 -> 编译 just -> 通过 just build 编译 Chatassembler ->
# 生成不同规模 .s 文件 (1x,4x,8x...) -> 进行测试(减少shell启动次数) ->
# 输出到 logs/ + bin_s/ + results.csv
###############################################################################

echo "=== [1] 检测/安装依赖 (yum) ==="

# perf
if ! command -v perf &>/dev/null; then
  echo "[perf 不存在] 尝试用 yum 安装..."
  sudo yum install -y perf || echo "请手动安装 perf"
fi

# cargo & rust
if ! command -v cargo &>/dev/null; then
  echo "[Cargo 不存在] 尝试用 yum 安装 rust + cargo..."
  sudo yum install -y rust cargo || {
    echo "无法安装 cargo, 请手工安装后再试"
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

# cmake / gcc-c++
if ! command -v cmake &>/dev/null; then
  echo "[cmake 不存在] sudo yum install -y cmake"
  sudo yum install -y cmake
fi
if ! command -v g++ &>/dev/null; then
  echo "[g++ 不存在] sudo yum install -y gcc-c++"
  sudo yum install -y gcc-c++
fi

echo "=== [2] just build Chatassembler ==="
cd /home/yuyu/Chata
just build type='Release'

echo "=== [3] 将 /usr/local/lib 加入动态库搜索路径 ==="
if [ ! -f /etc/ld.so.conf.d/usr-local-lib.conf ]; then
  echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/usr-local-lib.conf
fi
sudo ldconfig

echo "=== [4] 回到 testfiles 目录 ==="
cd testfiles

###############################################################################
# 生成多种规模 .s 文件
###############################################################################
GEN_S_DIR="gen_s"
LOG_DIR="logs"
BIN_DIR="bin_s"

mkdir -p "$GEN_S_DIR" "$LOG_DIR" "$BIN_DIR"

echo "=== [5] 生成多规模的 .s 文件 ==="
SCALES=(1 4 8 16 32)
BASE_S="16kinstrs.s"

rm -f "$GEN_S_DIR"/big_*.s
for scale in "${SCALES[@]}"; do
  OUTFILE="$GEN_S_DIR/big_${scale}x.s"
  echo "生成 $OUTFILE (scale=${scale})..."
  cat /dev/null > "$OUTFILE"
  for ((i=0; i<scale; i++)); do
    cat "$BASE_S" >> "$OUTFILE"
  done
done

ls -lh "$GEN_S_DIR"

###############################################################################
# 编写一个 test_libchata_perf.cpp (可复用)
###############################################################################
echo "=== [6] 编写 test_libchata_perf.cpp 并编译 ==="

cat << 'EOF' > test_libchata_perf.cpp
#include <libchata.hpp>
#include <fstream>
#include <iostream>
#include <chrono>
#include <string>

static std::string readFile(const std::string &filename) {
    std::ifstream ifs(filename, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(ifs)),
                       std::istreambuf_iterator<char>());
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <input.s>" << std::endl;
        return 1;
    }
    std::string input_file = argv[1];
    std::string code = readFile(input_file);
    if (code.empty()) {
        std::cerr << "Error: " << input_file << " is empty.\n";
        return 1;
    }

    auto start = std::chrono::steady_clock::now();
    auto machine_code = libchata_assemble(code);
    auto end = std::chrono::steady_clock::now();

    // 输出
    std::cout << "[libchata] " << input_file << " => size=" 
              << machine_code.size() << ", time_ms="
              << std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count()
              << "\n";

    // 这里不写.bin了，只测 parse时间; 如需写bin,可加 ofs write
    return 0;
}
EOF

g++ -std=c++20 test_libchata_perf.cpp -o test_libchata_perf \
    -I/usr/local/include -L/usr/local/lib -lchata

echo "=== [7] 开始测试并把结果输出到 results.csv ==="
OUT_CSV="$LOG_DIR/results.csv"
echo "file,lines,tool,run_index,real_time_sec,user_time_sec,sys_time_sec,perf_instructions,perf_cycles,cache_miss,branch_miss" > "$OUT_CSV"

RUNS=5    # 可改10
PERF_EVENTS="instructions,cycles,cache-misses,branch-misses"

################################################################################
# 设计思路：减少 shell 启动次数
# -> 我们一次就对 each scale 做 RUNS 次 chatassembler & as+objcopy
#    并且只perf/time包裹一个内部循环
################################################################################

for scale in "${SCALES[@]}"; do
  SFILE="$GEN_S_DIR/big_${scale}x.s"
  LINES=$(wc -l < "$SFILE")

  ##############################################################################
  # 1) libchata: 在一次shell进程中循环 RUNS 次
  ##############################################################################
  echo "---- [libchata] scale=$scale ----"
  PERF_LOG="$LOG_DIR/perf_libchata_${scale}x.log"

  # 这里写个临时脚本 run_libchata.sh, 循环 RUNS 次
  cat <<EOF2 > run_libchata.sh
#!/usr/bin/env bash
for i in \$(seq 1 $RUNS); do
  echo "run=\$i"
  ./test_libchata_perf "$SFILE"
done
EOF2
  chmod +x run_libchata.sh

  # 用 perf stat 包裹 run_libchata.sh
  /usr/bin/time -p perf stat -e "$PERF_EVENTS" -o "$PERF_LOG" -x ',' -- \
    sh run_libchata.sh \
  2> time_tmp.log

  # 解析 time
  REAL_T=$(grep "^real " time_tmp.log | awk '{print $2}')
  USER_T=$(grep "^user " time_tmp.log | awk '{print $2}')
  SYS_T=$(grep "^sys " time_tmp.log | awk '{print $2}')

  # 解析 perf
  INS=$(grep 'instructions:' "$PERF_LOG" | awk -F',' '{print $1}')
  CYC=$(grep 'cycles:'        "$PERF_LOG" | awk -F',' '{print $1}')
  CMISS=$(grep 'cache-misses:' "$PERF_LOG" | awk -F',' '{print $1}')
  BMISS=$(grep 'branch-misses:' "$PERF_LOG" | awk -F',' '{print $1}')

  # 把这个统一作为(汇总)写入1行
  echo "${SFILE},${LINES},libchata,ALL,${REAL_T},${USER_T},${SYS_T},${INS},${CYC},${CMISS},${BMISS}" >> "$OUT_CSV"

  # 2) as+objcopy
  echo "---- [as+objcopy] scale=$scale ----"
  PERF_LOG2="$LOG_DIR/perf_as_${scale}x.log"

  # 写个 run_as.sh, 也循环 RUNS 次
  cat <<EOF3 > run_as.sh
#!/usr/bin/env bash
for i in \$(seq 1 $RUNS); do
  echo "run=\$i"
  riscv64-unknown-elf-as "$SFILE" -o tmp.o
  riscv64-unknown-elf-objcopy -O binary tmp.o /dev/null
done
EOF3
  chmod +x run_as.sh

  /usr/bin/time -p perf stat -e "$PERF_EVENTS" -o "$PERF_LOG2" -x ',' -- \
    sh run_as.sh \
  2> time_tmp.log

  REAL_T=$(grep "^real " time_tmp.log | awk '{print $2}')
  USER_T=$(grep "^user " time_tmp.log | awk '{print $2}')
  SYS_T=$(grep "^sys " time_tmp.log | awk '{print $2}')

  INS=$(grep 'instructions:' "$PERF_LOG2" | awk -F',' '{print $1}')
  CYC=$(grep 'cycles:'         "$PERF_LOG2" | awk -F',' '{print $1}')
  CMISS=$(grep 'cache-misses:' "$PERF_LOG2" | awk -F',' '{print $1}')
  BMISS=$(grep 'branch-misses:' "$PERF_LOG2" | awk -F',' '{print $1}')

  echo "${SFILE},${LINES},as+objcopy,ALL,${REAL_T},${USER_T},${SYS_T},${INS},${CYC},${CMISS},${BMISS}" >> "$OUT_CSV"

  rm -f run_libchata.sh run_as.sh time_tmp.log tmp.o
done

echo "=== 测试完成，结果在 $OUT_CSV ==="