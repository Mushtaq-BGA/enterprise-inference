#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# CPU policy dispatch — decides HOW a model's pods get pinned to CPUs.
#
# One switch, three policies (matching solutions' `kubernetes_cpu_policy`):
#
#   nri-balloons    (default) NRI balloons resource policy. NUMA-aware balloons
#                   sized per tensor-parallel shard. All logic lives in
#                   nri.sh / nri_policy.py; this file only routes to it.
#   kubelet-static  kubelet's static CPU manager. Any pod in the Guaranteed QoS
#                   class (integer cpu, requests == limits for cpu AND memory)
#                   gets exclusive whole CPUs off the shared pool. No plugin,
#                   no annotations needed — but the manifest must qualify for
#                   Guaranteed, which is what this file enforces.
#   best-effort     no pinning; the CFS scheduler places threads.
#
# Precedence for choosing the policy (first match wins):
#   1. --cpu-policy <p>   CLI flag (per-deploy override)
#   2. MM_CPU_POLICY=<p>  env var — how the Ansible install passes the
#                         cluster-wide `kubernetes_cpu_policy` through
#   3. auto-detect        kubelet cpuManagerPolicy=static → kubelet-static;
#                         else NRI balloons DaemonSet present → nri-balloons;
#                         else best-effort
#
# Public API (all set globals, mirroring the pre-existing nri.sh contract):
#   cpu_policy_resolve                 → CPU_POLICY
#   build_cpu_policy_annotations <tp>  → CPU_POLICY_ANNOTATIONS,
#                                        NRI_NODE_SELECTOR_TERM, MODEL_CPU
#   cpu_policy_preflight_gate          → aborts on an unplaceable model

CPU_POLICY_ANNOTATION_PREFIX="cpu-policy.model-manager.io"

# Resolved policy for this run. Empty until cpu_policy_resolve runs.
CPU_POLICY=""
# Cache so repeated calls (render_manifest + the pre-flight gate) don't re-probe
# the cluster. Detection is a couple of kubectl round-trips.
_CPU_POLICY_CACHED=""

# ── Detection ────────────────────────────────────────────────────────────────

# Read a node's live kubelet configuration.
#
# The kubelet serves its running config at /configz through the API server
# proxy. This is the only way to see cpuManagerPolicy from outside the node —
# it is NOT on the Node object. Requires RBAC on nodes/proxy (the admin
# kubeconfig the installer uses has it). Empty on any failure; callers treat
# that as "unknown", never as "not static".
_kubelet_configz() {
    local node="$1"
    [[ -z "$node" ]] && return 0
    kubectl get --raw "/api/v1/nodes/${node}/proxy/configz" 2>/dev/null || true
}

