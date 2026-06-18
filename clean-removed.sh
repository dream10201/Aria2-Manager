#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ====== 配置 ======

RPC_URL="${ARIA2_RPC_URL:-http://127.0.0.1:6800/jsonrpc}"
RPC_SECRET="${ARIA2_RPC_SECRET:-}"

# 只允许删除这些目录下面的文件。多个目录用冒号分隔。
DOWNLOAD_ROOTS_RAW="${ARIA2_DOWNLOAD_ROOTS:-/downloads}"

LOG_FILE="${ARIA2_CLEAN_LOG:-/tmp/aria2-clean-removed.log}"

# 1 = 只记录，不真删
DRY_RUN="${ARIA2_CLEAN_DRY_RUN:-0}"

# 1 = 只删除未完成任务；已完成后被移除的任务不删文件
ONLY_INCOMPLETE="${ARIA2_CLEAN_ONLY_INCOMPLETE:-1}"

# 1 = 下载出错时也删除未完成文件。需要把 on-download-error 指向本脚本。
CLEAN_ON_ERROR="${ARIA2_CLEAN_ON_ERROR:-1}"

# 1 = 下载完成时只清理 .aria2 控制文件，不删除下载结果。
# 需要把 on-download-complete 也指向本脚本。
CLEAN_ON_COMPLETE_CONTROL="${ARIA2_CLEAN_ON_COMPLETE_CONTROL:-1}"

# 1 = 下载完成后自动从 aria2 已停止列表删除记录。
# 错误、被移除、未完成任务不会删除记录。
REMOVE_COMPLETED_RECORD="${ARIA2_REMOVE_COMPLETED_RECORD:-1}"

# 1 = 删除 BT 中未 selected 但实际写入过数据的文件
DELETE_TOUCHED_UNSELECTED="${ARIA2_CLEAN_DELETE_TOUCHED_UNSELECTED:-1}"

# 1 = 删除文件后向上清理空目录，不删除下载根目录本身
PRUNE_EMPTY_DIRS="${ARIA2_CLEAN_PRUNE_EMPTY_DIRS:-1}"


# ====== 基础函数 ======

log() {
    local msg="$*"
    {
        printf '%s %s\n' "$(date '+%F %T')" "$msg"
    } >> "$LOG_FILE" 2>/dev/null || true
}

