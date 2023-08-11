#!/usr/bin/env bash

set -e

if [ -z "$DOCKER_URL" ]; then
	echo "ERROR: DOCKER_URL must be set, exiting..."
	exit 1
fi

VERSION=${VERSION:-}
CHANNEL=${CHANNEL:-test}
APT_CONTAINERD_INSTALL="containerd.io"
YUM_CONTAINERD_INSTALL="containerd.io"
ZYPPER_CONTAINERD_INSTALL="containerd.io"

MIN_ROOTLESS_VER="20.10.12"

if [ "$CONTAINERD_VERSION" ]
then
	APT_CONTAINERD_INSTALL="containerd.io=$CONTAINERD_VERSION*"
	YUM_CONTAINERD_INSTALL="containerd.io-$CONTAINERD_VERSION*"
	ZYPPER_CONTAINERD_INSTALL="containerd.io=$CONTAINERD_VERSION*"
fi

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

on_ec2() {
	if [ -f /sys/hypervisor/uuid ] && [ "$(head -c 3 /sys/hypervisor/uuid)" == ec2 ]; then
		return 0
	else
		return 1
	fi
}

strip_trailing_slash() {
	echo "$1" | sed 's/\/$//'
}

# version_gte checks if the version specified in $VERSION is at least
# the given CalVer (YY.MM) version. returns 0 (success) if $VERSION is either
# unset (=latest) or newer or equal than the specified version. Returns 1 (fail)
# otherwise.
#
# examples:
#
# VERSION=20.10
# version_gte 20.10 // 0 (success)
# version_gte 19.03 // 0 (success)
# version_gte 21.10 // 1 (fail)
version_gte() {
	if [ -z "$VERSION" ]; then
			return 0
	fi
	# Cut "-" used in case off dev/tp/rc builds
	clean_version="$(echo "$VERSION" | cut -d'-' -f1)"
	eval calver_compare "$clean_version" "$1"
}

# calver_compare compares two CalVer (YY.MM.VER) version strings. returns 0 (success)
# if version A is newer or equal than version B, or 1 (fail) otherwise. Patch
# releases and pre-release (-alpha/-beta) are not taken into account
#
# examples:
#
# calver_compare 20.10.12 19.03 // 0 (success)
# calver_compare 20.10.12 20.10.12 // 0 (success)
# calver_compare 19.03.02 20.10.12 // 1 (fail)
calver_compare() (
	set +x

	yy_a="$(echo "$1" | cut -d'.' -f1)"
	yy_b="$(echo "$2" | cut -d'.' -f1)"
	if [ "$yy_a" -lt "$yy_b" ]; then
		return 1
	fi
	if [ "$yy_a" -gt "$yy_b" ]; then
		return 0
	fi
	mm_a="$(echo "$1" | cut -d'.' -f2)"
	mm_b="$(echo "$2" | cut -d'.' -f2)"
	if [ "${mm_a#0}" -lt "${mm_b#0}" ]; then
		return 1
	fi
	ver_a="$(echo "$1" | cut -d'.' -f3)"
	ver_b="$(echo "$2" | cut -d'.' -f3)"
	if [ "$ver_a" -lt "$ver_b" ]; then
		return 1
	fi

	return 0
)