# Node to inspect: the explicit --node, else any schedulable worker, else the
# first node. Mirrors where the scheduler would most likely place the pod.
_cpu_policy_probe_node() {
    local node="${MODEL_NODE:-}"
    if [[ -z "$node" ]]; then
        node=$(kubectl get nodes \
            -l '!node-role.kubernetes.io/control-plane' \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    fi
    if [[ -z "$node" ]]; then
        node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    fi
    printf '%s' "$node"
}

# True when the probed node's kubelet runs the static CPU manager.
_kubelet_static_active() {
    local node="${1:-}"
    [[ -z "$node" ]] && return 1
    local cfg
    cfg=$(_kubelet_configz "$node")
    [[ -z "$cfg" ]] && return 1
    local pol
    pol=$(jq -r '.kubeletconfig.cpuManagerPolicy // ""' <<< "$cfg" 2>/dev/null) || pol=""
    [[ "$pol" == "static" ]]
}

_nri_balloons_ds_present() {
    kubectl get daemonset nri-resource-policy-balloons -n kube-system \
        -o name >/dev/null 2>&1
}

_cpu_policy_valid() {
    case "$1" in
        nri-balloons|kubelet-static|best-effort) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve the policy for this run into CPU_POLICY (see precedence at top).
cpu_policy_resolve() {
    if [[ -n "$_CPU_POLICY_CACHED" ]]; then
        CPU_POLICY="$_CPU_POLICY_CACHED"
        return 0
    fi

    local requested=""

    # 1. Per-deploy CLI override.
    if [[ -n "${OPT_CPU_POLICY:-}" ]]; then
        requested="$OPT_CPU_POLICY"
        if ! _cpu_policy_valid "$requested"; then
            abort "Invalid --cpu-policy '$requested'. Valid: nri-balloons, kubelet-static, best-effort."
        fi

    # 2. Cluster-wide value passed through by the Ansible install.
    elif [[ -n "${MM_CPU_POLICY:-}" ]]; then
        requested="${MM_CPU_POLICY,,}"
        if ! _cpu_policy_valid "$requested"; then
            warn "Invalid MM_CPU_POLICY='${MM_CPU_POLICY}' — ignoring, falling back to auto-detection."
            requested=""
        fi
    fi

    # Back-compat: MM_NRI_ENABLED=false was the old way to turn pinning off,
    # and older installs still export it. Honour it only when no explicit
    # policy was given, so the newer switch always wins.
    if [[ -z "$requested" ]] \
        && [[ -n "${MM_NRI_ENABLED:-}" ]] \
        && [[ ! "${MM_NRI_ENABLED}" =~ ^(true|1|yes)$ ]]; then
        requested="best-effort"
        info "MM_NRI_ENABLED=${MM_NRI_ENABLED} — CPU pinning disabled (best-effort)."
    fi

    # 3. Auto-detect from the cluster.
    if [[ -z "$requested" ]]; then
        local node
        node=$(_cpu_policy_probe_node)
        if _kubelet_static_active "$node"; then
            requested="kubelet-static"
            info "Detected kubelet static CPU manager on '${node}' — using kubelet-static."
        elif _nri_balloons_ds_present; then
            requested="nri-balloons"
        else
            requested="best-effort"
            warn "No CPU-pinning mechanism detected (no NRI balloons DaemonSet, kubelet cpuManagerPolicy is not static) — deploying best-effort, without CPU pinning."
        fi
    fi

    CPU_POLICY="$requested"
    _CPU_POLICY_CACHED="$requested"
}

# ── Annotation block rendering ───────────────────────────────────────────────

# Render an annotations block at the indentation the target manifest needs,
# assigning it to CPU_POLICY_ANNOTATIONS.
#
# LLMInferenceService puts pod annotations at spec.annotations (2 spaces);
# InferenceService at spec.predictor.annotations (4 spaces). Same shape the
# NRI path has always emitted, so the templates are unchanged.
#
# Assigns the global rather than echoing it, because the block MUST keep its
# trailing newline: the templates read `{{NRI_ANNOTATIONS}}  model:`, so the
# following key sits on the substituted block's last line. A command
# substitution strips trailing newlines and would splice `model:` onto the last
# annotation, producing invalid YAML. nri.sh assigns directly for the same
# reason.
# Args: kind key=value...
_render_annotations_block() {
    local kind="$1"; shift
    local pad="    " key_pad="      "
    if [[ "$kind" == "LLMInferenceService" ]]; then
        pad="  "; key_pad="    "
    fi
    CPU_POLICY_ANNOTATIONS="${pad}annotations:
"
    local kv
    for kv in "$@"; do
        CPU_POLICY_ANNOTATIONS+="${key_pad}${kv%%=*}: ${kv#*=}
"
    done
}

# ── kubelet-static ───────────────────────────────────────────────────────────
#
# kubelet's static CPU manager needs no annotation to pin a pod — it acts on
# any Guaranteed-QoS container. What it does need is a manifest that qualifies:
#
#   * integer CPU (a millicpu value like "8500m" drops the pod to Burstable,
#     which is never pinned — it just shares the pool)
#   * requests == limits for cpu AND memory
#
# The templates already emit requests == limits from the same MODEL_CPU /
# MODEL_MEMORY values, so the remaining job is normalising MODEL_CPU to an
# integer and, when `full-pcpus-only` is on, to a whole number of physical
# cores. Under that option kubelet REJECTS a pod whose cpu request is not a
# multiple of threads-per-core (SMT width) — the pod goes Failed with
# "SMTAlignmentError", so rounding up here is what keeps a customer's odd cpu
# value deployable instead of crash-looping.
#
# Sets: _KS_FULL_PCPUS_ONLY, _KS_THREADS_PER_CORE
_kubelet_static_probe() {
    local node="$1"
    _KS_FULL_PCPUS_ONLY=false
    _KS_THREADS_PER_CORE=1

    local cfg
    cfg=$(_kubelet_configz "$node")
    if [[ -n "$cfg" ]]; then
        local opt
        opt=$(jq -r '.kubeletconfig.cpuManagerPolicyOptions["full-pcpus-only"] // ""' \
            <<< "$cfg" 2>/dev/null) || opt=""
        [[ "$opt" == "true" ]] && _KS_FULL_PCPUS_ONLY=true
    fi

    # SMT width. Not exposed by the Kubernetes API (it needs /sys or lscpu on
    # the node), so it is an override with a safe default: 2 whenever
    # full-pcpus-only is active, which is the x86 server norm and the value the
    # solutions repo's kubelet-static profile is built around. Set
    # MM_KUBELET_THREADS_PER_CORE=1 on an SMT-disabled cluster to avoid the
    # (harmless) round-up to an even cpu count.
    if [[ -n "${MM_KUBELET_THREADS_PER_CORE:-}" ]]; then
        if [[ "${MM_KUBELET_THREADS_PER_CORE}" =~ ^[1-9][0-9]*$ ]]; then
            _KS_THREADS_PER_CORE="${MM_KUBELET_THREADS_PER_CORE}"
        else
            warn "Invalid MM_KUBELET_THREADS_PER_CORE='${MM_KUBELET_THREADS_PER_CORE}' — expected a positive integer; using auto-detected default."
            [[ "$_KS_FULL_PCPUS_ONLY" == true ]] && _KS_THREADS_PER_CORE=2
        fi
    elif [[ "$_KS_FULL_PCPUS_ONLY" == true ]]; then
        _KS_THREADS_PER_CORE=2
    fi
}

# Normalise MODEL_CPU so the pod lands in Guaranteed QoS and satisfies
# full-pcpus-only. Echoes the adjusted value; returns 1 (printing nothing) when
# the input is not a usable CPU quantity.
#
# NB: this deliberately does NOT abort. It runs inside a command substitution
# that is itself nested inside `manifest=$(render_manifest)`, and an `exit` from
# that depth only kills the innermost subshell — the deploy would carry on with
# an empty value. The caller must test the status and abort in its own context:
#     effective=$(_kubelet_static_effective_cpu "$cpu") || abort ...
_kubelet_static_effective_cpu() {
    local cpu="$1"

    # Strip a millicpu suffix and round UP to the next whole CPU — rounding
    # down could take a model below the cores it needs to load.
    if [[ "$cpu" == *m ]]; then
        local milli="${cpu%m}"
        [[ "$milli" =~ ^[0-9]+$ ]] || return 1
        cpu=$(( (milli + 999) / 1000 ))
    fi
    # Non-integer (e.g. "7.5") — round up via awk, ints are unaffected.
    if [[ ! "$cpu" =~ ^[0-9]+$ ]]; then
        # Reject anything that is not a plain decimal before handing it to awk:
        # awk would silently evaluate "abc" as 0 and "8x" as 8.
        [[ "$cpu" =~ ^[0-9]*\.?[0-9]+$ ]] || return 1
        local rounded
        rounded=$(awk -v v="$cpu" 'BEGIN{ if (v+0 <= 0) print 0; else printf "%d", (v == int(v) ? v : int(v) + 1) }' 2>/dev/null) || return 1
        [[ "$rounded" =~ ^[0-9]+$ ]] || return 1
        cpu="$rounded"
    fi

    (( cpu <= 0 )) && return 1

    # full-pcpus-only: round up to a whole physical core.
    local tpc="${_KS_THREADS_PER_CORE:-1}"
    if [[ "${_KS_FULL_PCPUS_ONLY:-false}" == true ]] && (( tpc > 1 )) && (( cpu % tpc != 0 )); then
        cpu=$(( ((cpu / tpc) + 1) * tpc ))
    fi

    printf '%s' "$cpu"
}

# Normalise MODEL_CPU and reject resource shapes that cannot be Guaranteed.
#
# MUST run in the deploy's own shell (cmd_deploy), NOT inside the
# `manifest=$(render_manifest)` substitution: it both mutates MODEL_CPU for the
# renderer and aborts on unusable input, and neither works from a subshell.
# Idempotent, so calling it again from the annotation builder is harmless.
_kubelet_static_validate_resources() {
    [[ "${_KS_RESOURCES_VALIDATED:-0}" == 1 ]] && return 0

    local node
    node=$(_cpu_policy_probe_node)
    _kubelet_static_probe "$node"

    local effective
    effective=$(_kubelet_static_effective_cpu "$MODEL_CPU") \
        || abort "kubelet-static needs a numeric CPU quantity >= 1 for '${MODEL_NAME}', got '${MODEL_CPU}'." \
                 "Set an integer cpu in models.yaml or pass --cpu N."
    if [[ "$effective" != "$MODEL_CPU" ]]; then
        info "kubelet-static: CPU ${MODEL_CPU} → ${effective} (integer, Guaranteed QoS$( [[ "$_KS_FULL_PCPUS_ONLY" == true ]] && printf ', full-pcpus-only aligned to %s-thread cores' "$_KS_THREADS_PER_CORE" ))"
        MODEL_CPU="$effective"
    fi

    # Memory must also be requests == limits for Guaranteed QoS. The templates
    # render both from MODEL_MEMORY, so that holds by construction — but an
    # empty value would render `memory:` twice as null and silently drop the
    # pod to BestEffort, unpinned. Fail loudly instead.
    [[ -z "${MODEL_MEMORY:-}" ]] \
        && abort "kubelet-static requires an explicit memory value for '${MODEL_NAME}' (Guaranteed QoS needs requests == limits). Set memory in models.yaml or pass --memory."

    _KS_RESOURCES_VALIDATED=1
}

# Populate CPU_POLICY_ANNOTATIONS for kubelet-static.
_build_kubelet_static_annotations() {
    local tp="$1"

    # Normally already done by cpu_policy_validate_resources in the parent
    # shell; repeated here so a direct caller still gets a normalised CPU.
    _kubelet_static_validate_resources

    # Annotations are documentation only here: kubelet pins on QoS class, not on
    # a label. Recorded so `kubectl get pod -o yaml` shows which policy placed
    # the pod, matching what the NRI path stamps.
    local -a ann=(
        "${CPU_POLICY_ANNOTATION_PREFIX}/type=kubelet-static"
        "${CPU_POLICY_ANNOTATION_PREFIX}/qos=guaranteed"
        "${CPU_POLICY_ANNOTATION_PREFIX}/cpus=\"${MODEL_CPU}\""
    )
    [[ "${_KS_FULL_PCPUS_ONLY:-false}" == true ]] \
        && ann+=("${CPU_POLICY_ANNOTATION_PREFIX}/full-pcpus-only=\"true\"")
    (( tp > 1 )) && ann+=("${CPU_POLICY_ANNOTATION_PREFIX}/tensor-parallel=\"${tp}\"")

    _render_annotations_block "$MODEL_KIND" "${ann[@]}"   # sets CPU_POLICY_ANNOTATIONS

    # kubelet-static has no per-node capability label to select on (unlike NRI's
    # nri.intel.com/max-tp), so no hard node affinity is added. The Guaranteed
    # pod is simply scheduled where the requested CPUs fit, and the pre-flight
    # gate below verifies at least one node can hold it.
    NRI_NODE_SELECTOR_TERM=""
}

# ── best-effort ──────────────────────────────────────────────────────────────

_build_best_effort_annotations() {
    _render_annotations_block "$MODEL_KIND" \
        "${CPU_POLICY_ANNOTATION_PREFIX}/type=best-effort"   # sets CPU_POLICY_ANNOTATIONS
    NRI_NODE_SELECTOR_TERM=""
}

# ── Dispatch: resource validation ────────────────────────────────────────────

# Validate/normalise the model's CPU + memory for the active policy, aborting on
# a shape the policy cannot honour.
#
# Call this from cmd_deploy BEFORE `manifest=$(render_manifest)`: it mutates
# MODEL_CPU (which the renderer reads) and aborts in a context where `exit`
# actually stops the deploy. nri-balloons does its own CPU adjustment inside
# nri_resolve and best-effort needs none, so only kubelet-static acts here.
cpu_policy_validate_resources() {
    cpu_policy_resolve
    [[ "$CPU_POLICY" == "kubelet-static" ]] && _kubelet_static_validate_resources
    return 0
}

# ── Dispatch: annotations ────────────────────────────────────────────────────

# Populate CPU_POLICY_ANNOTATIONS (+ NRI_NODE_SELECTOR_TERM, and MODEL_CPU
# where the policy changes the effective request) for the active policy.
#
# Called from render_manifest inside a command substitution, so it cannot abort
# the parent deploy — anything that must stop a deploy belongs in
# cpu_policy_validate_resources or cpu_policy_preflight_gate, both of which run
# in the deploy's own shell.
build_cpu_policy_annotations() {
    local tp="${1:-1}"
    CPU_POLICY_ANNOTATIONS=""
    NRI_NODE_SELECTOR_TERM=""

    cpu_policy_resolve

    case "$CPU_POLICY" in
        nri-balloons)
            # Unchanged NRI path — nri.sh owns balloon naming, effective CPU
            # (HT doubling) and the max-tp node affinity.
            build_nri_annotations "$tp"
            CPU_POLICY_ANNOTATIONS="$NRI_ANNOTATIONS"
            ;;
        kubelet-static) _build_kubelet_static_annotations "$tp" ;;
        best-effort)    _build_best_effort_annotations ;;
    esac
}

