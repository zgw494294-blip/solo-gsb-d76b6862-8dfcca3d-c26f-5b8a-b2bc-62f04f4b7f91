#!/usr/bin/env bash
# 受控交错回归（黑盒 HTTP）：
# 同一设备两次合法声明，长度分别为 3、6；让第二次在第一次“已提交但响应
# 尚未返回”的窗口内完整落库。修复前两份响应都显示 declared_length=6，
# 修复后必须分别为 3、6，且最终数据库状态为 6（等价某种串行执行）。
#
# 依赖服务以 FIRMWARE_TEST_PAUSE_DIR=<目录> 启动（见 README“并发交错复现”）。
# 纯 curl，无第三方工具（jq 仅用于美化，缺失也能跑）。
set -u

BASE=${BASE_URL:-http://localhost:8000}
PAUSE_DIR=${FIRMWARE_TEST_PAUSE_DIR:-/tmp/fw-pause}
# 每次运行使用唯一设备，避免与历史数据相互干扰（API 不提供删除）
DEV=${DEV:-race-http-$(date +%s)-$$}
OUT=${OUT_DIR:-/tmp/fw-race-out}
mkdir -p "$OUT"

jqf() { if command -v jq >/dev/null 2>&1; then jq "$@"; else cat; fi; }
sha256_hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# 从整设备视图取“第一个非空 declared_length”（本例候选为 slot1；slot0 为
# 已确认槽，declared_length 为 null，不会匹配至少一位数字的模式）。
first_declared() { grep -o '"declared_length":[0-9][0-9]*' | head -1 | cut -d: -f2; }
req() { # method path [json-body]
  if [ -n "${3:-}" ]; then
    curl -sS -X "$1" "$BASE$2" -H 'Content-Type: application/json' -d "$3"
  else
    curl -sS -X "$1" "$BASE$2"
  fi
}

echo ">> 健康检查"
curl -fsS "$BASE/health" >/dev/null || { echo "服务未就绪：$BASE/health"; exit 1; }

echo ">> 设备：$DEV"
echo ">> 创建设备（初始镜像 base）"
INIT_B64=$(printf 'base' | base64 | tr -d '\n')
req POST /devices "$(printf '{"device_id":"%s","initial_image_base64":"%s"}' "$DEV" "$INIT_B64")" \
  | jqf '.slots' >/dev/null

SHA3=$(sha256_hex abc)
SHA6=$(sha256_hex abcdef)

echo ">> 放置挂点标记：$PAUSE_DIR/declare_update"
mkdir -p "$PAUSE_DIR"
: > "$PAUSE_DIR/declare_update"

echo ">> 发起声明 A（length=3），它会在提交后阻塞在挂点上"
( req PUT "/devices/$DEV/update" "$(printf '{"length":3,"sha256":"%s"}' "$SHA3")" \
    > "$OUT/respA.json" ) &
PID_A=$!

echo ">> 等待 A 的写入落库（轮询 GET 看到 declared_length=3）"
for _ in $(seq 1 200); do
  L=$(req GET "/devices/$DEV" | first_declared)
  [ "$L" = "3" ] && break
  sleep 0.05
done
[ "$L" = "3" ] || { echo "未等到 A 落库"; rm -f "$PAUSE_DIR/declare_update" "$PAUSE_DIR/declare_update.held"; exit 1; }
echo "   A 已提交（库中=3），但响应尚未返回"

echo ">> 在 A 返回前，完整执行声明 B（length=6）"
req PUT "/devices/$DEV/update" "$(printf '{"length":6,"sha256":"%s"}' "$SHA6")" > "$OUT/respB.json"
LB=$(first_declared < "$OUT/respB.json")
[ "$LB" = "6" ] || { echo "B 自身响应应为 6，实际：$LB"; rm -f "$PAUSE_DIR/declare_update" "$PAUSE_DIR/declare_update.held"; exit 1; }

echo ">> 删除标记，放行 A 返回"
rm -f "$PAUSE_DIR/declare_update" "$PAUSE_DIR/declare_update.held"
wait "$PID_A"

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
