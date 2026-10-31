#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'promote-candidate: %s\n' "$*" >&2
    exit 1
}

for name in BASE_SHA CANDIDATE_SHA BUILD_RUN_ID STAGING R2_ACCESS_KEY_ID \
    R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET AGGREGATE_FEED_TOKEN GH_TOKEN; do
    [[ -n "${!name:-}" ]] || fail "missing $name"
done
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid base SHA"
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid candidate SHA"
[[ "$BUILD_RUN_ID" =~ ^[0-9]+$ ]] || fail "invalid build run ID"
[[ "$STAGING" =~ ^auto-bump-staging-[0-9]+-[0-9]+$ ]] || fail "invalid staging branch"
[[ -f publish/manifest.json ]] || fail "missing verified manifest"
jq -e --arg sha "$CANDIDATE_SHA" --argjson run "$BUILD_RUN_ID" \
    '.candidate_sha == $sha and .build_run_id == $run and (.files | length > 0)' \
    publish/manifest.json >/dev/null || fail "manifest does not identify this candidate and build"
cp publish/manifest.json publish/feed/release-manifest.json

# 完整验证来源校验：用 GitHub API 证明 candidate 经过了其发布通道要求的验证
#（代码修复为 audit、单构建、16 目标矩阵；上游同步还包含两次 assemble）。
# verification.json 只做关联，证明来自 API。fail-closed，发生在改动 main 之前。
MANIFEST_PATH="$PWD/publish/manifest.json" \
    bash "$(dirname "$0")/verify-candidate.sh"

git fetch -q origin refs/heads/main
remote_main=$(git ls-remote origin refs/heads/main | cut -f1)
[[ "$remote_main" = "$BASE_SHA" || "$remote_main" = "$CANDIDATE_SHA" ]] || fail "main moved; candidate must be rebuilt"
# 冻结语义：candidate 由 tag 标识，不再依赖 staging 分支位置。
# staging 分支在冻结后可能已移动（新同步开始），不影响本次晋升。
candidate_tag_sha=$(git ls-remote origin "refs/tags/candidate/${CANDIDATE_SHA}" | cut -f1)
[[ "$candidate_tag_sha" = "$CANDIDATE_SHA" ]] || fail "candidate tag missing or moved"
git fetch -q origin "$CANDIDATE_SHA"
git merge-base --is-ancestor "$BASE_SHA" "$CANDIDATE_SHA" || fail "candidate does not descend from its base"

aggregate_workflow=$(GH_TOKEN="$AGGREGATE_FEED_TOKEN" gh api \
    'repos/kenzok8/openwrt-clashoo/contents/.github/workflows/aggregate-feed.yml?ref=main' \
    -H 'Accept: application/vnd.github.raw+json') || fail "cannot read aggregate workflow"
grep -Fq 'candidate_sha:' <<< "$aggregate_workflow" || fail "aggregate workflow lacks candidate identity gate"
grep -Fq 'build_run_id:' <<< "$aggregate_workflow" || fail "aggregate workflow lacks build identity gate"