ubuntu_install() {
	local dist_version="$1"
	export DEBIAN_FRONTEND=noninteractive
	local pre_reqs="apt-transport-https ca-certificates curl software-properties-common"
	if ! command -v gpg > /dev/null; then
		pre_reqs="$pre_reqs gnupg"
	fi
	local ubuntu_url
	(
		set -ex
		$sh_c "apt-get update -qq"
		$sh_c "apt-get install -y -qq $pre_reqs >/dev/null"
	)
	ubuntu_url=$(strip_trailing_slash "$DOCKER_URL")
	#
	# Check if we have a gpg (should be valid repo to use if it's there) before appending suffix
	if ! curl -fsSL "$ubuntu_url/gpg" >/dev/null; then
		# URL's may not be suffixed with ubuntu, let's make sure that they are
		if [[ ! "$ubuntu_url" =~ /ubuntu$ ]]; then
			ubuntu_url="$ubuntu_url/ubuntu"
		fi
	fi
	local arch
	arch="$(dpkg --print-architecture)"
	local release
	# Grab this outside of the command to install so it's not muddled
	release="$(lsb_release -cs)"
	(
		set -ex
		$sh_c "curl -fsSL $ubuntu_url/gpg | apt-key add -qq - >/dev/null"
		$sh_c "add-apt-repository -y 'deb [arch=$arch] $ubuntu_url $release $CHANNEL' >/dev/null"
		$sh_c "apt-get update -qq >/dev/null"
	)
	local package="docker-ee"
	local package_version=""
	# By default don't include a cli_package and rootless_package to install just let the package manager grab the topmost one
	local cli_package=""
	local rootless_package=""
	local allow_downgrade=""
	# Grab the specific version, base it off of regex patterns
	if [ -n "$VERSION" ]; then
		package_pattern="$(echo "$VERSION" | sed "s/-ee-/~ee~/g" | sed "s/-/.*/g").*-0~ubuntu"
		local search_command="apt-cache madison '$package' | grep '$package_pattern' | head -1 | cut -d' ' -f 4"
		package_version="$($sh_c "$search_command")"
		local cli_search_command="apt-cache madison '$package-cli' | grep '$package_pattern' | head -1 | cut -d' ' -f 3"
		cli_package_version="$($sh_c "$cli_search_command")"
		if version_gte "$MIN_ROOTLESS_VER"; then
			local rootless_search_command="apt-cache madison '$package-rootless-extras' | grep '$package_pattern' | head -1 | cut -d' ' -f 3"
			rootless_package_version="$($sh_c "$rootless_search_command")"
		fi
		echo "INFO: Searching repository for VERSION '$VERSION'"
		echo "INFO: $search_command"
		if [ -z "$package_version" ]; then
			echo
			echo "ERROR: '$VERSION' not found amongst apt-cache madison results"
			echo
			exit 1
		fi
		# If a cli package was found for the given version then include it in the install
		if [ -n "$cli_package_version" ]; then
			cli_package="$package-cli=$cli_package_version"
		fi
		# If a rootless package was found for the given version then include it in the install
		if [ -n "$rootless_package_version" ]; then
			rootless_package="$package-rootless-extras=$rootless_package_version"
		fi
		package_version="=$package_version"

	  if [ "$dist_version" != "14.04" ]; then
		  allow_downgrade="--allow-downgrades"
    fi
	fi
	(
		set -ex
		$sh_c "apt-get install -y $allow_downgrade -qq $package$package_version $cli_package $rootless_package $APT_CONTAINERD_INSTALL"
	)
}

