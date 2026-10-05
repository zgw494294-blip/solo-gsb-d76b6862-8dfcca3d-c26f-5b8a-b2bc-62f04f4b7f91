#!/usr/bin/env bash
# 受控交错回归（黑盒 HTTP）：
# 同一设备两次合法声明，长度分别为 3、6；让第二次在第一次“已提交但响应
# 尚未返回”的窗口内完整落库。修复前两份响应都显示 declared_length=6，
# 修复后必须分别为 3、6，且最终数据库状态为 6（等价某种串行执行）。
#
# 复现顺序（与 test_api.py 第 12 节一致）：
#   1) 发起声明 A，等待挂点确认（declare_update.held 出现）——这才说明
#      A 已提交且停在返回前。不能用数据库可见代替：A commit 后若被调度
#      出去、尚未进入挂点，库中已可见 3，此时放 B 进来会抢先接管标记并
#      被挂起，而脚本又在等 B 返回，形成等待环；
#   2) 发竞争声明 B，等它完整返回；
#   3) 确认 A 的响应仍未返回，再删除 .held 放行 A。
# 任何一步等待超时或失败都会退出并经 trap 释放挂点，脚本不会挂死。
#
# 依赖服务以 FIRMWARE_TEST_PAUSE_DIR=<目录> 启动（见 README“并发交错复现”）。
# 纯 curl，无第三方工具（jq 仅用于美化，缺失也能跑）。
set -u

BASE=${BASE_URL:-http://localhost:8000}
PAUSE_DIR=${FIRMWARE_TEST_PAUSE_DIR:-/tmp/fw-pause}
# 每次运行使用唯一设备，避免与历史数据相互干扰（API 不提供删除）
DEV=${DEV:-race-http-$(date +%s)-$$}
OUT=${OUT_DIR:-/tmp/fw-race-out}
# 单次 HTTP 请求的最长耗时（秒）；挂点确认/请求返回的轮询上限（×0.05s）
CURL_MAX=${CURL_MAX:-30}
WAIT_MAX=${WAIT_MAX:-200}
mkdir -p "$OUT"

MARKER="$PAUSE_DIR/declare_update"
HELD="$PAUSE_DIR/declare_update.held"
PID_A=""

# 无论成功、失败还是超时，退出前都释放挂点并等后台请求收尾：
# 删除 marker 与 .held（被挂请求随即放行），不留下挂点影响后续请求。
cleanup() {
  rm -f "$HELD" "$MARKER"
  # A 若仍被挂起，.held 已删，它会自行返回；curl 有 --max-time 兜底
  [ -n "$PID_A" ] && wait "$PID_A" 2>/dev/null
  return 0
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

jqf() { if command -v jq >/dev/null 2>&1; then jq "$@"; else cat; fi; }
sha256_hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# 从整设备视图取“第一个非空 declared_length”（本例候选为 slot1；slot0 为
# 已确认槽，declared_length 为 null，不会匹配至少一位数字的模式）。
first_declared() { grep -o '"declared_length":[0-9][0-9]*' | head -1 | cut -d: -f2; }
req() { # method path [json-body]
  if [ -n "${3:-}" ]; then
    curl -sS --max-time "$CURL_MAX" -X "$1" "$BASE$2" -H 'Content-Type: application/json' -d "$3"
  else
    curl -sS --max-time "$CURL_MAX" -X "$1" "$BASE$2"
  fi
}

echo ">> 健康检查"
curl -fsS --max-time 5 "$BASE/health" >/dev/null || { echo "服务未就绪：$BASE/health"; exit 1; }

echo ">> 设备：$DEV"
echo ">> 创建设备（初始镜像 base）"
INIT_B64=$(printf 'base' | base64 | tr -d '\n')
req POST /devices "$(printf '{"device_id":"%s","initial_image_base64":"%s"}' "$DEV" "$INIT_B64")" \
  | jqf '.slots' >/dev/null

SHA3=$(sha256_hex abc)
SHA6=$(sha256_hex abcdef)

echo ">> 清理并放置挂点标记：$MARKER"
mkdir -p "$PAUSE_DIR"
rm -f "$MARKER" "$HELD"      # 清掉上次异常运行可能残留的标记，避免误判挂点确认
: > "$MARKER"
: > "$OUT/respA.json"        # 清空历史输出，下面的“未返回”判断以本文件为准
: > "$OUT/respB.json"

echo ">> 发起声明 A（length=3），它会在提交后阻塞在挂点上"
( req PUT "/devices/$DEV/update" "$(printf '{"length":3,"sha256":"%s"}' "$SHA3")" \
    > "$OUT/respA.json" ) &
PID_A=$!

echo ">> 等待挂点确认：$HELD 出现（= A 已提交且停在返回前）"
for _ in $(seq 1 "$WAIT_MAX"); do
  [ -e "$HELD" ] && break
  # A 若未命中挂点就已返回（服务未开启挂点？），不必空等
  [ -s "$OUT/respA.json" ] && break
  sleep 0.05
done
[ -e "$HELD" ] || fail "未等到挂点确认（A 未停在提交后挂点）。服务需以 FIRMWARE_TEST_PAUSE_DIR=$PAUSE_DIR 启动"
[ -s "$OUT/respA.json" ] && fail "A 在挂点确认前已返回，交错不成立"
echo "   确认：A 已提交且停在返回前（挂点已接管标记）"

echo ">> 发起竞争声明 B（length=6），等它完整返回"
req PUT "/devices/$DEV/update" "$(printf '{"length":6,"sha256":"%s"}' "$SHA6")" > "$OUT/respB.json" \
  || fail "B 请求失败（curl 异常或超时）"
LB=$(first_declared < "$OUT/respB.json")
[ "$LB" = "6" ] || fail "B 自身响应应为 6，实际：$LB"

echo ">> B 已完成；确认 A 的响应仍未返回"
[ -s "$OUT/respA.json" ] && fail "A 在放行前已返回，交错不成立"

echo ">> 删除 $HELD，放行 A"
rm -f "$HELD"
for _ in $(seq 1 "$WAIT_MAX"); do
  [ -s "$OUT/respA.json" ] && break
  sleep 0.05
done
[ -s "$OUT/respA.json" ] || fail "放行后 A 仍未返回"
wait "$PID_A" 2>/dev/null
PID_A=""

LA=$(first_declared < "$OUT/respA.json")
FINAL=$(req GET "/devices/$DEV" | first_declared)

echo
echo "A 响应 declared_length = $LA   （期望 3）"
echo "B 响应 declared_length = $LB   （期望 6）"
echo "最终数据库 declared_length = $FINAL （期望 6）"
echo
[ "$LA" = 3 ] && [ "$LB" = 6 ] && [ "$FINAL" = 6 ] \
  && { echo "PASS：响应快照彼此独立，终态等价串行执行（A -> B）。"; exit 0; } \
  || { echo "FAIL：并发响应混入了后续写入。"; echo "-- A 响应 --"; cat "$OUT/respA.json"; exit 1; }
