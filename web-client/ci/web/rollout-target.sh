#!/bin/sh
# The hosted client's rollout target (Jenkinsfile.client-web, the
# WEB_CLIENT_ROLLOUT credential), as "<namespace> <deployment>" on stdout.
#
# Accepted, and nothing else:
#   <namespace> <deployment>
#   kubectl rollout restart <deploy>/<deployment> <ns-option>   (either order after "restart")
# where <deploy> is deploy, deployment, deployments or deployment.apps and
# <ns-option> is -n <ns>, -n<ns>, --namespace <ns> or --namespace=<ns>.
# Exactly one resource and one namespace: an extra, repeated or unknown word
# stops here, rather than restarting whichever deployment came last.
set -eu

fail() {
    echo 'WEB_CLIENT_ROLLOUT must be "<namespace> <deployment>" or "kubectl rollout restart deploy/<deployment> -n <namespace>", with nothing else.' >&2
    exit 1
}

ns=''; dep=''
set -f; set -- ${1-}; set +f
if [ $# -eq 2 ] && [ "${1#-}" = "$1" ] && [ "${2#*/}" = "$2" ]; then
    ns=$1; dep=$2
else
    [ $# -ge 3 ] && [ "$1" = kubectl ] && [ "$2" = rollout ] && [ "$3" = restart ] || fail
    shift 3
    nres=0; nns=0
    while [ $# -gt 0 ]; do
        case "$1" in
            deploy/*|deployment/*|deployments/*|deployment.apps/*) dep=${1#*/}; nres=$((nres + 1)) ;;
            -n|--namespace) [ $# -ge 2 ] || fail; shift; ns=$1; nns=$((nns + 1)) ;;
            --namespace=*) ns=${1#--namespace=}; nns=$((nns + 1)) ;;
            -n?*) ns=${1#-n}; nns=$((nns + 1)) ;;
            *) fail ;;
        esac
        shift
    done
    [ "$nres" -eq 1 ] && [ "$nns" -eq 1 ] || fail
fi
name='^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
printf '%s' "$ns" | grep -Eq "$name" || fail
printf '%s' "$dep" | grep -Eq "$name" || fail
printf '%s %s\n' "$ns" "$dep"
