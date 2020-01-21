#!/bin/bash

set -xe
source $WORKSPACE/libfabric-ci-scripts/common.sh
trap 'on_exit'  EXIT
slave_name=slave_$label
slave_value=${!slave_name}
ami=($slave_value)
NODES=1
# Placement group is not needed for single-node tests.
export ENABLE_PLACEMENT_GROUP=0

set +x
create_instance || { echo "==>Unable to create instance"; exit 1; }
set -x

execution_seq=$((${execution_seq}+1))
test_instance_status ${INSTANCE_IDS}

get_instance_ip

execution_seq=$((${execution_seq}+1))
# Kernel upgrade only for Ubuntu and provider EFA
check_provider_os ${INSTANCE_IPS}

# Add AMI specific installation commands
script_builder single-node

# Appending fabtests to the existing installation script
cat <<-"EOF" >> ${tmp_script}
. ~/.bash_profile
ssh-keygen -f ${HOME}/.ssh/id_rsa -N "" > /dev/null
cat ${HOME}/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys

# Provider-specific handling of the options passed to runfabtests.sh
FABTEST_OPTS="-E LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\" -vvv ${EXCLUDE}"
case "${PROVIDER}" in
"efa")
    # EFA provider supports a custom address format based on the GID of the
    # device. Extract that from sysfs and pass it to the tests. Also have the
    # client communicate with QP0 of the server.
    gid=$(ibv_devinfo -v | grep GID | awk '{print $3}')
    FABTEST_OPTS+=" -t all -C \"-P 0\" -s $gid -c $gid"
    ;;
"shm")
    # The shm provider does not support the negative tests with bad addresses,
    # and there seems to be no easy way to add them to the exclude lists..
    # See https://github.com/ofiwg/libfabric/issues/5182 for context.
    FABTEST_OPTS+=" -N"
    ;;
esac

bash -c "${HOME}/libfabric/fabtests/install/bin/runfabtests.sh ${FABTEST_OPTS} ${PROVIDER} 127.0.0.1 127.0.0.1"

EOF

# Test whether node is ready for SSH connection or not
test_ssh ${INSTANCE_IPS}

execution_seq=$((${execution_seq}+1))
# For single node, the ssh connection is established only once. The script
# builds libfabric and also executes fabtests
set +x
ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -T -i ~/${slave_keypair} ${ami[1]}@${INSTANCE_IPS} \
    "bash -s" -- <${tmp_script} \
    "$PULL_REQUEST_ID" "$PULL_REQUEST_REF" "$PROVIDER" 2>&1 | tr \\r \\n | \
    sed 's/\(.*\)/'${INSTANCE_IPS}' \1/' | tee ${output_dir}/temp_execute_runfabtests.txt
EXIT_CODE=${PIPESTATUS[0]}
set -x

# Get build status
exit_status "$EXIT_CODE" "${INSTANCE_IPS}"
exit ${BUILD_CODE}