version=$(git show "$CANDIDATE_SHA:ci/pins.env" | sed -n 's/^DAE_VERSION=//p')
[[ "$version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || fail "invalid candidate version"
tag="v${version}-${CANDIDATE_SHA:0:7}"
remote_tag=$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)
if [[ -z "$remote_tag" ]]; then
    remote_tag=$(git ls-remote --tags origin "refs/tags/$tag" | cut -f1)
fi
[[ -z "$remote_tag" || "$remote_tag" = "$CANDIDATE_SHA" ]] || fail "tag $tag points to another commit"

# Stage and verify the exact candidate bytes before changing main or a release.
rclone_dir=$(mktemp -d)
trap 'rm -rf "$rclone_dir"' EXIT
chmod 700 "$rclone_dir"
cat > "$rclone_dir/rclone.conf" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
no_check_bucket = true
EOF
chmod 600 "$rclone_dir/rclone.conf"
export RCLONE_CONFIG="$rclone_dir/rclone.conf"
stage="r2:${R2_BUCKET}/openwrt-feed/daed-candidates/${CANDIDATE_SHA}"
probe="r2:${R2_BUCKET}/openwrt-feed/daed-candidates/.write-probe-${GITHUB_RUN_ID:-$BUILD_RUN_ID}"
rclone copyto publish/manifest.json "$probe"
rclone deletefile "$probe"
# --checksum：按内容比对。promote 重试时本地 publish/ 是重新生成的，
# 文件 mtime 与 stage 里已上传的不同，只按时间戳比对会被 --immutable 误判为已修改。
rclone copy publish/ "$stage/" --immutable --checksum --fast-list
# verification.json 是 gate 写入 stage 的验证记录（元数据，不属于发布内容，
# 本地 publish/ 由构建产物生成、不含此文件），校验时排除。
rclone check publish/ "$stage/" --download --fast-list --exclude verification.json

# The unified feed also carries luci-app-daede from jell. Its version must not
# supersede this candidate after main and the tag have moved.
for candidate in publish/feed/*/*/luci-app-daede*.apk publish/feed/*/*/luci-app-daede*.ipk; do
    [[ -f "$candidate" ]] || continue
    relative=${candidate#publish/feed/}
    directory=${relative%/*}
    candidate_name=${candidate##*/}
    rclone lsf "r2:${R2_BUCKET}/openwrt-feed/jell/${directory}/" \
        --files-only --include 'luci-app-daede*' > "$rclone_dir/jell-package-list" || \
        fail "cannot inspect jell packages in $directory"
    while IFS= read -r existing_name; do
        [[ -n "$existing_name" ]] || continue
        newest=$(printf '%s\n%s\n' "$candidate_name" "$existing_name" | sort -V | tail -1)
        [[ "$newest" = "$candidate_name" ]] || \
            fail "jell has a newer luci-app-daede in $directory: $existing_name"
    done < "$rclone_dir/jell-package-list"
done

state="r2:${R2_BUCKET}/openwrt-feed/daed-release-state"
pending="$state/pending.json"
manifest_digest=$(sha256sum publish/manifest.json | cut -d' ' -f1)
jq -n --arg sha "$CANDIDATE_SHA" --arg base "$BASE_SHA" \
    --arg staging "$STAGING" --arg tag "$tag" \
    --arg digest "$manifest_digest" --argjson run "$BUILD_RUN_ID" \
    '{candidate_sha:$sha,base_sha:$base,staging:$staging,tag:$tag,build_run_id:$run,manifest_sha256:$digest}' \
    > "$rclone_dir/pending.json"
if rclone lsf "$state/" --files-only > "$rclone_dir/state-listing" 2>/dev/null; then
    state_listing=$(cat "$rclone_dir/state-listing")
else
    fail "cannot list release state in R2"
fi
if printf '%s\n' "$state_listing" | grep -Fxq pending.json; then
    rclone cat "$pending" > "$rclone_dir/existing-pending.json"
    cmp -s "$rclone_dir/pending.json" "$rclone_dir/existing-pending.json" || \
        fail "another release is pending"
else
    rclone copyto "$rclone_dir/pending.json" "$pending" --immutable
    rclone cat "$pending" > "$rclone_dir/existing-pending.json"
    cmp -s "$rclone_dir/pending.json" "$rclone_dir/existing-pending.json" || \
        fail "pending release state differs after upload"
fi

if [[ "$remote_main" = "$CANDIDATE_SHA" && -z "$remote_tag" && "$BASE_SHA" = "$CANDIDATE_SHA" ]]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git tag -a "$tag" "$CANDIDATE_SHA" -m "Release $tag"
    git -c credential.helper='!gh auth git-credential' push origin "refs/tags/$tag:refs/tags/$tag"
elif [[ "$remote_main" = "$BASE_SHA" && -z "$remote_tag" ]]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git tag -a "$tag" "$CANDIDATE_SHA" -m "Release $tag"
    git -c credential.helper='!gh auth git-credential' push --atomic \
        --force-with-lease="refs/heads/main:$BASE_SHA" origin \
        "$CANDIDATE_SHA:refs/heads/main" "refs/tags/$tag:refs/tags/$tag"
    [[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$CANDIDATE_SHA" ]] || fail "main did not advance to candidate"
elif [[ "$remote_main" != "$CANDIDATE_SHA" || "$remote_tag" != "$CANDIDATE_SHA" ]]; then
    fail "main and tag do not identify the same verified candidate"
fi

notes="$rclone_dir/release-notes.md"
BASE="https://github.com/kenzok8/openwrt-daede/releases/download/${tag}"
ARCHS="aarch64_cortex-a53 aarch64_cortex-a72 aarch64_generic arm_cortex-a7_neon-vfpv4 arm_cortex-a9 arm_cortex-a9_neon i386_pentium4 x86_64"
cell_ipk() {
    pkg="$1"; arch="$2"; fallback="$3"
    f=$(ls publish/release/${pkg}_*_${arch}.ipk 2>/dev/null | head -1)
    [ -n "$f" ] && echo "[$(basename $f)](${BASE}/$(basename $f))" || echo "$fallback"
}
cell_apk() {
    pkg="$1"; arch="$2"
    f=$(ls publish/release/${pkg}-*-${arch}.apk 2>/dev/null | head -1)
    [ -n "$f" ] && echo "[$(basename $f)](${BASE}/$(basename $f))" || echo "—"
}
noarch_ipk() {
    pkg="$1"
    f=$(ls publish/release/${pkg}_*_all.ipk 2>/dev/null | head -1)
    [ -n "$f" ] && echo "[$(basename $f)](${BASE}/$(basename $f))" || echo "—"
}
{
    printf '# openwrt-daede %s\n\n' "$tag"
    printf 'Pinned upstream dae/daed release from candidate `%s`.\n\n' "$CANDIDATE_SHA"
    printf 'All 16 SDK targets passed the patch audit and package gate. Build run: %s.\n\n' "$BUILD_RUN_ID"
    echo "## Packages / 安装包"
    echo ""
    echo "## 📦 SDK 24.10 · 稳定版 (IPK)"
    echo ""
    echo "| 架构 | dae | daed | luci-app-daede |"
    echo "| :--- | :--- | :--- | :--- |"
    luci_fallback=$(noarch_ipk luci-app-daede)
    for arch in $ARCHS; do
        echo "| \`${arch}\` | $(cell_ipk dae $arch —) | $(cell_ipk daed $arch —) | $(cell_ipk luci-app-daede $arch "$luci_fallback") |"
    done
    echo ""
    echo "## 📦 SDK 25.12 · 稳定版 (APK)"
    echo ""
    echo "| 架构 | dae | daed | luci-app-daede |"
    echo "| :--- | :--- | :--- | :--- |"
    for arch in $ARCHS; do
        echo "| \`${arch}\` | $(cell_apk dae $arch) | $(cell_apk daed $arch) | $(cell_apk luci-app-daede $arch) |"
    done
} > "$notes"
if ! gh release view "$tag" >/dev/null 2>&1; then
    gh release create "$tag" --draft --verify-tag --target "$CANDIDATE_SHA" \
        --title "Release $tag" --notes-file "$notes"
fi
release_target=$(gh release view "$tag" --json targetCommitish --jq '.targetCommitish')
[[ "$release_target" = "$CANDIDATE_SHA" || "$release_target" = "$tag" ]] || fail "Release target differs from candidate"
for asset in publish/release/* publish/manifest.json; do
    [[ -f "$asset" ]] || fail "missing release asset"
    name=${asset##*/}
    if gh release view "$tag" --json assets --jq '.assets[].name' | grep -Fxq "$name"; then
        existing="$rclone_dir/$name"
        gh release download "$tag" --pattern "$name" --output "$existing"
        cmp -s "$asset" "$existing" || fail "Release asset differs: $name"
    else
        gh release upload "$tag" "$asset"
    fi
done
{
    find publish/release -maxdepth 1 -type f -printf '%f\n'
    printf 'manifest.json\n'
} | sort > "$rclone_dir/expected-assets"
gh release view "$tag" --json assets --jq '.assets[].name' | sort > "$rclone_dir/actual-assets"
diff -u "$rclone_dir/expected-assets" "$rclone_dir/actual-assets" || fail "Release has unexpected or missing assets"

feed="r2:${R2_BUCKET}/openwrt-feed/daed"
echo "=== [R2] uploading daed feed ==="
rclone sync publish/feed/ "$feed/" --checksum --fast-list --transfers 8 --checkers 16
echo "=== [R2] verifying uploaded daed feed ==="
rclone check publish/feed/ "$feed/" --download --fast-list
echo "=== [R2] daed feed upload verified ==="

# 聚合阶段：单接口轮询 + 共享截止时间 + 派发歧义处理。
# gh run watch 每 3 秒同时打 run/jobs 两个接口，一次聚合（实测 35 分钟 ~ 2 小时）
# 就吃掉个人令牌 5000/h 的近半额度，所以这里自己轮询，并按响应头等额度恢复。
API_ROOT="https://api.github.com"
AGGREGATE_REPO="kenzok8/openwrt-clashoo"
AGGREGATE_WORKFLOW="aggregate-feed.yml"
AGGREGATE_POLL_INTERVAL="${AGGREGATE_POLL_INTERVAL:-60}"
AGGREGATE_WAIT_TIMEOUT="${AGGREGATE_WAIT_TIMEOUT:-10800}"
aggregate_state="$state/aggregate.json"
aggregate_intent="$state/aggregate-intent.json"
aggregate_tmp="$rclone_dir/aggregate"
mkdir -p "$aggregate_tmp"
# 整个聚合阶段（含重派）共用这一个截止时间，重派不会重新计时。
aggregate_deadline=$((SECONDS + AGGREGATE_WAIT_TIMEOUT))
api_headers=(
    -H "Authorization: Bearer $AGGREGATE_FEED_TOKEN"
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
)

deadline_check() {
    [ "$SECONDS" -lt "$aggregate_deadline" ] || \
        fail "aggregate stage exceeded ${AGGREGATE_WAIT_TIMEOUT}s"
}

# 单次请求的超时不超过剩余时间，避免请求本身把阶段拖过界。
request_timeout() {
    local left=$((aggregate_deadline - SECONDS))
    deadline_check
    if [ "$left" -gt 60 ]; then
        left=60
    fi
    printf '%s\n' "$left"
}

# api_request <METHOD> <PATH> [JSON]：结果落在 api_code / api_body，响应头进 aggregate_tmp/hdr。
api_request() {
    local method=$1 path=$2 body=${3:-} timeout
    local -a args
    timeout=$(request_timeout) || exit 1
    : > "$aggregate_tmp/hdr"
    : > "$aggregate_tmp/body"
    args=(-sS --max-time "$timeout" --connect-timeout 10 -X "$method" "${api_headers[@]}"
        -D "$aggregate_tmp/hdr" -o "$aggregate_tmp/body" -w '%{http_code}')
    if [ -n "$body" ]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi
    api_code=$(curl "${args[@]}" "$API_ROOT$path") || api_code=000
    api_body=$(cat "$aggregate_tmp/body" 2>/dev/null || :)
}

header_value() {
    awk -v want="$1" 'tolower($1) == tolower(want) ":" { v = $2 } END { print v }' \
        "$aggregate_tmp/hdr" 2>/dev/null | tr -d '\r'
}

# 403 既可能是限流也可能是权限不足：只有带限流证据的才等，权限错误直接失败。
rate_limited() {
    [ -n "$(header_value retry-after)" ] && return 0
    [ "$(header_value x-ratelimit-remaining)" = 0 ] && return 0
    return 1
}

# 等待时长：优先 retry-after，其次按 x-ratelimit-reset 算到额度恢复。
rate_limit_delay() {
    local retry_after reset now delay
    retry_after=$(header_value retry-after)
    reset=$(header_value x-ratelimit-reset)
    now=$(date +%s)
    case "$retry_after" in ''|*[!0-9]*) retry_after= ;; esac
    case "$reset" in ''|*[!0-9]*) reset= ;; esac
    if [ -n "$retry_after" ]; then
        delay=$((retry_after + 5))
    elif [ -n "$reset" ] && [ "$reset" -gt "$now" ]; then
        delay=$((reset - now + 10))
    else
        delay=$AGGREGATE_POLL_INTERVAL
    fi
    printf '%s\n' "$delay"
}

# 所有等待都受共享截止时间约束。
sleep_for() {
    local secs=$1 left
    deadline_check
    left=$((aggregate_deadline - SECONDS))
    [ "$secs" -le "$left" ] || secs=$left
    echo "=== [aggregate] waiting ${secs}s ===" >&2
    sleep "$secs"
}

iso_utc() {
    if date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
        date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
    else
        date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
    fi
}

# 第 n 次重试的退避：15、30、60、120、240 秒，封顶 300。
backoff_delay() {
    local delay=$((15 << $1))
    [ "$delay" -le 300 ] || delay=300
    printf '%s\n' "$delay"
}

new_dispatch_id() {
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# 按派发标识认领 run：display_title（来自 aggregate 的 run-name）必须同时
# 带上本候选、构建编号和唯一 dispatch id；只凭时间窗口会把别人的手动派发误认进来。
aggregate_locate_run() {
    local iso=$1 dispatch_id=$2 ids count i=0
    while [ "$i" -lt 6 ]; do
        api_request GET "/repos/$AGGREGATE_REPO/actions/workflows/$AGGREGATE_WORKFLOW/runs?event=workflow_dispatch&per_page=50"
        case "$api_code" in
            200) ;;
            403|429)
                if rate_limited; then sleep_for "$(rate_limit_delay)"; i=$((i + 1)); continue; fi
                fail "cannot list aggregate runs (HTTP $api_code): $api_body" ;;
            401|404)
                fail "cannot list aggregate runs (HTTP $api_code): $api_body" ;;
            5*|000)
                sleep_for "$(backoff_delay "$i")"; i=$((i + 1)); continue ;;
            *)
                fail "cannot list aggregate runs (HTTP $api_code): $api_body" ;;
        esac
        ids=$(jq -r --arg since "$iso" --arg sha "$CANDIDATE_SHA" \
            --argjson build "$BUILD_RUN_ID" --arg did "$dispatch_id" \
            '.workflow_runs[]
             | select(.created_at >= $since)
             | select((.display_title // "") | contains($did))
             | select((.display_title // "") | contains($sha))
             | select((.display_title // "") | contains($build | tostring))
             | .id' <<< "$api_body") || fail "cannot parse aggregate run list"
        count=$(printf '%s\n' "$ids" | grep -c . || true)
        case "$count" in
            0) sleep_for "$AGGREGATE_POLL_INTERVAL"; i=$((i + 1)); continue ;;
            1) printf '%s\n' "$ids"; return 0 ;;
            *) fail "several aggregate runs match this dispatch ($(printf '%s' "$ids" | tr '\n' ' ')); resolve manually" ;;
        esac
    done
    return 0
}

# 单个 run 的单接口轮询。
aggregate_poll() {
    local run=$1 attempt=0
    while :; do
        api_request GET "/repos/$AGGREGATE_REPO/actions/runs/$run"
        case "$api_code" in
            200)
                printf '%s %s\n' "$(jq -r '.status' <<< "$api_body")" \
                    "$(jq -r '.conclusion // "-"' <<< "$api_body")"
                return 0 ;;
            401|404) fail "aggregate run $run inaccessible (HTTP $api_code): $api_body" ;;
            403|429)
                if rate_limited; then
                    sleep_for "$(rate_limit_delay)"
                else
                    fail "aggregate run $run forbidden (HTTP $api_code): $api_body"
                fi ;;
            5*|000)
                attempt=$((attempt + 1))
                [ "$attempt" -le 5 ] || fail "aggregate run $run polling keeps failing (HTTP $api_code)"
                sleep_for "$(backoff_delay $((attempt - 1)))" ;;
            *)
                fail "aggregate run $run polling failed (HTTP $api_code): $api_body" ;;
        esac
    done
}

