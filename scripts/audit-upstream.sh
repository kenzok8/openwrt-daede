#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

repo_input=${1:-$PWD}
repo=$(cd "$repo_input" && pwd -P)
audit_tmp=$(mktemp -d "${TMPDIR:-/tmp}/openwrt-daede-audit.XXXXXX")
trap 'rm -rf "$audit_tmp"' EXIT INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for command_name in awk curl diff git go patch sed sort tar; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing required command: $command_name"
done

hash_command=""
if command -v sha256sum >/dev/null 2>&1; then
    hash_command=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    hash_command=shasum
else
    fail "missing sha256sum or shasum"
fi

[[ -f "$repo/ci/pins.env" ]] || fail "missing $repo/ci/pins.env"
[[ -f "$repo/dae/Makefile" ]] || fail "missing $repo/dae/Makefile"
[[ -f "$repo/daed/Makefile" ]] || fail "missing $repo/daed/Makefile"

required_pin_vars=(
    DAE_VERSION DAED_VERSION DAED_COMMIT WING_COMMIT CORE_COMMIT
    CORE_UPSTREAM_COMMIT OUTBOUND_COMMIT QUICGO_BASE_COMMIT QUICGO_PERF_TIP
)
while IFS= read -r pins_line || [[ -n "$pins_line" ]]; do
    [[ -z "$pins_line" || "$pins_line" == \#* ]] && continue
    [[ "$pins_line" =~ ^([A-Z][A-Z0-9_]*)=([0-9A-Za-z._-]+)$ ]] || fail "invalid ci/pins.env line"
    pin_name=${BASH_REMATCH[1]}
    pin_value=${BASH_REMATCH[2]}
    case "$pin_name" in
        DAE_VERSION|DAED_VERSION|DAED_COMMIT|WING_COMMIT|CORE_COMMIT|CORE_UPSTREAM_COMMIT|OUTBOUND_COMMIT|QUICGO_BASE_COMMIT|QUICGO_PERF_TIP) ;;
        *) fail "unexpected pin in ci/pins.env: $pin_name" ;;
    esac
    seen_var="seen_$pin_name"
    [[ -z "${!seen_var:-}" ]] || fail "duplicate pin in ci/pins.env: $pin_name"
    printf -v "$seen_var" '%s' 1
    printf -v "$pin_name" '%s' "$pin_value"
done < "$repo/ci/pins.env"

for pin_var in "${required_pin_vars[@]}"; do
    [[ -n "${!pin_var:-}" ]] || fail "missing pin: $pin_var"
done

require_sha() {
    local name=$1 value=${!1}
    [[ "$value" =~ ^[0-9a-f]{40}$ ]] || fail "$name must be a full lowercase commit SHA"
}

for sha_var in DAED_COMMIT WING_COMMIT CORE_COMMIT CORE_UPSTREAM_COMMIT \
    OUTBOUND_COMMIT QUICGO_BASE_COMMIT QUICGO_PERF_TIP; do
    require_sha "$sha_var"
done

make_value() {
    local file=$1 key=$2
    sed -n "s/^${key}:=//p" "$file" | sed -n '1p'
}

