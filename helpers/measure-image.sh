#!/bin/bash

set -euo pipefail

export PODMAN_IGNORE_CGROUPSV1_WARNING=1

# Usage function
usage() {
	cat <<EOF
Usage: $(basename "$0") [-h, -o outdir] IMG

Options:
    -h          Display this help message
    -o          Define where to store the measurement file. Defaults to "."

Example:
    $(basename "$0") quay.io/redhat-user-workloads/ose-osc-tenant/osc-dm-verity-image:test
EOF
	exit 1
}

outdir=$(pwd)

# Parse global options
while getopts "o:h" opt; do
	case ${opt} in
	h)
		usage
		;;
	o)
		outdir="$OPTARG"
		;;
	\?)
		echo "Invalid option" >&2
		usage
		;;
	esac
done
shift $((OPTIND - 1))

check_package() {
	PACKAGE="edk2-ovmf"
	if dnf list installed "$PACKAGE" &>/dev/null; then
		echo "Package '$PACKAGE' is installed."
	else
		echo "Package '$PACKAGE' is NOT installed. Please install it first."
		echo "dnf install -y $PACKAGE"
		exit 1
	fi
}

prepare() {
	mkdir -p measure
	cd measure

	podman create --name podvm $PODVM_IMG
	podman cp podvm:/image/podvm.qcow2 .
	podman rm podvm

	wget https://raw.githubusercontent.com/confidential-containers/cloud-api-adaptor/refs/heads/main/src/cloud-api-adaptor/hack/podvm-measure.sh
	sed 's/(3|9|11)/(3|9|11|12)/g' podvm-measure.sh > podvm-measure-custom.sh
	rm -f podvm-measure.sh
	mv podvm-measure-custom.sh podvm-measure.sh
	chmod +x podvm-measure.sh
	cp /usr/share/edk2/ovmf/OVMF_CODE.fd .
	cd - > /dev/null
}

run_measurements() {
	cd measure
	./podvm-measure.sh swtpm &
	./podvm-measure.sh -i podvm.qcow2 -o ./OVMF_CODE.fd launch &
	./podvm-measure.sh wait
	./podvm-measure.sh scrape > $outdir/measurements.json
	./podvm-measure.sh stop
	jq -e . $outdir/measurements.json
	cd - > /dev/null
	rm -rf measure
}

# Main command dispatch
main() {
	[[ $# -lt 1 ]] && usage

	PODVM_IMG=$1

	echo "OUTPUT=$outdir/measurements.json"

	check_package
	prepare
	run_measurements
}

main "$@"