#!/usr/bin/env bash
#
# verify-candidate.sh — 用 GitHub API 证明一个候选经过了完整验证。
#
# 验收标准：未经完整验证的候选无法晋升（fail-closed）。
# verification.json 只是关联信息；证明来自对 GitHub API 的核对：
# 受信任的验证 workflow、run attempt、对应 job 的成功状态、
# 以及每项验证实际验证的 candidate SHA。
#
# 环境变量：
#   BASE_SHA           候选构建时的 main SHA（必填）
#   CANDIDATE_SHA      待晋升的候选 SHA（必填）
#   STAGING            候选构建使用的 staging 分支（必填）
#   GH_TOKEN           GitHub token，需 actions:read（必填）
#   R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT / R2_BUCKET（必填，
#                      用于下载 verification.json；rclone 需已配置好）
#   MANIFEST_PATH      prepare-release-assets.py 生成的 publish/manifest.json（必填）
#   REPO               仓库，默认 kenzok8/openwrt-daede
#
# 任一核对失败即 exit 1，且发生在改动 main 之前的阶段调用。

set -euo pipefail

fail() {
    printf 'verify-candidate: %s\n' "$*" >&2
    exit 1
}

for name in BASE_SHA CANDIDATE_SHA STAGING GH_TOKEN R2_ACCESS_KEY_ID \
    R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET R2_INTERNAL_BUCKET MANIFEST_PATH; do
    [[ -n "${!name:-}" ]] || fail "missing $name"
done
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid candidate SHA"
[[ -f "$MANIFEST_PATH" ]] || fail "missing manifest: $MANIFEST_PATH"
command -v gh >/dev/null 2>&1 || fail "missing gh"
command -v rclone >/dev/null 2>&1 || fail "missing rclone"
command -v python3 >/dev/null 2>&1 || fail "missing python3"
command -v git >/dev/null 2>&1 || fail "missing git"

REPO="${REPO:-kenzok8/openwrt-daede}"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/verify-candidate.XXXXXX")
trap 'rm -rf "$workdir"' EXIT INT TERM
chmod 700 "$workdir"

# 自带 rclone 配置，不依赖调用方的 ambient 配置
cat > "$workdir/rclone.conf" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
no_check_bucket = true
EOF
chmod 600 "$workdir/rclone.conf"
export RCLONE_CONFIG="$workdir/rclone.conf"

echo "verify-candidate: candidate $CANDIDATE_SHA in $REPO"

# 1. 下载验证记录（关联信息，非证明）
rclone cat "r2:${R2_INTERNAL_BUCKET}/daed-candidates/${CANDIDATE_SHA}/verification.json" \
    > "$workdir/verification.json" || fail "cannot download verification.json for $CANDIDATE_SHA"

# 2. 逐条用 API 核对。期望的 job 名按 workflow 写死。
python3 - "$workdir/verification.json" <<'PYEOF' > "$workdir/checks.tsv"
import json, sys
record = json.load(open(sys.argv[1]))
assert record.get("schema_version") == 2, "unsupported verification schema"
kind = record["kind"]
assert kind in ("main", "upstream"), "invalid candidate kind"
assert record["candidate_sha"], "verification.json: missing candidate_sha"
print("CANDIDATE\t" + record["candidate_sha"])
print("BASE\t" + record["base_sha"])
print("STAGING\t" + record["staging"])
print("KIND\t" + kind)
print("AUTO_BUMP\t" + str(record["auto_bump_run_id"]) + "\t" + str(record["auto_bump_run_attempt"]))
# step -> (workflow path, job 名)
jobs = {
    "assemble-dae":  (".github/workflows/assemble-dae-src.yml", "assemble"),
    "assemble-daed": (".github/workflows/assemble-daed-src.yml", "assemble"),
    "audit":         (".github/workflows/audit-upstream.yml", "Audit upstream pins"),
    "smoke":         (".github/workflows/test-daed-build.yml", "build"),
    "matrix":        (".github/workflows/release.yml", "Verify built packages"),
}
seen = set()
for v in record["verifications"]:
    step = v["step"]
    assert step in jobs, f"unexpected verification step: {step}"
    assert step not in seen, f"duplicate verification step: {step}"
    seen.add(step)
    path, job = jobs[step]
    # 规范化记录里的 workflow 标识：早期 gate 写的是文件名，新 gate 写全路径。
    # 两者都接受，统一成全路径；真正的安全核对在 bash 里用 API 返回的 .path 做。
    wf = v["workflow"]
    if not wf.startswith(".github/"):
        wf = ".github/workflows/" + wf
    assert wf == path, f"{step}: workflow mismatch: {v['workflow']}"
    print(f"{step}\t{v['run_id']}\t{v['attempt']}\t{v['head_sha']}\t{job}\t{path}")