aggregate_wait() {
    local run=$1 line
    while :; do
        line=$(aggregate_poll "$run") || exit 1
        case "$line" in
            "completed "*) printf '%s\n' "${line#completed }"; return 0 ;;
        esac
        sleep_for "$AGGREGATE_POLL_INTERVAL"
    done
}

# 读 R2 状态目录；查询失败必须停，不能把“查不到”当“没有记录”。
state_files() {
    rclone lsf "$state/" --files-only > "$aggregate_tmp/state-listing" 2>/dev/null || \
        fail "cannot list release state in R2"
    cat "$aggregate_tmp/state-listing"
}

# 确认未接受的派发：清掉意图记录并复查，让重跑能干净重派。
# 复查要先取结果再判断：fail 在管道子进程里退出，外层 if 只会看到非零。
aggregate_discard_intent() {
    local remaining
    rclone deletefile "$aggregate_intent" || fail "cannot delete aggregate dispatch intent"
    remaining=$(state_files) || exit 1
    if printf '%s\n' "$remaining" | grep -Fxq aggregate-intent.json; then
        fail "aggregate dispatch intent still present after delete"
    fi
}

# marker 写不进去就不能报成功：重跑时靠它接上已派发的 run。
aggregate_record_run() {
    local run=$1 did=$2
    jq -n --arg sha "$CANDIDATE_SHA" --argjson build "$BUILD_RUN_ID" \
        --argjson run "$run" --arg did "$did" \
        '{candidate_sha:$sha,build_run_id:$build,aggregate_run_id:$run,dispatch_id:$did}' \
        > "$aggregate_tmp/state.json" || fail "cannot build aggregate state for run $run"
    rclone copyto "$aggregate_tmp/state.json" "$aggregate_state" --immutable || \
        fail "cannot record aggregate run $run in R2"
    rclone cat "$aggregate_state" > "$aggregate_tmp/state.readback.json" || \
        fail "cannot read back aggregate state for run $run"
    cmp -s "$aggregate_tmp/state.json" "$aggregate_tmp/state.readback.json" || \
        fail "aggregate state differs after upload"
    # 意图记录没清干净有两重后果：重派时 --immutable 会被旧文件拦住；
    # 发布后残留会挡住下一个候选。所以删除失败要停。
    aggregate_discard_intent
}

