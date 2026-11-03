#!/usr/bin/env bash
set -Eeuo pipefail
deadline=$((SECONDS + ${READINESS_TIMEOUT_SEC:-180}))
consecutive=0
last='服务正在启动'
while (( SECONDS < deadline )); do
  matched=false
  for base in http://127.0.0.1 http://127.0.0.1:8080; do
    response="$(curl -sS --max-time 3 -w $'\n%{http_code}' "${base}/api/readiness" 2>/dev/null || true)"
    status="${response##*$'\n'}"
    if [[ "$status" == 200 ]] && grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' <<<"$response"; then matched=true;break;fi
    if [[ "$status" == 404 && "${ALLOW_LEGACY_READINESS:-false}" == true ]] && curl -fsS --max-time 3 "${base}/api/health" >/dev/null 2>&1; then
      echo '[ready] 旧版本仅支持存活检查，无法据此验证全部业务推进。'
      matched=true;break
    fi
    if [[ "$status" == 503 ]];then last="${response%$'\n'*}";fi
    if [[ "$status" == 401 || "$status" == 403 ]];then last="就绪接口返回 ${status}，请核对实际镜像版本和入口访问配置；旧版 API 可能尚未完成升级。";fi
  done
  if [[ "$matched" == true ]];then consecutive=$((consecutive+1));else consecutive=0;fi
  if (( consecutive >= 2 ));then echo '[ready] 数据库和 Worker 连续就绪检查通过。';exit 0;fi
  sleep 2
done
echo "[ready] 等待就绪超时：${last}"
echo '[ready] 请查看 docker compose 容器状态及 api/worker 日志；未自动重发广告或回滚数据。'
exit 33