hash_file() {
    if [ "$hash_command" = sha256sum ]; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

for package in dae daed; do
    makefile="$repo/$package/Makefile"
    version=$(make_value "$makefile" PKG_VERSION)
    pins_version=$(printf '%s' "$package" | tr '[:lower:]' '[:upper:]')_VERSION
    [[ "$version" = "${!pins_version}" ]] || fail "$package Makefile version does not match ci/pins.env"
    source=$(make_value "$makefile" PKG_SOURCE)
    source_url=$(make_value "$makefile" PKG_SOURCE_URL)
    source_hash=$(make_value "$makefile" PKG_HASH)
    [[ "$source" =~ ^${package}-src-${version}-[0-9a-f]{12}\.tar\.gz$ ]] || \
        fail "$package Makefile has an invalid content-addressed PKG_SOURCE"
    [[ "$source_url" =~ ^https://github\.com/kenzok8/openwrt-daede/releases/download/${package}-src/?$ ]] || \
        fail "$package Makefile has an unexpected PKG_SOURCE_URL"
    [[ "$source_hash" =~ ^[0-9a-f]{64}$ ]] || fail "$package Makefile has an invalid PKG_HASH"
    source_id=${source##*-}
    source_id=${source_id%.tar.gz}
    [[ "$source_id" = "${source_hash:0:12}" ]] || \
        fail "$package PKG_SOURCE id does not match PKG_HASH"
done

patch_dirs=(
    dae/patches
    dae/patches_arm
    daed/patches
    daed/patches_arm
    ci/patches/daed-web
    ci/patches/outbound
    ci/patches/quic-go
    .github/patches
)
shopt -s nullglob
patch_count=0
actual_patches="$audit_tmp/actual-patches.txt"
: > "$actual_patches"
for patch_dir in "${patch_dirs[@]}"; do
    [[ -d "$repo/$patch_dir" ]] || fail "missing patch directory: $patch_dir"
    patch_files=("$repo/$patch_dir"/*.patch)
    if ((${#patch_files[@]} == 0)); then
        continue
    fi
    for patch_file in "${patch_files[@]}"; do
        [ -f "$patch_file" ] || continue
        patch_count=$((patch_count + 1))
        printf '%s\n' "${patch_file#"$repo"/}" >> "$actual_patches"
    done
done
(( patch_count > 0 )) || fail "no patches found in the patch directories"
[[ -f "$repo/ci/patches/expected.txt" ]] || fail "missing expected patch inventory"
sort -o "$actual_patches" "$actual_patches"
diff -u "$repo/ci/patches/expected.txt" "$actual_patches" || fail "patch inventory changed; review it before updating expected.txt"

processed_count=0
absorbed_count=0
record_absorbed() {
    absorbed_count=$((absorbed_count + 1))
    printf 'ABSORBED: %s\n' "${1#"$repo"/}" >&2
}

apply_tree_patches() {
    local target=$1 patch_dir=$2 count_inventory=${3:-yes} patch_file
    patch_files=("$repo/$patch_dir"/*.patch)
    ((${#patch_files[@]} == 0)) && return 0
    for patch_file in "${patch_files[@]}"; do
        [ -f "$patch_file" ] || continue
        if [ "$count_inventory" = yes ]; then
            processed_count=$((processed_count + 1))
        fi
        if patch -p1 -d "$target" --dry-run -R -f <"$patch_file" >/dev/null 2>&1; then
            record_absorbed "$patch_file"
        elif patch -p1 -d "$target" --dry-run -f <"$patch_file" >/dev/null 2>&1; then
            patch -p1 -d "$target" -f <"$patch_file" >/dev/null
            printf 'APPLIED: %s\n' "${patch_file#"$repo"/}"
        else
            fail "${patch_file#"$repo"/} neither reverse-applies nor forward-applies"
        fi
    done
}

download_source() {
    local package=$1 makefile="$repo/$1/Makefile" source source_url source_hash archive extract_dir actual_hash
    source=$(make_value "$makefile" PKG_SOURCE)
    source_url=$(make_value "$makefile" PKG_SOURCE_URL)
    source_hash=$(make_value "$makefile" PKG_HASH)
    archive="$audit_tmp/$package.tar.gz"
    extract_dir="$audit_tmp/$package-source"
    mkdir -p "$extract_dir"
    printf 'FETCH: %s\n' "$source" >&2
    curl -fsSL --retry 3 -o "$archive" "${source_url%/}/$source" || fail "failed to download $source"
    actual_hash=$(hash_file "$archive")
    [[ "$actual_hash" = "$source_hash" ]] || fail "$package source hash mismatch"
    tar -xzf "$archive" -C "$extract_dir" || fail "failed to extract $source"
    printf '%s\n' "$extract_dir/$package-$(make_value "$makefile" PKG_VERSION)"
}

dae_source=$(download_source dae)
[[ -d "$dae_source/core" ]] || fail "missing assembled dae core: $dae_source/core"
cp -a "$dae_source" "$audit_tmp/dae-arm"
apply_tree_patches "$dae_source/core" dae/patches
apply_tree_patches "$audit_tmp/dae-arm/core" dae/patches_arm

daed_source=$(download_source daed)
[[ -d "$daed_source/wing" ]] || fail "missing assembled daed wing: $daed_source/wing"
for patch_file in "$repo"/ci/patches/daed-web/*.patch; do
    processed_count=$((processed_count + 1))
    patch -p1 -d "$daed_source" --dry-run -R -f <"$patch_file" >/dev/null 2>&1 || \
        fail "${patch_file#"$repo"/} missing from assembled daed web source"
    printf 'EMBEDDED: %s\n' "${patch_file#"$repo"/}"
done
cp -a "$daed_source" "$audit_tmp/daed-arm"
apply_tree_patches "$daed_source/wing" daed/patches
apply_tree_patches "$audit_tmp/daed-arm/wing" daed/patches no_count
apply_tree_patches "$audit_tmp/daed-arm/wing" daed/patches_arm

# A patch can still apply after upstream has added the same Go API with
# different surrounding comments. Compile config before the SDK gate.
printf 'BUILD: daed core config\n'
(cd "$daed_source/wing/dae-core" && go test -c -o "$audit_tmp/daed-config.test" ./config)

fetch_exact() {
    local url=$1 commit=$2 target=$3 resolved
    git init -q "$target"
    git -C "$target" remote add origin "$url"
    git -C "$target" fetch -q --depth=1 origin "$commit" || fail "cannot fetch $commit from $url"
    git -C "$target" checkout -q --detach FETCH_HEAD
    resolved=$(git -C "$target" rev-parse HEAD)
    [[ "$resolved" = "$commit" ]] || fail "resolved $resolved instead of requested $commit"
}

outbound_dir="$audit_tmp/outbound"
quic_dir="$audit_tmp/quic-go"
printf 'FETCH: outbound %s\n' "$OUTBOUND_COMMIT"
fetch_exact https://github.com/kenzok8/outbound "$OUTBOUND_COMMIT" "$outbound_dir"
printf 'FETCH: quic-go %s\n' "$QUICGO_BASE_COMMIT"
fetch_exact https://github.com/kenzok8/quic-go "$QUICGO_BASE_COMMIT" "$quic_dir"

quic_version=$(awk '/github\.com\/olicesx\/quic-go/ {
    for (i = 1; i <= NF; i++) if ($i ~ /^v[0-9]/) { print $i; exit }
}' "$outbound_dir/go.mod")
[[ -n "$quic_version" ]] || fail "outbound go.mod does not pin github.com/olicesx/quic-go"
quic_suffix=${quic_version##*-}
expected_suffix=$(printf '%.12s' "$QUICGO_BASE_COMMIT")
[[ "$quic_suffix" = "$expected_suffix" ]] || fail "outbound requires quic-go $quic_suffix but QUICGO_BASE_COMMIT starts with $expected_suffix"
[[ "$QUICGO_PERF_TIP" = "$QUICGO_BASE_COMMIT" ]] || fail "QUICGO_PERF_TIP and QUICGO_BASE_COMMIT must move together"

apply_git_patches() {
    local target=$1 patch_dir=$2 patch_file
    patch_files=("$repo/$patch_dir"/*.patch)
    ((${#patch_files[@]} == 0)) && return 0
    for patch_file in "${patch_files[@]}"; do
        [ -f "$patch_file" ] || continue
        processed_count=$((processed_count + 1))
        if git -C "$target" apply --check -R "$patch_file" >/dev/null 2>&1; then
            record_absorbed "$patch_file"
        elif git -C "$target" apply --check "$patch_file" >/dev/null 2>&1; then
            git -C "$target" apply "$patch_file"
            printf 'APPLIED: %s\n' "${patch_file#"$repo"/}"
        else
            fail "${patch_file#"$repo"/} neither reverse-applies nor forward-applies"
        fi
    done
}

apply_git_patches "$outbound_dir" ci/patches/outbound
printf 'TEST: outbound SSR\n'
(cd "$outbound_dir" && go test ./protocol/shadowsocks_stream/)
apply_git_patches "$quic_dir" ci/patches/quic-go
printf 'BUILD: quic-go ./...\n'
(cd "$quic_dir" && go build ./...)

sdk_action_sha=44f98c51d04aebd1aa79fe4f603559c1ec2085da
grep -Fq "ref: $sdk_action_sha" "$repo/.github/workflows/release.yml" || \
    fail "release.yml does not use the audited SDK action"
sdk_action_dir="$audit_tmp/gh-action-sdk"
printf 'FETCH: gh-action-sdk %s\n' "$sdk_action_sha"
fetch_exact https://github.com/kenzok8/gh-action-sdk "$sdk_action_sha" "$sdk_action_dir"
apply_git_patches "$sdk_action_dir" .github/patches

[[ "$processed_count" -eq "$patch_count" ]] || fail "processed $processed_count of $patch_count patches"
[[ "$absorbed_count" -eq 0 ]] || fail "$absorbed_count patch(es) appear absorbed upstream"
printf 'PASS patches=%d absorbed=0\n' "$patch_count"