# 历史候选的包副本没人再消费（release 里有同样的字节），只保留 JSON 元数据。
# 只是瘦身，失败不影响发布正确性，所以告警而不阻断。
prune_candidate_staging() {
    local base="r2:${R2_BUCKET}/openwrt-feed/daed-candidates" listing dir
    if ! listing=$(rclone lsf "$base/" --dirs-only 2>&1); then
        echo "warning: cannot list candidate staging: $listing" >&2
        return 0
    fi
    for dir in $(printf '%s\n' "$listing" | tr -d '/'); do
        [ -n "$dir" ] || continue
        if [ "$dir" = "$CANDIDATE_SHA" ]; then
            continue
        fi
        if ! rclone delete "$base/$dir/" --include '*.ipk' --include '*.apk' 2>/dev/null; then
            echo "warning: cannot prune staged packages for $dir" >&2
        fi
    done
}

# 发布落地后清聚合状态，残留会挡住下一个候选。
aggregate_cleanup_state() {
    local listing
    rclone deletefile "$aggregate_state" || fail "cannot delete aggregate state after publishing"
    listing=$(state_files) || exit 1
    if printf '%s\n' "$listing" | grep -E '^(aggregate\.json|aggregate-intent\.json)$' >/dev/null; then
        fail "aggregate state still present after publishing: $(printf '%s' "$listing" | tr '\n' ' ')"
    fi
}

