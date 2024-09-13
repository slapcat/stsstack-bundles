#!/bin/bash -eu
#
# Run Charmed Openstack CI tests manually in a similar way to how they are run
# by OpenStack CI (OSCI).
#
# Usage: clone/fetch charm to test and run from within charm root dir.
#
FUNC_TEST_PR=
FUNC_TEST_TARGET=
MANUAL_FUNCTESTS=false
MODIFY_BUNDLE_CONSTRAINTS=true
REMOTE_BUILD=
SKIP_BUILD=false
SLEEP=
WAIT_ON_DESTROY=true

usage () {
    cat << EOF
USAGE: `basename $0` OPTIONS

Run OpenStack charms functional tests manually in a similar way to how
Openstack CI (OSCI) would do it. This tool should be run from within a charm
root.

Not all charms use the same versions and dependencies and an attempt is made to
cover this here but in some cases needs to be dealt with as a pre-requisite to
running the tool. For example some charms need their tests to be run using
python 3.8 and others python 3.10. Some tests might require Juju 2.9 and others
Juju 3.x - the assumption in this runner is that Juju 3.x is ok to use.

OPTIONS:
    --func-test-target
        Provide the name of a specific test target to run. If none provided
        all tests are run based on what is defined in osci.yaml i.e. will do
        what osci would do by default.
    --func-test-pr
        Provides similar functionality to Func-Test-Pr in commit message. Set
        to zaza-openstack-tests Pull Request ID.
    --no-wait
        By default we wait before destroying the model after a test run. This
        flag can used to override that behaviour.
    --manual-functests
        Runs functest commands separately (deploy,configure,test) instead of
        the entire suite.
    --remote-build
        Builds the charm in a remote location and transfers the charm file over.
        The destination needs to be prepared for the build and authorized for
        ssh. Implies --skip-build. Specify parameter as <destination>,<path>.
        Example: --remote-build ubuntu@10.171.168.1,~/git/charm-nova-compute
    --skip-build
        Skip building charm if already done to save time.
    --skip-modify-bundle-constraints
        By default we modify test bundle constraints to ensure that applications
        have the resources they need. For example nova-compute needs to have
        enough capacity to boot the vms required by the tests.
    --sleep
        Specify amount of seconds to sleep between functest steps.
    --help
        This help message.
EOF
}

while (($# > 0)); do
    case "$1" in
        --debug)
            set -x
            ;;
        --func-test-target)
            FUNC_TEST_TARGET=$2
            shift
            ;;
        --func-test-pr)
            FUNC_TEST_PR=$2
            shift
            ;;
        --manual-functests)
            MANUAL_FUNCTESTS=true
            ;;
        --no-wait)
            WAIT_ON_DESTROY=false
            ;;
        --remote-build)
            REMOTE_BUILD=$2
            SKIP_BUILD=true
            shift
            ;;
        --skip-modify-bundle-constraints)
            MODIFY_BUNDLE_CONSTRAINTS=false
            ;;
        --skip-build)
            SKIP_BUILD=true
            ;;
        --sleep)
            SLEEP=$2
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: invalid input '$1'"
            usage
            exit 1
            ;;
    esac
    shift
done

# Install dependencies
snap info yq &>/dev/null || sudo snap install yq

# Ensure zosic-config checked out and up-to-date
(
cd
if [[ -d zosci-config ]]; then
    cd zosci-config
    git checkout master
    git pull
else
    git clone https://github.com/openstack-charmers/zosci-config
fi
)

TOOLS_PATH=$(realpath $(dirname $0))/func_test_tools
CHARM_PATH=$(pwd)

# Get commit we are running tests against.
COMMIT_ID=$(git -C $CHARM_PATH rev-parse --short HEAD)
CHARM_NAME=$(awk '/^name: .+/{print $2}' metadata.yaml)

echo "Running functional tests for charm $CHARM_NAME commit $COMMIT_ID"

