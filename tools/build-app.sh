#!/usr/bin/env bash
set -euo pipefail
HONGFLOW_PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
HONGFLOW_STUDIO=${HONGFLOW_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}
export DEVECO_SDK_HOME="$HONGFLOW_STUDIO/sdk"
export OHOS_NATIVE_SDK="${OHOS_NATIVE_SDK:-$DEVECO_SDK_HOME/default/openharmony/native}"
cd "$HONGFLOW_PROJECT_DIR"
if [[ ! -f entry/libs/arm64-v8a/libhongflow_core.so ]]; then
  "$HONGFLOW_PROJECT_DIR/tools/build-core.sh"
fi
"$HONGFLOW_STUDIO/tools/ohpm/bin/ohpm" install --all
"$HONGFLOW_STUDIO/tools/node/bin/node" "$HONGFLOW_STUDIO/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p buildMode="${1:-debug}" assembleHap --no-daemon
