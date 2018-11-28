#!/bin/bash

# This creates a pachyderm cluster in AWS for testing. This is a thin wrapper around
# etc/deploy/aws.sh, but it uses the same state store bucket for all tests, so that
# kops clusters created for testing can always be enumerated and deleted.

set -euxo pipefail

## Parse command-line flags

set -e

which jq

delete_resources() {
  local name=${1}
  [[ -e ${HOME}/.pachyderm/${name}-info.json ]] || aws s3 cp "${KOPS_BUCKET}/${name}-info.json" "${HOME}/.pachyderm/${name}-info.json"
  kops --state=${KOPS_BUCKET} delete cluster --name=${name} --yes
  aws s3 rb --region ${REGION} --force "s3://$(jq --raw-output .pachyderm_bucket ${HOME}/.pachyderm/${name}-info.json)" >/dev/null
  aws s3 rm "${KOPS_BUCKET}/${name}-info.json"
  sudo rm "${HOME}/.pachyderm/${name}-info.json"
}

ZONE="${ZONE:-us-west-1b}"
KOPS_BUCKET=${KOPS_BUCKET:-s3://pachyderm-travis-state-store-v1}
OP=-
CLOUDFRONT=
DEPLOY_PACHD="true"  # By default, aws.sh deploys pachyderm in its k8s cluster
len_zone_minus_one="$(( ${#ZONE} - 1 ))"
REGION=${ZONE:0:${len_zone_minus_one}}

# Process args
new_opt="$( getopt --long="create,delete:,delete-all,list,zone:,use-cloudfront,no-pachyderm" -- ${0} "${@}" )"
[[ "$?" -eq 0 ]] || exit 1
eval "set -- ${new_opt}"

while true; do
  case "${1}" in
    --list)
      kops --state=${KOPS_BUCKET} get clusters
      exit 0  # Shortcut
      ;;
    --delete)
      OP=delete
      CLUSTER_NAME="${2}"
      shift 2
      ;;
    --delete-all)
      OP=delete-all
      shift
      ;;
    --create)
      OP=create
      shift
      ;;
    --zone)
      ZONE="${2}"
      shift 2
      ;;
    --use-cloudfront)
      # Default is not to provide the flag
      CLOUDFRONT="--use-cloudfront"
      shift
      ;;
    --no-pachyderm)
      DEPLOY_PACHD="false" # default is true, see top of file
      shift
      ;;
    --)
      shift
      break
      ;;
  esac
done

echo -e "Zone: ${ZONE}"

# No need to authenticate with kops, as auth creds are already in environment variables
# in travis
set -x
case "${OP}" in
  create)
    aws_sh="$(dirname "${0}")/../../deploy/aws.sh"
    aws_sh="$(realpath "${aws_sh}")"
    cmd=("${aws_sh}" --zone=${ZONE} --state=${KOPS_BUCKET} --no-metrics)
    if [[ "${DEPLOY_PACHD}" == "false" ]]; then
      cmd+=("--no-pachyderm")
    fi
    if [[ -n "${CLOUDFRONT}" ]]; then
      cmd+=("${CLOUDFRONT}")
    fi
    sudo env "PATH=${PATH}" "GOPATH=${GOPATH}" "${cmd[@]}"
    check_ready="$(dirname "${0}")/../../kube/check_ready.sh"
    check_ready="$(realpath "${check_ready}")"
    sudo env "PATH=${PATH}" "GOPATH=${GOPATH}" "bash -c 'until timeout 1s sudo ${check_ready} app=pachd; do sleep 1; done'"
    ;;
  delete)
    delete_resources ${CLUSTER_NAME}
    ;;
  delete-all)
    kops --state=${KOPS_BUCKET} get clusters | tail -n+2 | awk '{print $1}' \
      | while read name; do
        delete_resources ${name}
      done
    ;;
  *)
    set +x
    echo "Must pass --create, --delete, --delete-all or --list to testing/deploy/aws.sh"
    exit 1
esac

set +x