expected = set(jobs) if kind == "upstream" else {"audit", "smoke", "matrix"}
assert seen == expected, f"verification steps differ: missing={expected - seen} extra={seen - expected}"
PYEOF

record_sha=$(awk -F'\t' '$1=="CANDIDATE" {print $2}' "$workdir/checks.tsv")
[[ "$record_sha" == "$CANDIDATE_SHA" ]] || \
    fail "verification.json is for $record_sha, not $CANDIDATE_SHA"
record_base=$(awk -F'\t' '$1=="BASE" {print $2}' "$workdir/checks.tsv")
record_staging=$(awk -F'\t' '$1=="STAGING" {print $2}' "$workdir/checks.tsv")
record_kind=$(awk -F'\t' '$1=="KIND" {print $2}' "$workdir/checks.tsv")
read -r auto_bump_run auto_bump_attempt < <(awk -F'\t' '$1=="AUTO_BUMP" {print $2, $3}' "$workdir/checks.tsv")
[[ "$record_base" == "$BASE_SHA" && "$record_staging" == "$STAGING" ]] || \
    fail "candidate base or staging differs from the frozen record"
[[ "$record_base" =~ ^[0-9a-f]{40}$ && "$record_staging" =~ ^auto-bump-staging-[0-9]+-[0-9]+$ ]] || \
    fail "invalid candidate base or staging"
if [[ "$record_kind" == main ]]; then
    [[ "$record_base" == "$CANDIDATE_SHA" ]] || fail "main candidate differs from its base"
else
    [[ "$record_base" != "$CANDIDATE_SHA" ]] || fail "upstream candidate has no staged commit"
fi
[[ "$auto_bump_run" =~ ^[0-9]+$ && "$auto_bump_attempt" =~ ^[0-9]+$ ]] || \
    fail "invalid candidate orchestrator run"
origin_json=$(gh api "repos/${REPO}/actions/runs/${auto_bump_run}" \
    --jq '{path: .path, head_sha: .head_sha, event: .event}') || \
    fail "cannot read candidate orchestrator run"
