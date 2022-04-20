#!/bin/bash

set -o nounset
# set -o errexit
# set -o pipefail

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CLUSTER_NAME="$(/tmp/yq r "${SHARED_DIR}/install-config.yaml" 'metadata.name')"
BASE_DOMAIN="$(/tmp/yq r "${SHARED_DIR}/install-config.yaml" 'baseDomain')"

INSTALL_STAGE="initial"
function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
  case "${CLUSTER_TYPE}" in
    aws|aws-arm64|aws-usgov)
      grep -Po 'Instance ID: \Ki\-\w+' "${dir}/.openshift_install.log" > "${SHARED_DIR}/aws-instance-ids.txt";;
  *) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}' to collect machine IDs"
  esac
}

function prepare_next_steps() {
  #Save install status for must-gather to generate junit
  echo "$? $INSTALL_STAGE" > "${SHARED_DIR}/install-status.txt"
  set +e
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

case "${CLUSTER_TYPE}" in
aws|aws-arm64|aws-usgov) export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred;;
*) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

# ---------------------------------------------------------
# manifests
# ---------------------------------------------------------
openshift-install --dir="${dir}" create manifests &
wait "$!"

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then
  /tmp/yq d -i "${dir}/manifests/cluster-dns-02-config.yml" spec.privateZone
  /tmp/yq d -i "${dir}/manifests/cluster-dns-02-config.yml" spec.publicZone
fi

sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${dir}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)


# ---------------------------------------------------------
# create cluster
# ---------------------------------------------------------

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
TF_LOG=debug openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

wait "$!"
ret="$?"

if test "${ret}" -ne 0 ; then
  echo "Installation failed [create cluster]"
fi

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then

  if [ "${CLUSTER_TYPE}" == "aws" ] || [ "${CLUSTER_TYPE}" == "aws-arm64" ]; then
    # creating app record
    cat >> "/tmp/ingress_app.yml" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Network Elements (Route53 & LBs)

Parameters:
  PrivateHostedZoneId:
    Description: The Route53 private zone ID to register the targets with, such as Z21IXYZABCZ2A4.
    Type: String
  PrivateHostedZoneName:
    Description: The Route53 zone to register the targets with, such as cluster.example.com. Omit the trailing period.
    Type: String
  RouterLbDns:
    Description: The loadbalancer DNS
    Type: String
  RouterLbHostedZoneId:
    Description: The Route53 zone ID where loadbalancer reside
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterLabels:
      PrivateHostedZoneId:
        default: "Private Hosted Zone ID"
      PrivateHostedZoneName:
        default: "Private Hosted Zone Name"
      RouterLbDns:
        default: "router loadbalancer dns"
      RouterLbHostedZoneId:
        default: "Private Hosted Zone ID of router lb"

Resources:
  InternalAppsRecord:
    Type: AWS::Route53::RecordSet
    Properties:
      AliasTarget:
        DNSName: !Ref RouterLbDns
        HostedZoneId: !Ref RouterLbHostedZoneId
        EvaluateTargetHealth: false
      HostedZoneId: !Ref PrivateHostedZoneId
      Name: !Join [".", ["*.apps", !Ref PrivateHostedZoneName]]
      Type: A
EOF
  fi

  if [ "${CLUSTER_TYPE}" == "aws-usgov" ]; then
    # creating app record
    cat >> "/tmp/ingress_app.yml" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Network Elements (Route53 & LBs)

Parameters:
  PrivateHostedZoneId:
    Description: The Route53 private zone ID to register the targets with, such as Z21IXYZABCZ2A4.
    Type: String
  PrivateHostedZoneName:
    Description: The Route53 zone to register the targets with, such as cluster.example.com. Omit the trailing period.
    Type: String
  RouterLbDns:
    Description: The loadbalancer DNS
    Type: String


Metadata:
  AWS::CloudFormation::Interface:
    ParameterLabels:
      PrivateHostedZoneId:
        default: "Private Hosted Zone ID"
      PrivateHostedZoneName:
        default: "Private Hosted Zone Name"
      RouterLbDns:
        default: "router loadbalancer dns"

