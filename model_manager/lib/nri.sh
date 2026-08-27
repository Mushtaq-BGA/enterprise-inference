#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# NRI Balloons policy integration — release-1 compatible approach.
#
# Core NRI policy logic (detection, balloon naming, effective CPU, pre-flight
# validation) is handled by nri_policy.py for reliability and debuggability.
# This shell layer provides:
#   - Wrappers that call the Python module and expose results to the bash model-manager
#   - nri-info display command for operator diagnostics
#
# Balloon types are pre-configured by the nri_cpu_balloons Ansible role.
# This script does NOT dynamically create or patch balloon types in the
# BalloonsPolicy CR — that is the role's responsibility.

NRI_POLICY_PY="${MM_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/nri_policy.py"
NRI_ANNOTATION_KEY="balloon.balloons.resource-policy.nri.io"
NRI_POLICY_CRD="balloonspolicies.config.nri"

# ── Python NRI policy wrapper ────────────────────────────────────────────────

# Call the Python NRI policy module. All core NRI decisions are made here.
# Usage: _nri_py <subcommand> [args...]
_nri_py() {
    python3 "$NRI_POLICY_PY" "$@"
}

# Resolve NRI settings for a deployment.
# Sets: NRI_BALLOON, NRI_EFFECTIVE_CPU, NRI_ANNOTATIONS,
#        NRI_NODE_SELECTOR_TERM, NRI_ADVANCED_MODE, NRI_HIDE_HT
#
# If NRI resolution fails (DaemonSet missing, Python error, etc.), falls back
# to deploying without NRI annotations. The model will still be deployed but
# without CPU pinning — a clear warning is emitted so the operator knows.
#
# Args: cpu tp [node] [kind] [balloon_override]
nri_resolve() {
    local cpu="$1" tp="$2" node="${3:-}" kind="${4:-LLMInferenceService}"
    local balloon_override="${5:-}"

    local args=(resolve --cpu "$cpu" --tp "$tp" --kind "$kind")
    [[ -n "$node" ]] && args+=(--node "$node")
    [[ -n "$balloon_override" ]] && args+=(--balloon "$balloon_override")

    local result
    result=$(_nri_py "${args[@]}") || {
        warn "┌─────────────────────────────────────────────────────────────────────┐"
        warn "│  NRI BALLOONS FALLBACK — Model will deploy WITHOUT CPU pinning      │"
        warn "├─────────────────────────────────────────────────────────────────────┤"
        warn "│  NRI policy resolution failed. Possible causes:                     │"
        warn "│    • nri-resource-policy-balloons DaemonSet not deployed             │"
        warn "│    • NRI ConfigMap missing or misconfigured                          │"
        warn "│    • kubectl connectivity issue to kube-system                       │"
        warn "│                                                                     │"
        warn "│  Action: Run the nri_cpu_balloons Ansible role, then redeploy.      │"
        warn "│  The model is being deployed in best-effort mode (no CPU pinning).  │"
        warn "└─────────────────────────────────────────────────────────────────────┘"
        NRI_BALLOON=""
        NRI_EFFECTIVE_CPU="$cpu"
        NRI_NODE_SELECTOR_TERM=""
        NRI_ADVANCED_MODE=false
        NRI_HIDE_HT=false

        # Fallback annotations — mark pod as best-effort so it's traceable
        if [[ "$kind" == "LLMInferenceService" ]]; then
            NRI_ANNOTATIONS="  annotations:
    cpu-policy.model-manager.io/type: best-effort
    cpu-policy.model-manager.io/reason: nri-resolution-failed
"
        else
            NRI_ANNOTATIONS="    annotations:
      cpu-policy.model-manager.io/type: best-effort
      cpu-policy.model-manager.io/reason: nri-resolution-failed
"
        fi
        return 0
    }

    NRI_BALLOON=$(echo "$result" | jq -r '.balloon')
    NRI_EFFECTIVE_CPU=$(echo "$result" | jq -r '.effective_cpu')
    NRI_ADVANCED_MODE=$(echo "$result" | jq -r '.advanced_mode')
    NRI_HIDE_HT=$(echo "$result" | jq -r '.hide_hyperthreads')

    # Build annotation block for template injection
    local ann_key="${NRI_ANNOTATION_KEY}/container.main"
    if [[ "$kind" == "InferenceService" ]]; then
        ann_key="${NRI_ANNOTATION_KEY}/pod"
    fi

    if [[ "$kind" == "LLMInferenceService" ]]; then
        NRI_ANNOTATIONS="  annotations:
    cpu-policy.model-manager.io/type: nri-balloons
    cpu-policy.model-manager.io/balloon: ${NRI_BALLOON}
    ${ann_key}: ${NRI_BALLOON}
"
    else
        NRI_ANNOTATIONS="    annotations:
      cpu-policy.model-manager.io/type: nri-balloons
      cpu-policy.model-manager.io/balloon: ${NRI_BALLOON}
      ${ann_key}: ${NRI_BALLOON}
"
    fi

    # Hard node affinity for TP>1 in advanced mode
    NRI_NODE_SELECTOR_TERM=""
    local nst
    nst=$(echo "$result" | jq -r '.node_selector_term // empty')
    if [[ -n "$nst" && "$nst" != "null" ]]; then
        NRI_NODE_SELECTOR_TERM="$nst"
    fi
}