# 派发聚合。顺序是「先落意图，再 POST」：POST 之后、marker 之前进程死掉，
# 重跑也能靠意图记录（候选 + 构建编号 + dispatch id + 查找起点）找回那个 run。
# 204 拿不到 run id，响应丢失更不知道发没发出去，两条路都走「按 dispatch id 认领」。
aggregate_dispatch() {
    local body since iso run dispatch_id attempt=0
    dispatch_id=$(new_dispatch_id)
    [ -n "$dispatch_id" ] || fail "cannot generate dispatch id"
    since=$(date +%s)
    iso=$(iso_utc "$since")
    jq -n --arg sha "$CANDIDATE_SHA" --argjson build "$BUILD_RUN_ID" \
        --arg did "$dispatch_id" --arg since "$iso" \
        '{candidate_sha:$sha,build_run_id:$build,dispatch_id:$did,since:$since}' \
        > "$aggregate_tmp/intent.json" || fail "cannot build aggregate dispatch intent"
    rclone copyto "$aggregate_tmp/intent.json" "$aggregate_intent" --immutable || \
        fail "cannot record aggregate dispatch intent in R2"
    rclone cat "$aggregate_intent" > "$aggregate_tmp/intent.readback.json" || \
        fail "cannot read back aggregate dispatch intent"
    cmp -s "$aggregate_tmp/intent.json" "$aggregate_tmp/intent.readback.json" || \
        fail "aggregate dispatch intent differs after upload"
    body=$(jq -n --arg sha "$CANDIDATE_SHA" --argjson run "$BUILD_RUN_ID" --arg did "$dispatch_id" \
        '{ref:"main",inputs:{candidate_sha:$sha,build_run_id:($run|tostring),dispatch_id:$did}}') || \
        fail "cannot build aggregate dispatch payload"
    while :; do
        api_request POST "/repos/$AGGREGATE_REPO/actions/workflows/$AGGREGATE_WORKFLOW/dispatches" "$body"
        case "$api_code" in
            204) ;;
            403|429)
                if rate_limited; then
                    attempt=$((attempt + 1))
                    if [ "$attempt" -gt 2 ]; then
                        aggregate_discard_intent
                        fail "aggregate dispatch still rate limited; retry later"
                    fi
                    # 403 说明没被接受，等额度恢复后重派是安全的。
                    sleep_for "$(rate_limit_delay)"
                    continue
                fi
                aggregate_discard_intent
                fail "cannot dispatch aggregate feed (HTTP $api_code): $api_body" ;;
            4*)
                # 4xx（含 401/404 和 422 这种上游未接 dispatch_id）肯定没被接受。
                aggregate_discard_intent
                fail "cannot dispatch aggregate feed (HTTP $api_code): $api_body" ;;
            *)
                # 结果不明（网络中断、5xx）：保留意图记录，让重跑去认领。
                echo "=== [aggregate] dispatch outcome unknown (HTTP $api_code); looking for the run ===" >&2 ;;
        esac
        run=$(aggregate_locate_run "$iso" "$dispatch_id") || exit 1
        if [ -n "$run" ]; then
            break
        fi
        fail "no aggregate run matches dispatch id $dispatch_id; check GitHub before retrying"
    done
    aggregate_record_run "$run" "$dispatch_id"
    printf '%s\n' "$run"
}