yum_install() {
	local dist_id="$1"
  if [ "$dist_id" = "almalinux" ]; then
    dist_id="rhel"
  fi
	local dist_version="$2"
  if [ "$dist_version" = "9.2" ]; then
    dist_version="9"
  fi
  local yum_url
	yum_url=$(strip_trailing_slash "$DOCKER_URL")
	(
		set -ex
		$sh_c "rpm -qa | grep curl || yum install -q -y curl"
	)
	# Check if we have a usable repo file before appending suffix
	if ! curl -fsSL "$yum_url/docker-ee.repo" >/dev/null; then
		if [[ ! "$yum_url" =~ /centos$|/rhel$|rocky$ ]]; then
			yum_url="$yum_url/$dist_id"
		fi
	fi
	case $dist_id:$dist_version in
	oraclelinux:7*)
		# Enable "Oracle Linux 7 Server Add ons (x86_64)" repo for oraclelinux7
		(
			set -ex
			$sh_c 'yum-config-manager --enable ol7_addons'
		)
		;;
	rhel:7*)
		extras_repo="rhel-7-server-extras-rpms"
		if on_ec2; then
			$sh_c "yum install -y rh-amazon-rhui-client"
			extras_repo="rhel-7-server-rhui-extras-rpms"
		fi
		# We don't actually make packages for 7.1 but they can still use the 7 repository
		if [ "$dist_version" = "7.1" ]; then
			dist_version="7"
		fi
		# Enable extras repo for rhel
		(
			set -ex
			$sh_c "yum-config-manager --enable $extras_repo"
		)
		;;
	esac
	# TODO: For Docker EE 17.03 a targeted version of container-selinux needs to be
	#       installed. See: https://github.com/docker/release-repo/issues/62
	(
		set -ex
		$sh_c "echo '$yum_url' > /etc/yum/vars/dockerurl"
		$sh_c "echo '$dist_version' > /etc/yum/vars/dockerosversion"
		$sh_c "yum install -q -y yum-utils device-mapper-persistent-data lvm2"
		$sh_c "yum-config-manager --add-repo $yum_url/docker-ee.repo"
		$sh_c "yum-config-manager --disable 'docker-ee-*'"
		$sh_c "yum-config-manager --enable 'docker-ee-$CHANNEL'"
	)
	local package="docker-ee"
	local package_version=""
	# By default don't include a cli_package and rootless_package to install just let the package manager grab the topmost one
	local cli_package=""
	local rootless_package=""
	local install_cmd="install"
	if [ -n "$VERSION" ]; then
		package_pattern="$(echo "$VERSION" | sed "s/-ee-/\\\\.ee\\\\./g" | sed "s/-/.*/g").*el"
		local search_command="yum list --showduplicates '$package' | grep '$package_pattern' | tail -1 | awk '{print \$2}'"
		package_version="$($sh_c "$search_command")"
		local cli_search_command="yum list --showduplicates '$package-cli' | grep '$package_pattern' | tail -1 | awk '{print \$2}'"
		cli_package_version="$($sh_c "$cli_search_command")"
		if version_gte "$MIN_ROOTLESS_VER" && [ "$dist_id:$dist_version" != "oraclelinux:7" ]; then
			local rootless_search_command="yum list --showduplicates '$package-rootless-extras' | grep '$package_pattern' | tail -1 | awk '{print \$2}'"
			rootless_package_version="$($sh_c "$rootless_search_command")"
		fi
		echo "INFO: Searching repository for VERSION '$VERSION'"
		echo "INFO: $search_command"
		if [ -z "$package_version" ]; then
			echo
			echo "ERROR: '$VERSION' not found amongst yum list results"
			echo
			exit 1
		fi
		if [ -n "$cli_package_version" ]; then
			cli_package="$package-cli-$(echo "${cli_package_version}" | cut -d':' -f 2)"
		fi
		if [ -n "$rootless_package_version" ]; then
			rootless_package="$package-rootless-extras-$(echo "${rootless_package_version}" | cut -d':' -f 2)"
		fi
		# Cut out the epoch and prefix with a '-'
		package_version="$(echo "$package_version" | cut -d':' -f 2)"
		package_version_dash="-${package_version}"

		# Check if we're doing an upgrade / downgrade and the command accordingly
		echo "INFO: Checking to determine whether this should be an upgrade or downgrade"
		# If the package isn't realdy installed then don't try upgrade / downgrade
		if ! $sh_c "yum list installed $package" >/dev/null; then
			install_cmd="install"
		# Exit codes when using --assumeno will give 0 if there would be an upgrade/downgrade, 1 if there is
		elif ! $sh_c "yum upgrade --assumeno $package$package_version_dash"; then
			install_cmd="upgrade"
		elif ! $sh_c "yum downgrade --assumeno $package$package_version_dash"; then
			install_cmd="downgrade"
		fi
		echo "INFO: will use install command $install_cmd"
	fi
	(
		set -ex
		$sh_c "yum $install_cmd -q -y $package$package_version_dash $cli_package $rootless_package $YUM_CONTAINERD_INSTALL"
	)
}