origin_path=$(printf '%s' "$origin_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
origin_head=$(printf '%s' "$origin_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["head_sha"])')
origin_event=$(printf '%s' "$origin_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["event"])')
[[ "$origin_path" == .github/workflows/auto-bump.yml && "$origin_head" == "$record_base" ]] || \
    fail "candidate orchestrator workflow or head SHA differs"
[[ "$origin_event" == workflow_dispatch || "$origin_event" == schedule ]] || \
    fail "candidate orchestrator event is $origin_event"
[[ "$record_kind" != main || "$origin_event" == workflow_dispatch ]] || \
    fail "main candidate was not manually requested"
origin_jobs=$(gh api "repos/${REPO}/actions/runs/${auto_bump_run}/attempts/${auto_bump_attempt}/jobs") || \
    fail "cannot read candidate orchestrator jobs"
origin_result=$(printf '%s' "$origin_jobs" | python3 -c '
import json,sys
matches = [job["conclusion"] for job in json.load(sys.stdin)["jobs"] if job["name"] == "bump"]
print(matches[0] if len(matches) == 1 else "missing")
')
[[ "$origin_result" == success ]] || fail "candidate orchestrator bump job concluded $origin_result"

matrix_run_id=""
while IFS=$'\t' read -r step run_id attempt head_sha job_name expected_path; do
    case "$step" in CANDIDATE|BASE|STAGING|KIND|AUTO_BUMP) continue ;; esac
    echo "verify-candidate: checking $step (run $run_id, attempt $attempt)"
    [[ "$run_id" =~ ^[0-9]+$ ]] || fail "$step: invalid run_id"
    [[ "$attempt" =~ ^[0-9]+$ ]] || fail "$step: invalid attempt"
    [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || fail "$step: invalid head_sha"

    # run 级核对：workflow、headSha、结论、attempt
    run_json=$(gh api "repos/${REPO}/actions/runs/${run_id}" \
        --jq '{path: .path, head_sha: .head_sha, conclusion: .conclusion}') \
        || fail "$step: cannot read run $run_id"
    run_path=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')
    run_head=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["head_sha"])')
    run_conc=$(printf '%s' "$run_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["conclusion"])')

    # workflow 路径必须在受信任列表（python 段已断言 step 合法，这里再对一次 API 返回）
    [[ "$run_path" == "$expected_path" ]] || \
        fail "$step: run $run_id is workflow $run_path, not $expected_path"
    [[ "$run_head" == "$head_sha" ]] || \
        fail "$step: run $run_id head $run_head != recorded $head_sha"
    [[ "$run_conc" == "success" ]] || \
        fail "$step: run $run_id concluded $run_conc"
    # attempt 语义：核对记录的 attempt；重跑产生的新 attempt 不影响
    # 旧 attempt 对同一 SHA 的证明（job 级按记录的 attempt 查）。

    # job 级核对：该 attempt 里对应 job 必须 success
    # job 名用前缀匹配：smoke 的 job 名带矩阵参数（如 "build (x86_64, 25.12)"）。
    # 各 workflow 的 job 数都小于一页（≤30），不需要 --paginate。
    jobs_json=$(gh api "repos/${REPO}/actions/runs/${run_id}/attempts/${attempt}/jobs") \
        || fail "$step: cannot read jobs for run $run_id attempt $attempt"
    job_conc=$(printf '%s' "$jobs_json" | python3 -c '
import json, sys
job = sys.argv[1]
data = json.load(sys.stdin)
matches = [j["conclusion"] for j in data["jobs"] if j["name"].startswith(job)]
print(matches[0] if matches and matches[0] else "missing")
' "$job_name")
    [[ "$job_conc" == "success" ]] || \
        fail "$step: job '$job_name' concluded $job_conc (run $run_id attempt $attempt)"

    # SHA 绑定
    if [[ "$step" == audit || "$step" == smoke || "$step" == matrix ]]; then
        [[ "$head_sha" == "$CANDIDATE_SHA" ]] || \
            fail "$step verified $head_sha, not candidate $CANDIDATE_SHA"
    else
        # assemble 在冻结前运行：验证其 head 是 candidate 的祖先
        git fetch -q origin "$head_sha" "$CANDIDATE_SHA" 2>/dev/null || \
            fail "$step: cannot fetch $head_sha / $CANDIDATE_SHA"
        git merge-base --is-ancestor "$head_sha" "$CANDIDATE_SHA" || \
            fail "$step head $head_sha is not an ancestor of candidate $CANDIDATE_SHA"
    fi

    [[ "$step" == "matrix" ]] && matrix_run_id="$run_id"
    echo "verify-candidate: $step OK (run $run_id attempt $attempt)"
done < "$workdir/checks.tsv"

# 3. manifest 绑定：manifest 只做关联，不充当证明。
#    manifest 的 build_run_id 必须等于 verification 记录里的 matrix run，
#    保证"发布的字节"就是"被验证的那次构建"的产物。
manifest_sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate_sha"])' "$MANIFEST_PATH")
manifest_run=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build_run_id"])' "$MANIFEST_PATH")
[[ "$manifest_sha" == "$CANDIDATE_SHA" ]] || \
    fail "manifest is for $manifest_sha, not candidate $CANDIDATE_SHA"
[[ "$manifest_run" == "$matrix_run_id" ]] || \
    fail "manifest build_run_id $manifest_run != verified matrix run $matrix_run_id"

echo "verify-candidate: all checks passed for $CANDIDATE_SHA"