# 聚合跑完复核统一 feed 索引：确认合进去的 daed 就是本候选的字节。
# 身份认领靠 dispatch id；这一步兜底校验聚合结果确实落了盘。
aggregate_verify_merged() {
    local arch="24.10/x86_64" expect got
    expect=$(jq -r --arg p "feed/$arch/" \
        '.files[] | select(.path | startswith($p)) | select(.path | test("/daed_[^/]*\\.ipk$")) | .sha256' \
        publish/manifest.json)
    [[ "$expect" =~ ^[0-9a-f]{64}$ ]] || fail "manifest lacks the daed package for $arch"
    rclone cat "r2:${R2_BUCKET}/openwrt-feed/${arch}/Packages" > "$aggregate_tmp/merged-Packages" || \
        fail "cannot read unified feed index for $arch"
    got=$(awk '/^Package: daed$/ { f = 1 } f && /^SHA256(sum)?: / { print $2; exit }' \
        "$aggregate_tmp/merged-Packages")
    [ "$got" = "$expect" ] || \
        fail "unified feed daed sha256 ($got) does not match this candidate ($expect)"
    echo "=== [aggregate] unified feed carries this candidate ($arch) ==="
}

# 读 R2 状态：查询失败必须停——把“查不到”当“没有记录”会导致重复派发。
state_listing=$(state_files) || exit 1