zypper_install() {
	local arch
	arch="$(uname -m)"
	local dist_version
	dist_version=$1
	local repo_version
	local zypper_flags=""
	case "$dist_version" in
		12*)
			repo_version=12.3
			;;
		15*)
			zypper_flags=" --allow-vendor-change"
			repo_version=15
			;;
	esac
	(
		set -ex
		$sh_c "zypper install -y curl"
	)
	local zypper_url
	zypper_url=$(strip_trailing_slash "$DOCKER_URL")
	# No need to append sles if we already have a valid repo
	if ! curl -fsL "$zypper_url/docker-ee.repo" >/dev/null; then
		zypper_url="$zypper_url/sles"
	fi
	(
		set -ex
		$sh_c "zypper removerepo docker-ee-$CHANNEL" # this will always return 0 even if repo alias not found
		$sh_c "zypper addrepo $zypper_url/$repo_version/$arch/$CHANNEL docker-ee-$CHANNEL"
		$sh_c "rpm --import '$zypper_url/gpg'"
		$sh_c "zypper refresh"
	)
	local package="docker-ee"
	local package_version=""
	# By default don't include a cli_package and rootless_package to install just let the package manager grab the topmost one
	local cli_package=""
	local rootless_package=""
	if [ -n "$VERSION" ]; then
		local package_pattern
		package_pattern="$(echo "$VERSION" | sed "s/-ee-/\\\\.ee\\\\./g" | sed "s/-/.*/g").*|"
		local search_command="zypper search -s '$package' | grep '$package_pattern' | tr -d '[:space:]' | cut -d'|' -f 4"
		package_version="$($sh_c "$search_command")"
		local cli_search_command="zypper search -s '$package-cli' | grep '$package_pattern' | tr -d '[:space:]' | cut -d'|' -f 4"
		cli_package_version="$($sh_c "$cli_search_command")"
		if version_gte "$MIN_ROOTLESS_VER" && [ "$repo_version" != "12.3" ] ; then
			local rootless_search_command="zypper search -s '$package-rootless-extras' | grep '$package_pattern' | tr -d '[:space:]' | cut -d'|' -f 4"
			rootless_package_version="$($sh_c "$rootless_search_command")"
		fi
		echo "INFO: Searching repository for VERSION '$VERSION'"
		echo "INFO: $search_command"
		if [ -z "$package_version" ]; then
			echo
			echo "ERROR: '$VERSION' not found amongst zypper search results"
			echo
			exit 1
		fi
		if [ -n "$cli_package_version" ]; then
			cli_package="$package-cli-$cli_package_version"
		fi
		if [ -n "$rootless_package_version" ]; then
			rootless_package="$package-rootless-extras-$rootless_package_version"
		fi
		package_version="-$package_version"
	fi
	(
		set -ex
		$sh_c "zypper rm -y docker docker-engine docker-libnetwork runc containerd || true"
		$sh_c "zypper install $zypper_flags --replacefiles -f -y '$package$package_version' $ZYPPER_CONTAINERD_INSTALL $cli_package $rootless_package"
	)

	# cli package is installed, and we want to pin a version
	if rpm -qa | grep "$package-cli" >/dev/null 2>/dev/null; then
		if [ -n "$VERSION" ]; then
			# zypper treats versions differently so we'll have to search for the version again
			local search_command="zypper search -s '$package-cli' | grep '$package_pattern' | tr -d '[:space:]' | cut -d'|' -f 4"
			package_version="-$($sh_c "$search_command")"
			(
				set -ex
				$sh_c "zypper install -f -y '$package-cli$package_version' $ZYPPER_CONTAINERD_INSTALL"
			)
		fi
	fi
}

main() {
	user="$(id -un 2>/dev/null || true)"
	sh_c='sh -c'
	if [ "$user" != 'root' ]; then
		if command_exists sudo; then
			sh_c='sudo -E sh -c'
		elif command_exists su; then
			sh_c='su -c'
		else
			cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
			exit 1
		fi
	fi
	dist_id="$(. /etc/os-release && echo "$ID")"
	dist_version="$(. /etc/os-release && echo "$VERSION_ID")"
	case "$dist_id:$dist_version" in
		ubuntu:14.04|ubuntu:16.04|ubuntu:18.04|ubuntu:20.04|ubuntu:22.04)
			ubuntu_install "$dist_version"
			exit 0
			;;
		centos:*|rhel:*|rocky:*|almalinux:*)
			# Strip point versions, they don't really matter
			yum_install "$dist_id" "${dist_version/\.*/}"
			exit 0
			;;
		amzn:2)
			yum_install amazonlinux 2
			exit 0
			;;
		ol:*)
			# Consider only major version for OL distros
			dist_version=${dist_version%%.*}
			yum_install "oraclelinux" "$dist_version"
			exit 0
			;;
		sles:12*|sles:15*|opensuse-leap:15*)
			zypper_install "$dist_version"
			exit 0
			;;
		*)
			echo
			echo "ERROR: Unsupported distribution / distribution version '$dist_id:$dist_version'"
			echo "       If you feel this is a mistake file an issue @ https://github.com/docker/docker-install-ee"
			echo
			exit 1
			;;
	esac
}

main