skip() {
    log "SKIP: $*"
    exit 0
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || skip "missing command: $1"
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

canon_dir() {
    local dir="$1"

    [[ -d "$dir" ]] || return 1

    (
        cd -P -- "$dir" >/dev/null 2>&1
        pwd -P
    )
}

canonical_entry_path() {
    local path="$1"
    local dir base cdir

    [[ -n "$path" ]] || return 1
    [[ "$path" != "/" ]] || return 1

    dir="$(dirname -- "$path")"
    base="$(basename -- "$path")"

    [[ -d "$dir" ]] || return 1

    cdir="$(canon_dir "$dir")" || return 1
    printf '%s/%s\n' "$cdir" "$base"
}

normalize_path() {
    local raw="$1"
    local base_dir="${2:-}"

    [[ -n "$raw" ]] || return 1

    if [[ "$raw" == /* ]]; then
        printf '%s\n' "$raw"
    else
        [[ -n "$base_dir" ]] || return 1
        printf '%s/%s\n' "$base_dir" "$raw"
    fi
}

ROOTS=()

init_roots() {
    local IFS=':'
    local root croot
    read -r -a raw_roots <<< "$DOWNLOAD_ROOTS_RAW"

    for root in "${raw_roots[@]}"; do
        [[ -n "$root" ]] || continue
        croot="$(canon_dir "$root")" || {
            log "WARN: download root does not exist: $root"
            continue
        }
        ROOTS+=("$croot")
    done

    ((${#ROOTS[@]} > 0)) || skip "no valid download roots"
}

under_allowed_root() {
    local path="$1"
    local root

    for root in "${ROOTS[@]}"; do
        [[ "$path" == "$root" ]] && return 1
        [[ "$path" == "$root"/* ]] && return 0
    done

    return 1
}

delete_file_like() {
    local raw="$1"
    local path cpath

    path="$(normalize_path "$raw")" || return 0
    cpath="$(canonical_entry_path "$path")" || return 0

    if ! under_allowed_root "$cpath"; then
        log "REFUSE outside root: $cpath"
        return 0
    fi

    if [[ -d "$cpath" && ! -L "$cpath" ]]; then
        log "SKIP directory, not recursive: $cpath"
        return 0
    fi

    if [[ ! -e "$cpath" && ! -L "$cpath" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY unlink: $cpath"
    else
        rm -f -- "$cpath"
        log "UNLINK: $cpath"
    fi

    DELETED_DIRS+=("$(dirname -- "$cpath")")
}

prune_empty_dir_upward() {
    local dir="$1"
    local cdir

    [[ "$PRUNE_EMPTY_DIRS" == "1" ]] || return 0

    cdir="$(canon_dir "$dir")" || return 0

    while under_allowed_root "$cdir"; do
        if [[ "$DRY_RUN" == "1" ]]; then
            log "DRY rmdir-if-empty: $cdir"
            cdir="$(dirname -- "$cdir")"
            continue
        fi

        if rmdir -- "$cdir" 2>/dev/null; then
            log "RMDIR empty: $cdir"
            cdir="$(dirname -- "$cdir")"
        else
            break
        fi
    done
}

rpc_tell_status() {
    local gid="$1"
    local payload

    payload="$(
        jq -nc \
            --arg gid "$gid" \
            --arg secret "$RPC_SECRET" '
            {
              jsonrpc: "2.0",
              id: "clean-removed",
              method: "aria2.tellStatus",
              params:
                (
                  (
                    if $secret != "" then
                      ["token:" + $secret]
                    else
                      []
                    end
                  )
                  +
                  [
                    $gid,
                    [
                      "gid",
                      "status",
                      "totalLength",
                      "completedLength",
                      "dir",
                      "files",
                      "bittorrent",
                      "infoHash"
                    ]
                  ]
                )
            }
            '
    )"

    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 5 \
        --header 'Content-Type: application/json' \
        --data "$payload" \
        "$RPC_URL"
}

rpc_remove_download_result() {
    local gid="$1"
    local payload

    payload="$(
        jq -nc \
            --arg gid "$gid" \
            --arg secret "$RPC_SECRET" '
            {
              jsonrpc: "2.0",
              id: "clean-removed",
              method: "aria2.removeDownloadResult",
              params:
                (
                  (
                    if $secret != "" then
                      ["token:" + $secret]
                    else
                      []
                    end
                  )
                  +
                  [
                    $gid
                  ]
                )
            }
            '
    )"

    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 5 \
        --header 'Content-Type: application/json' \
        --data "$payload" \
        "$RPC_URL"
}

add_candidate() {
    local path="$1"

    [[ -n "$path" ]] || return 0
    [[ "$path" != "/" ]] || return 0

    if [[ -z "${SEEN[$path]+x}" ]]; then
        SEEN["$path"]=1
        CANDIDATES+=("$path")
    fi
}

add_sidecars() {
    local path="$1"

    add_candidate "${path}.aria2"
    add_candidate "${path}.torrent"
    add_candidate "${path}.meta4"
    add_candidate "${path}.metalink"
}

add_control_file() {
    local path="$1"

    add_candidate "${path}.aria2"
}


# ====== 主流程 ======

main() {
    need_cmd curl
    need_cmd jq
    init_roots

    local gid="${1:-}"
    local hook_file_num="${2:-0}"
    local hook_first_path="${3:-}"

    [[ "$gid" =~ ^[0-9a-fA-F]{1,16}$ ]] || skip "invalid gid: $gid"

    local resp
    resp="$(rpc_tell_status "$gid")" || skip "rpc failed for gid=$gid"

    if jq -e '.error? != null' >/dev/null <<< "$resp"; then
        skip "rpc error for gid=$gid: $(jq -rc '.error' <<< "$resp")"
    fi

    local status total completed base_dir
    status="$(jq -r '.result.status // empty' <<< "$resp")"
    total="$(jq -r '.result.totalLength // "0"' <<< "$resp")"
    completed="$(jq -r '.result.completedLength // "0"' <<< "$resp")"
    base_dir="$(jq -r '.result.dir // empty' <<< "$resp")"

    local control_only=0

    if [[ "$status" == "complete" ]]; then
        [[ "$CLEAN_ON_COMPLETE_CONTROL" == "1" ]] && control_only=1
        [[ "$control_only" == "1" || "$REMOVE_COMPLETED_RECORD" == "1" ]] || skip "status=$status gid=$gid"
    elif [[ "$status" != "removed" ]] && [[ ! ( "$status" == "error" && "$CLEAN_ON_ERROR" == "1" ) ]]; then
        skip "status=$status gid=$gid"
    fi

    if [[ "$control_only" != "1" ]] \
        && [[ "$ONLY_INCOMPLETE" == "1" ]] \
        && is_uint "$total" \
        && is_uint "$completed" \
        && (( total > 0 )) \
        && (( completed >= total )); then
        skip "already complete, gid=$gid completed=$completed total=$total"
    fi

    declare -A SEEN=()
    CANDIDATES=()
    DELETED_DIRS=()

    local delete_touched_json="false"
    [[ "$DELETE_TOUCHED_UNSELECTED" == "1" ]] && delete_touched_json="true"

    # 数据文件：selected=true 的文件一定删；
    # 未 selected 但 completedLength>0 的文件可选删除，因为 BT piece 可能跨文件写入。
    local p normalized

    while IFS= read -r -d '' p; do
        normalized="$(normalize_path "$p" "$base_dir")" || continue
        if [[ "$control_only" == "1" ]]; then
            add_control_file "$normalized"
        else
            add_candidate "$normalized"
            add_sidecars "$normalized"
        fi
    done < <(
        jq -rj \
            --argjson deleteTouched "$delete_touched_json" '
            .result.files[]?
            | select(
                (.selected == "true")
                or
                ($deleteTouched and ((.completedLength | tonumber? // 0) > 0))
              )
            | (.path // empty), "\u0000"
            ' <<< "$resp"
    )

    # 兜底：RPC 没有 files 时，用 hook 第三个参数。
    if ((${#CANDIDATES[@]} == 0)) && [[ "$hook_file_num" != "0" && -n "$hook_first_path" ]]; then
        normalized="$(normalize_path "$hook_first_path" "$base_dir")" || true
        if [[ -n "${normalized:-}" ]]; then
            if [[ "$control_only" == "1" ]]; then
                add_control_file "$normalized"
            else
                add_candidate "$normalized"
                add_sidecars "$normalized"
            fi
        fi
    fi

    # BT multi 的控制文件是 <top-dir>.aria2，不是第一个文件路径.aria2。
    local bt_mode bt_name top_dir
    bt_mode="$(jq -r '.result.bittorrent.mode // empty' <<< "$resp")"
    bt_name="$(jq -r '.result.bittorrent.info.name // empty' <<< "$resp")"

    if [[ "$bt_mode" == "multi" && -n "$base_dir" && -n "$bt_name" ]]; then
        top_dir="${base_dir%/}/$bt_name"
        add_candidate "${top_dir}.aria2"
    fi

    # magnet metadata：bt-save-metadata=true 时，aria2 会保存 <infoHash>.torrent。
    local info_hash
    info_hash="$(jq -r '.result.infoHash // empty' <<< "$resp")"

    if [[ "$control_only" != "1" && -n "$base_dir" && "$info_hash" =~ ^[0-9a-fA-F]{40}$ ]]; then
        add_candidate "${base_dir%/}/${info_hash,,}.torrent"
        add_candidate "${base_dir%/}/${info_hash^^}.torrent"
    fi

    if ((${#CANDIDATES[@]} > 0)); then
        for p in "${CANDIDATES[@]}"; do
            delete_file_like "$p"
        done

        for p in "${DELETED_DIRS[@]:-}"; do
            prune_empty_dir_upward "$p"
        done
    else
        log "NO_CANDIDATES gid=$gid"
    fi

    if [[ "$status" == "complete" && "$REMOVE_COMPLETED_RECORD" == "1" ]]; then
        local remove_resp
        if remove_resp="$(rpc_remove_download_result "$gid")"; then
            if jq -e '.error? != null' >/dev/null <<< "$remove_resp"; then
                log "WARN removeDownloadResult failed gid=$gid: $(jq -rc '.error' <<< "$remove_resp")"
            else
                log "REMOVE_RECORD gid=$gid"
            fi
        else
            log "WARN removeDownloadResult rpc failed gid=$gid"
        fi
    fi

    log "DONE gid=$gid status=$status mode=$([[ "$control_only" == "1" ]] && printf control-only || printf cleanup) candidates=${#CANDIDATES[@]} completed=$completed total=$total"
}

main "$@"