aggregate_run=""
if printf '%s\n' "$state_listing" | grep -Fxq aggregate.json; then
    rclone cat "$aggregate_state" > "$aggregate_tmp/state.json" || fail "cannot read aggregate state from R2"
    if jq -e --arg sha "$CANDIDATE_SHA" --argjson run "$BUILD_RUN_ID" \
        '.candidate_sha == $sha and .build_run_id == $run and (.aggregate_run_id | type == "number")' \
        "$aggregate_tmp/state.json" >/dev/null; then
        aggregate_run=$(jq -r .aggregate_run_id "$aggregate_tmp/state.json")
        echo "=== [aggregate] resuming dispatched run $aggregate_run ==="
        # 同一候选的意图记录不该和 marker 共存；存了就说明上次删除失败，清掉。
        if printf '%s\n' "$state_listing" | grep -Fxq aggregate-intent.json; then
            rclone cat "$aggregate_intent" > "$aggregate_tmp/intent.json" || \
                fail "cannot read aggregate intent from R2"
            jq -e --arg did "$(jq -r .dispatch_id "$aggregate_tmp/state.json")" \
                '.dispatch_id == $did' "$aggregate_tmp/intent.json" >/dev/null || \
                fail "aggregate intent does not match the recorded run"
            aggregate_discard_intent
        fi
    else
        # pending.json 槽位已保证没有并发发布，这里只可能是上次放弃的残留。
        echo "=== [aggregate] discarding stale aggregate state ===" >&2
        rclone deletefile "$aggregate_state" || fail "cannot delete stale aggregate state"
        # 同一批残留里可能还有别的候选留下的意图记录，留着会挡住新的派发。
        if printf '%s\n' "$state_listing" | grep -Fxq aggregate-intent.json; then
            aggregate_discard_intent
        fi
    fi