source ~/novarc
export {,TEST_}CIDR_EXT=`openstack subnet show subnet_${OS_USERNAME}-psd-extra -c cidr -f value`
FIP_MAX=$(ipcalc $CIDR_EXT| awk '$1=="HostMax:" {print $2}')
FIP_MIN=$(ipcalc $CIDR_EXT| awk '$1=="HostMin:" {print $2}')
FIP_MIN_ABC=${FIP_MIN%.*}
FIP_MIN_D=${FIP_MIN##*.}
FIP_MIN=${FIP_MIN_ABC}.$(($FIP_MIN_D + 64))

CIDR_OAM=`openstack subnet show subnet_${OS_USERNAME}-psd -c cidr -f value`
OAM_MAX=$(ipcalc $CIDR_OAM| awk '$1=="HostMax:" {print $2}')
OAM_MIN=$(ipcalc $CIDR_OAM| awk '$1=="HostMin:" {print $2}')
OAM_MIN_ABC=${OAM_MIN%.*}
OAM_MAX_D=${OAM_MAX##*.}
# Picking last two addresses and hoping they dont get used by Neutron.
export {OS,TEST}_VIP00=${OAM_MIN_ABC}.$(($OAM_MAX_D - 1))
export {OS,TEST}_VIP01=${OAM_MIN_ABC}.$(($OAM_MAX_D - 2))

# More information on config https://github.com/openstack-charmers/zaza/blob/master/doc/source/runningcharmtests.rst
export {,TEST_}NET_ID=$(openstack network show net_${OS_USERNAME}-psd-extra -f value -c id)
export {,TEST_}FIP_RANGE=$FIP_MIN:$FIP_MAX
export {,TEST_}GATEWAY=$(openstack subnet show subnet_${OS_USERNAME}-psd-extra -c gateway_ip -f value)
export {,TEST_}NAME_SERVER=91.189.91.131
export {,TEST_}CIDR_PRIV=192.168.21.0/24
#export SWIFT_IP=10.140.56.22
export TEST_MODEL_SETTINGS="image-stream=released;default-series=jammy;test-mode=true;transmit-vendor-metrics=false"
# We need to set TEST_JUJU3 as well as the constraints file
# Ref: https://github.com/openstack-charmers/zaza/blob/e96ab098f00951079fccb34bc38d4ae6ebb38606/setup.py#L47
export TEST_JUJU3=1

# NOTE: this should not be necessary for > juju 2.x but since we still have a need for it we add it in
export TEST_ZAZA_BUG_LP1987332=1

# Some charms point to an upstream constraints file that installs python-libjuju 2.x so we need to do this to ensure we get 3.x
export TEST_CONSTRAINTS_FILE=https://raw.githubusercontent.com/openstack-charmers/zaza/master/constraints-juju34.txt

# 2. Build
if ! $SKIP_BUILD; then
    # default value is 1.5/stable, assumed that later charm likely have charmcraft_channel value
    CHARMCRAFT_CHANNEL=$(grep charmcraft_channel osci.yaml | sed -r 's/.+:\s+(\S+)/\1/')
    sudo snap refresh charmcraft --channel ${CHARMCRAFT_CHANNEL:-"1.5/stable"}

    # ensure lxc initialised
    lxd init --auto || true

    tox -re build
else
    if [[ -n $REMOTE_BUILD ]]; then
        IFS=',' read -ra remote_build_params <<< "$REMOTE_BUILD"
        REMOTE_BUILD_DESTINATION=${remote_build_params[0]}
        REMOTE_BUILD_PATH=${remote_build_params[1]}
        ssh $REMOTE_BUILD_DESTINATION "cd $REMOTE_BUILD_PATH;git log -1;rm -rf *.charm;tox -re build"
        rm -rf *.charm
        rsync -vza $REMOTE_BUILD_DESTINATION:$REMOTE_BUILD_PATH/*.charm .
    fi
fi

# 3. Run functional tests.

# If a func test pr is provided switch to that pr.
if [[ -n $FUNC_TEST_PR ]]; then
    (
    [[ -d src ]] && cd src
    # We use the zosci-config tools to do this.
    MSG=$(echo "Func-Test-Pr: https://github.com/openstack-charmers/zaza-openstack-tests/pull/$FUNC_TEST_PR"| base64)
    ~/zosci-config/roles/handle-func-test-pr/files/process_func_test_pr.py -f ./test-requirements.txt "$MSG"
    )
fi

declare -A func_targets=()
if [[ -n $FUNC_TEST_TARGET ]]; then
    func_targets[$FUNC_TEST_TARGET]=null
else
    for target in $(python3 $TOOLS_PATH/identify_charm_func_tests.py); do
        func_targets[$target]=null
    done
fi

# Ensure nova-compute has enough resources to create vms in tests. Not all
# charms have bundles with constraints set so we need to cover both cases here.
if $MODIFY_BUNDLE_CONSTRAINTS; then
    (
    [[ -d src ]] && cd src
    for f in tests/bundles/*.yaml; do
        if [[ $(yq '.applications' $f) = null ]]; then
            yq -i '.services.nova-compute.constraints="root-disk=80G mem=8G"' $f
        else
            yq -i '.applications.nova-compute.constraints="root-disk=80G mem=8G"' $f
        fi
    done
    )
fi

# We don't need to rebuild when running different bundles for the same branch
rm -rf .tox/func-target
rm -rf .tox/func-noop

for target in ${!func_targets[@]}; do
    [[ -d src ]] && pushd src &>/dev/null || true
    fail=false
    if ! $MANUAL_FUNCTESTS; then
        tox -e func-target -- $target || fail=true
        model=`juju list-models| egrep -o "^zaza-\S+"|tr -d '*'`
    else
        $TOOLS_PATH/manual_functests_runner.sh $target $SLEEP || fail=true
        model=test-$target
    fi

    if $fail; then
        func_targets[$target]='fail'
    else
        func_targets[$target]='success'
    fi

    if $WAIT_ON_DESTROY; then
        read -p "Destroy model and run next test? [ENTER]"
    fi
    # cleanup before next run
    juju destroy-model --no-prompt $model --force --no-wait --destroy-storage
done
popd &>/dev/null || true

# Report results
echo "Test results for charm $CHARM_NAME functional tests @ commit $COMMIT_ID:"
for target in ${!func_targets[@]}; do
    if $(python3 $TOOLS_PATH/test_is_voting.py $target); then
        voting_info=""
    else
        voting_info=" (non-voting)"
    fi

    if [[ ${func_targets[$target]} = null ]]; then
        echo "  * $target: SKIPPED$voting_info"
    elif [[ ${func_targets[$target]} = success ]]; then
        echo "  * $target: SUCCESS$voting_info"
    else
        echo "  * $target: FAILURE$voting_info"
    fi
done

