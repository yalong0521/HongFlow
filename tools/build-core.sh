#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TASK_WORK_DIR=${HONGFLOW_WORK_DIR:-"$PROJECT_DIR/work/kernel-build"}
NATIVE_SDK=${OHOS_NATIVE_SDK:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}
GO_REVISION=302a5306b6fad2f47196360b82561d1db1f954cf
CORE_REVISION=8597778c7df410ebe88c57e59eaab32d203156df
CA_BUNDLE="$PROJECT_DIR/native/core/certificates/cacert-2026-09-25.pem"
CA_SHA256=a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
# Keep trust roots reproducible: never build with the upstream's empty embed file.
CA_ACTUAL_SHA256=$(shasum -a 256 "$CA_BUNDLE" | cut -d ' ' -f1)
if [[ "$CA_ACTUAL_SHA256" != "$CA_SHA256" ]]; then
 echo "Pinned Mozilla CA bundle checksum mismatch" >&2
 exit 1
fi
mkdir -p "$TASK_WORK_DIR"
fetch_pinned() {
 local checkout=$1 remote=$2 revision=$3
 if [[ ! -d "$checkout/.git" ]]; then git init -q "$checkout"; git -C "$checkout" remote add origin "$remote"; fi
 if ! git -C "$checkout" cat-file -e "$revision^{commit}" 2>/dev/null; then git -C "$checkout" fetch --depth 1 origin "$revision"; fi
 git -C "$checkout" checkout --detach "$revision"
}
# OHOS uses musl. Stock Go's initial-exec TLS cannot be dlopened by an ArkTS app.
# This pinned OpenHarmony-SIG compiler includes the ARM64 general dynamic TLS fix.
fetch_pinned "$TASK_WORK_DIR/ohos-go" https://gitcode.com/openharmony-sig/ohos_golang_go.git "$GO_REVISION"
if [[ ! -x "$TASK_WORK_DIR/ohos-go/bin/go" ]]; then
 GOROOT_BOOTSTRAP=$(go env GOROOT)
 export GOROOT_BOOTSTRAP
 (cd "$TASK_WORK_DIR/ohos-go/src" && ./make.bash)
fi
fetch_pinned "$TASK_WORK_DIR/mihomo" https://github.com/chen08209/Clash.Meta.git "$CORE_REVISION"
cp "$CA_BUNDLE" "$TASK_WORK_DIR/mihomo/component/ca/ca-certificates.crt"
cp "$PROJECT_DIR/native/core/patches/hongflow_embed.go.in" "$TASK_WORK_DIR/mihomo/hub/route/hongflow_embed.go"
# The fixed FlClash fork starts Initial in goroutines; the native Start contract
# must wait for those resources before checking provider counts or opening TUN.
for PATCH_NAME in provider-load-wait.patch profile-validation.patch; do
 CORE_PATCH="$PROJECT_DIR/native/core/patches/$PATCH_NAME"
 if ! git -C "$TASK_WORK_DIR/mihomo" apply --reverse --check "$CORE_PATCH" 2>/dev/null; then
  git -C "$TASK_WORK_DIR/mihomo" apply "$CORE_PATCH"
 fi
done
mkdir -p "$TASK_WORK_DIR/wrapper"
cp "$PROJECT_DIR/native/core/main.go" "$PROJECT_DIR/native/core/main_test.go" "$PROJECT_DIR/native/core/go.mod" "$PROJECT_DIR/native/core/go.sum" "$TASK_WORK_DIR/wrapper/"
GO_BIN="$TASK_WORK_DIR/ohos-go/bin/go"
GOTOOLCHAIN=local "$GO_BIN" -C "$TASK_WORK_DIR/wrapper" mod edit -replace "github.com/metacubex/mihomo=$TASK_WORK_DIR/mihomo"
cat > "$TASK_WORK_DIR/cc-ohos" <<COMPILER
#!/bin/sh
exec "$NATIVE_SDK/llvm/bin/clang" --target=aarch64-linux-ohos --sysroot="$NATIVE_SDK/sysroot" "\$@"
COMPILER
chmod +x "$TASK_WORK_DIR/cc-ohos"
mkdir -p "$PROJECT_DIR/entry/libs/arm64-v8a"
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local CC="$TASK_WORK_DIR/cc-ohos" \
 "$GO_BIN" -C "$TASK_WORK_DIR/wrapper" build -mod=mod -trimpath -tags netgo \
 -ldflags '-s -w -X github.com/metacubex/mihomo/constant.Version=FlClash-v0.8.99-8597778-ohos -extldflags=-Wl,-soname,libhongflow_core.so' \
 -buildmode=c-shared -o "$PROJECT_DIR/entry/libs/arm64-v8a/libhongflow_core.so" .
"$NATIVE_SDK/llvm/bin/llvm-readelf" -d "$PROJECT_DIR/entry/libs/arm64-v8a/libhongflow_core.so"