elif printf '%s\n' "$state_listing" | grep -Fxq aggregate-intent.json; then
    # 上次 POST 之后、marker 落地前就断了：按意图记录的 dispatch id 认领 run，
    # 认领不到就停（模糊重派会多跑一次两小时的聚合）。
    rclone cat "$aggregate_intent" > "$aggregate_tmp/intent.json" || \
        fail "cannot read aggregate intent from R2"
    jq -e --arg sha "$CANDIDATE_SHA" --argjson run "$BUILD_RUN_ID" \
        '.candidate_sha == $sha and .build_run_id == $run and (.dispatch_id | length > 0) and (.since | length > 0)' \
        "$aggregate_tmp/intent.json" >/dev/null || \
        fail "aggregate intent belongs to another candidate; inspect R2 state"
    intent_since=$(jq -r .since "$aggregate_tmp/intent.json")
    intent_did=$(jq -r .dispatch_id "$aggregate_tmp/intent.json")
    echo "=== [aggregate] recovering previous dispatch $intent_did ==="
    aggregate_run=$(aggregate_locate_run "$intent_since" "$intent_did") || exit 1
    [ -n "$aggregate_run" ] || \
        fail "cannot find the run for dispatch $intent_did; inspect GitHub before retrying"
    aggregate_record_run "$aggregate_run" "$intent_did"
fi
redispatched=0
while :; do
    if [ -z "$aggregate_run" ]; then
        aggregate_run=$(aggregate_dispatch) || exit 1
        echo "=== [aggregate] dispatched run $aggregate_run ==="
    fi
    aggregate_conclusion=$(aggregate_wait "$aggregate_run") || exit 1
    [ "$aggregate_conclusion" = success ] && break
    # 已派发的聚合失败或被取消：清掉记录重派一次，再失败就放弃等人工判断。
    echo "=== [aggregate] run $aggregate_run ended as $aggregate_conclusion ===" >&2
    rclone deletefile "$aggregate_state" || fail "cannot delete aggregate state"
    state_recheck=$(state_files) || exit 1
    if printf '%s\n' "$state_recheck" | grep -Fxq aggregate.json; then
        fail "aggregate state still present after delete"
    fi
    [ "$redispatched" -eq 0 ] || fail "aggregate feed failed twice; investigate before retrying"
    redispatched=1
    aggregate_run=""
done
aggregate_verify_merged
gh release edit "$tag" --draft=false --prerelease=false
# 冻结 tag 已完成使命（v* tag + release 才是 durable 引用）；删掉防止累积。
# 失败不致命：prune 工作流会清理 7 天以上的残留 candidate tag。
git -c credential.helper='!gh auth git-credential' push origin \
    --delete "refs/tags/candidate/${CANDIDATE_SHA}" 2>/dev/null \
    || echo "warning: cannot delete candidate tag (non-fatal)"
# staging 分支同样只是 gate 阶段的临时工作区；发布成功后一并删除，
# 防止 auto-bump-staging-* 累积。先核对远端 staging 仍指向本次候选，
# 避免误删已移动的同名分支；删除失败不致命。
if [ "$(git ls-remote origin "refs/heads/${STAGING}" | cut -f1)" = "$CANDIDATE_SHA" ]; then
    git -c credential.helper='!gh auth git-credential' push origin \
        --delete "refs/heads/${STAGING}" 2>/dev/null \
        || echo "warning: cannot delete staging branch (non-fatal)"
else
    echo "staging branch ${STAGING} no longer points at ${CANDIDATE_SHA}; leaving it"
fi
# --checksum：promote 中断后重跑时文件已存在但内容相同，按内容比对可幂等。
rclone copyto "$rclone_dir/pending.json" "$state/completed/${CANDIDATE_SHA}.json" --immutable --checksum
rclone cat "$state/completed/${CANDIDATE_SHA}.json" > "$rclone_dir/completed.json"
cmp -s "$rclone_dir/pending.json" "$rclone_dir/completed.json" || fail "completion state differs"
# 聚合状态残留会挡住下一个候选；清理完再释放 pending 槽位。
aggregate_cleanup_state
prune_candidate_staging
rclone deletefile "$pending"
printf 'promoted %s from build %s\n' "$tag" "$BUILD_RUN_ID"