# ── Dispatch: pre-flight ─────────────────────────────────────────────────────

# kubelet-static pre-flight.
#
# Two things can make a Guaranteed pod undeployable, and both are silent
# failures at apply time (the CR is accepted, pods just never schedule or go
# Failed), so they are worth catching before downloading weights:
#
#   1. kubelet is not actually running the static CPU manager — the pod would
#      run unpinned. Warn (not fatal): the cluster may legitimately be mid-roll,
#      and an unpinned model still serves.
#   2. No single node has enough allocatable CPU for cpu * tp. Fatal: exclusive
#      CPUs cannot span nodes, so the pod would sit Pending forever.
_kubelet_static_preflight() {
    local cpu="$1" tp="$2" node="$3" replicas="${4:-1}"
    local -a errors=()

    local probe="${node:-$(_cpu_policy_probe_node)}"
    if [[ -n "$probe" ]] && ! _kubelet_static_active "$probe"; then
        local cfg
        cfg=$(_kubelet_configz "$probe")
        if [[ -z "$cfg" ]]; then
            warn "Could not read kubelet config from node '${probe}' (needs RBAC on nodes/proxy) — cannot confirm cpuManagerPolicy=static. Proceeding; if the kubelet is not static the model runs without CPU pinning."
        else
            warn "Node '${probe}' has cpuManagerPolicy=$(jq -r '.kubeletconfig.cpuManagerPolicy // \"none\"' <<< "$cfg" 2>/dev/null) — not 'static'. ${MODEL_NAME} will run WITHOUT exclusive CPUs. Re-run the solutions install with kubernetes_cpu_policy=kubelet-static to reconfigure kubelet."
        fi
    fi

    # Per-pod demand. One pod per replica; tp shards live inside a pod (vLLM
    # threads), so a pod needs cpu * tp exclusive CPUs on ONE node.
    local per_pod=$(( cpu * tp ))

    # Largest allocatable CPU count across candidate nodes. Allocatable already
    # has kube/system-reserved subtracted, so it is the real ceiling.
    local nodes_json
    if [[ -n "$node" ]]; then
        nodes_json=$(kubectl get node "$node" -o json 2>/dev/null) || nodes_json=""
        [[ -n "$nodes_json" ]] && nodes_json=$(jq -c '{items: [.]}' <<< "$nodes_json" 2>/dev/null)
    else
        nodes_json=$(kubectl get nodes -o json 2>/dev/null) || nodes_json=""
    fi

    if [[ -z "$nodes_json" ]]; then
        warn "Could not list nodes to verify CPU capacity — skipping the kubelet-static capacity check."
    else
        # Allocatable cpu may be an integer ("64") or millicpu ("63500m").
        local max_alloc
        max_alloc=$(jq -r '
            [ .items[]
              | select((.spec.taints // []) | map(select(.effect == "NoSchedule")) | length == 0)
              | .status.allocatable.cpu
              | if type == "string" and endswith("m")
                then (.[:-1] | tonumber / 1000 | floor)
                else (tonumber | floor) end
            ] | max // 0' <<< "$nodes_json" 2>/dev/null) || max_alloc=0
        [[ -z "$max_alloc" || "$max_alloc" == "null" ]] && max_alloc=0

        if (( max_alloc > 0 )) && (( per_pod > max_alloc )); then
            errors+=("No schedulable node has ${per_pod} allocatable CPUs (cpu=${cpu} x tp=${tp}); the largest offers ${max_alloc}. Exclusive CPUs cannot span nodes, so the pod would stay Pending.")
        fi

        # Aggregate check across replicas — advisory, because other workloads'
        # usage is not accounted for here and the scheduler has the final say.
        if (( replicas > 1 )) && (( max_alloc > 0 )); then
            local total_alloc
            total_alloc=$(jq -r '
                [ .items[]
                  | select((.spec.taints // []) | map(select(.effect == "NoSchedule")) | length == 0)
                  | .status.allocatable.cpu
                  | if type == "string" and endswith("m")
                    then (.[:-1] | tonumber / 1000 | floor)
                    else (tonumber | floor) end
                ] | add // 0' <<< "$nodes_json" 2>/dev/null) || total_alloc=0
            local want=$(( per_pod * replicas ))
            if (( want > total_alloc )); then
                warn "kubelet-static: ${replicas} replicas x ${per_pod} CPUs = ${want} exceeds the cluster's ${total_alloc} allocatable CPUs — some replicas will stay Pending."
            fi
        fi
    fi

    if (( ${#errors[@]} > 0 )); then
        warn "kubelet-static pre-flight issues detected:"
        local e
        for e in "${errors[@]}"; do warn "  - $e"; done
        return 1
    fi
    return 0
}

# Enforcing pre-flight gate for the active policy. Runs before any weights are
# downloaded or manifest applied, and aborts a deploy that cannot be placed.
#
# Overrides (shared with the NRI path, so operators keep one mental model):
#   MM_SKIP_PREFLIGHT=1 / MM_NRI_SKIP_PREFLIGHT=1  skip the check
#   MM_PREFLIGHT=warn   / MM_NRI_PREFLIGHT=warn    report but do not block
cpu_policy_preflight_gate() {
    cpu_policy_resolve

    [[ "${MM_SKIP_PREFLIGHT:-}" =~ ^(1|true|yes)$ ]] && return 0

    resolve_tp_size   # sets TP_SIZE (idempotent; also called in render_manifest)

    case "$CPU_POLICY" in
        nri-balloons)
            nri_preflight_gate
            return $?
            ;;
        best-effort)
            # Nothing to reserve, nothing to check.
            return 0
            ;;
    esac

    # kubelet-static. Normalise first (cached, so this is a no-op when
    # cmd_deploy already ran it) — the capacity maths below is integer
    # arithmetic and would fail outright on a raw "8500m".
    _kubelet_static_validate_resources

    if _kubelet_static_preflight "$MODEL_CPU" "$TP_SIZE" "$MODEL_NODE" "${MODEL_REPLICAS:-1}"; then
        return 0
    fi

    if [[ "${MM_PREFLIGHT:-}" == "warn" || "${MM_NRI_PREFLIGHT:-}" == "warn" ]]; then
        warn "kubelet-static pre-flight failed but MM_PREFLIGHT=warn — proceeding anyway."
        return 0
    fi

    abort "kubelet-static pre-flight failed: cannot place ${MODEL_NAME}" \
          "(cpu=${MODEL_CPU} tp=${TP_SIZE} replicas=${MODEL_REPLICAS:-1}) on any single node." \
          "Lower --cpu/--tp/--replicas, or add a larger node. Override with" \
          "MM_PREFLIGHT=warn (proceed anyway) or MM_SKIP_PREFLIGHT=1 (skip check)."
}