# Run NRI pre-flight validation.
#
# Returns the pre-flight verdict as an exit code so the caller can gate the
# deployment on it:
#   0  pre-flight passed, or was overridden (MM_NRI_PREFLIGHT=warn) or skipped
#      (MM_NRI_SKIP_PREFLIGHT=1) — both are encoded by nri_policy.py as exit 0.
#   1  pre-flight failed in enforcing mode (e.g. insufficient physical cores).
# Diagnostic error lines are printed either way. The caller decides whether a
# non-zero return aborts the deploy (see nri_preflight_gate in model-manager).
#
# Args: cpu tp [node] [replicas]
# `replicas` is the model's replica (data-parallel) count. Each replica is a
# separate pod that consumes its own balloon, so the physical-core budget check
# must account for cpu * replicas of aggregate demand.
nri_preflight() {
    local cpu="$1" tp="$2" node="${3:-}" replicas="${4:-1}"

    [[ "${MM_NRI_ENABLED:-true}" =~ ^(true|1|yes)$ ]] || return 0

    local args=(preflight --cpu "$cpu" --tp "$tp")
    [[ -n "$node" ]] && args+=(--node "$node")
    [[ -n "$replicas" ]] && args+=(--replicas "$replicas")

    # `|| rc=$?` keeps `set -e` from aborting on a non-zero pre-flight exit so
    # we can inspect and propagate the verdict deliberately.
    local result rc=0
    result=$(_nri_py "${args[@]}" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        local errors
        errors=$(echo "$result" | grep -v '^\[' | jq -r '.errors[]?' 2>/dev/null) || true
        if [[ -n "$errors" ]]; then
            warn "NRI pre-flight issues detected:"
            echo "$errors" | while IFS= read -r line; do
                warn "  - $line"
            done
        fi
        return 1
    fi
    return 0
}

# ── Node label helper ────────────────────────────────────────────────────────

_node_label() {
    local node="$1" label="$2"
    local escaped="${label//./\\.}"
    if [[ -n "$node" ]]; then
        kubectl get node "$node" -o jsonpath="{.metadata.labels.${escaped}}" 2>/dev/null || true
    else
        kubectl get nodes -o jsonpath="{.items[0].metadata.labels.${escaped}}" 2>/dev/null || true
    fi
}

# ── NUMA topology (for nri-info display) ─────────────────────────────────────

nri_query_topology() {
    local node="$1"
    NRI_PHYS_CPUS=$(_node_label "$node" "nri.intel.com/physical-cpus")
    NRI_NUMA_NODES=$(_node_label "$node" "nri.intel.com/numa-nodes")
    NRI_MAX_TP=$(_node_label "$node" "nri.intel.com/max-tp")

    if [[ -z "$NRI_PHYS_CPUS" || -z "$NRI_NUMA_NODES" || "$NRI_NUMA_NODES" -eq 0 ]]; then
        die "Cannot determine NUMA topology for ${node:-first node} — missing labels"
    fi
    NRI_CORES_PER_NUMA=$(( NRI_PHYS_CPUS / NRI_NUMA_NODES ))
}

# ── CPU accounting (for nri-info display) ─────────────────────────────────────

_cpuset_count() {
    local spec="$1" total=0 part lo hi
    for part in ${spec//,/ }; do
        if [[ "$part" == *-* ]]; then
            lo="${part%-*}"; hi="${part#*-}"
            total=$(( total + hi - lo + 1 ))
        else
            total=$(( total + 1 ))
        fi
    done
    echo "$total"
}

_reserved_cpus() {
    local policy="$1"
    local raw
    raw=$(kubectl get "$NRI_POLICY_CRD" "$policy" -n kube-system \
        -o jsonpath='{.spec.reservedResources.cpu}' 2>/dev/null) || true
    if [[ "$raw" == cpuset:* ]]; then
        _cpuset_count "${raw#cpuset:}"
    elif [[ -n "$raw" ]]; then
        echo "$raw"
    else
        echo 0
    fi
}

_used_inference_cpus() {
    local node="$1"
    local total=0 cpu_val
    local pod_cpus
    pod_cpus=$(kubectl get pods -A -o json 2>/dev/null | jq -r --arg node "$node" '
        .items[]
        | select(.spec.nodeName == $node)
        | select(.status.phase == "Running")
        | (.metadata.annotations["balloon.balloons.resource-policy.nri.io/container.main"] //
           .metadata.annotations["balloon.balloons.resource-policy.nri.io/pod"]) as $b
        | select($b != null)
        | (.spec.containers[0].resources.requests.cpu // "0") | gsub("[^0-9]";"")
    ' 2>/dev/null) || pod_cpus=""

    while IFS= read -r cpu_val; do
        [[ -z "$cpu_val" ]] && continue
        total=$(( total + cpu_val ))
    done <<< "$pod_cpus"
    echo "$total"
}

# ── Resolve NRI policy name ──────────────────────────────────────────────────

nri_resolve_policy() {
    local node="$1"
    if [[ -z "$node" ]]; then
        node=$(kubectl get nodes -l "nri.intel.com/balloons-enabled=true" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
        [[ -z "$node" ]] && node=$(kubectl get nodes \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    fi
    NRI_TARGET_NODE="$node"
    NRI_POLICY_NAME="default"
    if [[ -n "$node" ]] \
        && kubectl get "$NRI_POLICY_CRD" "node.${node}" -n kube-system -o name >/dev/null 2>&1; then
        NRI_POLICY_NAME="node.${node}"
    fi
}

# ── HT detection (for nri-info display) ──────────────────────────────────────

nri_hide_hyperthreads() {
    local balloon="$1" node="$2"
    nri_resolve_policy "$node"
    local hide_ht
    hide_ht=$(kubectl get "$NRI_POLICY_CRD" "$NRI_POLICY_NAME" -n kube-system \
        -o jsonpath="{.spec.balloonTypes[?(@.name==\"$balloon\")].hideHyperthreads}" 2>/dev/null) || true
    [[ "$hide_ht" == "true" ]]
}

nri_get_threads_per_core() {
    local balloon="$1" node="$2"
    if nri_hide_hyperthreads "$balloon" "$node"; then
        NRI_THREADS_PER_CORE=1
    else
        NRI_THREADS_PER_CORE=2
    fi
}

# ── nri-info command ─────────────────────────────────────────────────────────

nri_info() {
    local target="$1"
    if [[ "$target" == "all" || -z "$target" ]]; then
        local nodes
        nodes=$(kubectl get nodes -l "nri.intel.com/balloons-enabled=true" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || true
        [[ -z "$nodes" ]] && die "No nodes found with nri.intel.com/balloons-enabled=true label"
        local count; count=$(echo "$nodes" | wc -l)
        if (( count == 1 )) && [[ "$target" != "all" ]]; then
            _nri_info_node "$(echo "$nodes" | head -1)"
        else
            local n
            while IFS= read -r n; do
                [[ -n "$n" ]] && _nri_info_node "$n"
            done <<< "$nodes"
        fi
        return 0
    fi
    _nri_info_node "$target"
}

_nri_info_node() {
    local node="$1"
    echo ""
    printf "  ${BOLD}${CYAN}NRI Balloons Policy — Node: %s${RESET}\n" "$node"
    echo "  ──────────────────────────────────────────────────────"

    local enabled
    enabled=$(_node_label "$node" "nri.intel.com/balloons-enabled")
    [[ "$enabled" != "true" ]] && { err "NRI balloons not enabled on node $node"; return 1; }

    nri_query_topology "$node"
    nri_resolve_policy "$node"
    local policy="$NRI_POLICY_NAME"

    _print_topology
    _print_balloon_types "$policy"
    _print_capacity "$node" "$policy"
    _print_valid_ranges "$node"
    _print_active_pods "$node"
    echo ""
}

_print_topology() {
    local max_tp="${NRI_MAX_TP:-$NRI_NUMA_NODES}"
    printf "\n  ${BOLD}Topology:${RESET}\n"
    printf "    Physical CPUs:   %s\n" "$NRI_PHYS_CPUS"
    printf "    NUMA nodes:      %s\n" "$NRI_NUMA_NODES"
    printf "    Cores per NUMA:  %s\n" "$NRI_CORES_PER_NUMA"
    printf "    Max TP:          %s\n" "$max_tp"
}

_print_balloon_types() {
    local policy="$1"
    local rows
    rows=$(kubectl get "$NRI_POLICY_CRD" "$policy" -n kube-system \
        -o jsonpath='{range .spec.balloonTypes[*]}{.name}{"\t"}{.hideHyperthreads}{"\t"}{.pinMemory}{"\t"}{.allocatorTopologyBalancing}{"\n"}{end}' 2>/dev/null) || true

    printf "\n  ${BOLD}Balloon Types (policy: %s):${RESET}\n" "$policy"
    printf "    %-25s %-15s %-10s %s\n" "NAME" "HIDE_HT" "PIN_MEM" "TOPO_BALANCE"
    printf "    %-25s %-15s %-10s %s\n" "─────" "───────" "───────" "────────────"

    local name hide pin topo
    while IFS=$'\t' read -r name hide pin topo; do
        [[ -z "$name" ]] && continue
        printf "    %-25s %-15s %-10s %s\n" "$name" "${hide:-false}" "${pin:-false}" "${topo:-false}"
    done <<< "$rows"
}

_print_capacity() {
    local node="$1" policy="$2"
    local reserved reserved_raw available used free
    reserved=$(_reserved_cpus "$policy")
    reserved_raw=$(kubectl get "$NRI_POLICY_CRD" "$policy" -n kube-system \
        -o jsonpath='{.spec.reservedResources.cpu}' 2>/dev/null) || true
    available=$(( NRI_PHYS_CPUS - reserved ))
    used=$(_used_inference_cpus "$node")
    free=$(( available - used ))

    printf "\n  ${BOLD}Capacity:${RESET}\n"
    if [[ "$reserved_raw" == cpuset:* ]]; then
        printf "    Reserved (system):        %s CPUs (%s — balanced across NUMA nodes)\n" "$reserved" "$reserved_raw"
    else
        printf "    Reserved (system):        %s CPUs\n" "$reserved"
    fi
    printf "    Available for inference:  %s CPUs\n" "$available"
    printf "    Allocated to models:      %s CPUs\n" "$used"
    printf "    ${GREEN}Free for new models:      %s CPUs${RESET}\n" "$free"
}

_print_valid_ranges() {
    local node="$1"
    local max_tp="${NRI_MAX_TP:-$NRI_NUMA_NODES}"

    # Use vllm-balloon for HT detection (release-1 balloon naming)
    nri_get_threads_per_core "vllm-balloon" "$node"
    local ht_state ht_label
    nri_hide_hyperthreads "vllm-balloon" "$node" && ht_state="on" || ht_state="off"
    ht_label="1 CPU = 1 physical core"
    (( NRI_THREADS_PER_CORE > 1 )) && ht_label="$NRI_THREADS_PER_CORE CPUs = 1 physical core"

    printf "\n  ${BOLD}Valid CPU ranges per TP level:${RESET}\n"
    printf "    (hideHyperthreads: %s — %s)\n\n" "$ht_state" "$ht_label"
    printf "    %-4s  %-12s  %-12s  %s\n" "TP" "MIN CPU" "MAX CPU" "BALLOON"
    printf "    %-4s  %-12s  %-12s  %s\n" "──" "───────" "───────" "───────"

    local tp min_cpu max_cpu balloon_label
    for (( tp=1; tp<=max_tp; tp++ )); do
        if (( tp == 1 )); then
            min_cpu=1
            max_cpu=$NRI_CORES_PER_NUMA
            (( NRI_THREADS_PER_CORE > 1 )) && max_cpu=$(( NRI_CORES_PER_NUMA * NRI_THREADS_PER_CORE ))
            balloon_label="vllm-balloon"
        else
            min_cpu=$(( NRI_CORES_PER_NUMA * (tp - 1) + 1 ))
            max_cpu=$(( NRI_CORES_PER_NUMA * tp ))
            if (( NRI_THREADS_PER_CORE > 1 )); then
                min_cpu=$(( min_cpu * NRI_THREADS_PER_CORE ))
                max_cpu=$(( max_cpu * NRI_THREADS_PER_CORE ))
            fi
            balloon_label="vllm-balloon-tp${tp}"
        fi
        printf "    %-4s  %-12s  %-12s  %s\n" "$tp" "$min_cpu" "$max_cpu" "$balloon_label"
    done
}

_print_active_pods() {
    local node="$1"
    local rows
    rows=$(kubectl get pods -A -o json 2>/dev/null | jq -r --arg node "$node" '
        .items[]
        | select(.spec.nodeName == $node)
        | (.metadata.annotations["balloon.balloons.resource-policy.nri.io/container.main"] //
           .metadata.annotations["balloon.balloons.resource-policy.nri.io/pod"]) as $b
        | select($b != null)
        | [(.metadata.namespace + "/" + .metadata.name),
           $b,
           .status.phase,
           (.spec.containers[0].resources.requests.cpu // "?")] | @tsv
    ' 2>/dev/null | sort) || rows=""

    printf "\n  ${BOLD}Active balloon pods:${RESET}\n"
    if [[ -z "$rows" ]]; then
        printf "    (none)\n"
        return
    fi
    printf "    %-55s %-25s %-10s %s\n" "POD" "BALLOON" "STATUS" "CPU"
    printf "    %-55s %-25s %-10s %s\n" "───" "───────" "──────" "───"
    local pod balloon status cpu
    while IFS=$'\t' read -r pod balloon status cpu; do
        [[ -z "$pod" ]] && continue
        printf "    %-55s %-25s %-10s %s\n" "$pod" "$balloon" "$status" "$cpu"
    done <<< "$rows"
}