Resources:
  InternalAppsRecord:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref PrivateHostedZoneId
      Name: !Join [".", ["*.apps", !Ref PrivateHostedZoneName]]
      Type: CNAME
      TTL: 10
      ResourceRecords:
      - !Ref RouterLbDns
EOF
  fi

  APPS_DNS_STACK_NAME="${CLUSTER_NAME}-apps-dns"
  echo ${APPS_DNS_STACK_NAME} > "${SHARED_DIR}/apps_dns_stack_name"
  REGION="${LEASED_RESOURCE}"

  private_route53_hostzone_name="${CLUSTER_NAME}.${BASE_DOMAIN}"
  private_route53_hostzone_id=$(aws route53 list-hosted-zones-by-name --dns-name "${private_route53_hostzone_name}" --max-items 1 | jq -r '.HostedZones[].Id' | awk -F '/' '{print $3}')
  export KUBECONFIG="${dir}/auth/kubeconfig"
  router_lb=$(oc -n openshift-ingress get service router-default -o json | jq -r '.status.loadBalancer.ingress[].hostname')

  if [ "${CLUSTER_TYPE}" == "aws" ] || [ "${CLUSTER_TYPE}" == "aws-arm64" ]; then
    router_lb_hostzone_id=$(aws --region ${REGION} elb describe-load-balancers | jq -r ".LoadBalancerDescriptions[] | select(.DNSName == \"${router_lb}\").CanonicalHostedZoneNameID")
    echo ${APPS_DNS_STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
    aws --region "${REGION}" cloudformation create-stack --stack-name ${APPS_DNS_STACK_NAME} \
      --template-body 'file:///tmp/ingress_app.yml' \
      --parameters \
      ParameterKey=PrivateHostedZoneId,ParameterValue=${private_route53_hostzone_id} \
      ParameterKey=PrivateHostedZoneName,ParameterValue=${private_route53_hostzone_name} \
      ParameterKey=RouterLbDns,ParameterValue=${router_lb} \
      ParameterKey=RouterLbHostedZoneId,ParameterValue=${router_lb_hostzone_id} \
      --capabilities CAPABILITY_NAMED_IAM &
    wait "$!"
    ret=$?
  fi

  if [ "${CLUSTER_TYPE}" == "aws-usgov" ]; then
    aws --region "${REGION}" cloudformation create-stack --stack-name ${APPS_DNS_STACK_NAME} \
      --template-body 'file:///tmp/ingress_app.yml' \
      --parameters \
      ParameterKey=PrivateHostedZoneId,ParameterValue=${private_route53_hostzone_id} \
      ParameterKey=PrivateHostedZoneName,ParameterValue=${private_route53_hostzone_name} \
      ParameterKey=RouterLbDns,ParameterValue=${router_lb} \
      --capabilities CAPABILITY_NAMED_IAM &
    wait "$!"
    ret=$?
  fi    
    
  if test "${ret}" -ne 0 ; then
    echo "Failed to create stack $APPS_DNS_STACK_NAME"
    exit $ret
  else
    echo "Created stack $APPS_DNS_STACK_NAME"
  fi

  aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${APPS_DNS_STACK_NAME}" &
  wait "$!"
  ret=$?
  if test "${ret}" -ne 0 ; then
    echo "Failed to wait stack $APPS_DNS_STACK_NAME"
    exit $ret
  else
    echo "Waited for stack $APPS_DNS_STACK_NAME"
  fi

  # completing installation
  TF_LOG=debug openshift-install --dir="${dir}" wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"
  ret="$?"

  if test "${ret}" -ne 0 ; then
    echo "Installation failed [wait-for install-complete]"
    exit $ret
  else
    echo "Waited for stack $APPS_DNS_STACK_NAME"
  fi
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
  INSTALL_STAGE="cluster_creation_successful"
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "$ret"