#!/bin/bash

#
# .travis-functions.sh:
#   - helper functions to be sourced from .travis.yml
#   - designed to respect travis' environment but testing locally is possible
#

if [ ! -f "configure.ac" ]; then
	echo ".travis-functions.sh must be sourced from source dir" >&2
	return 1 || exit 1
fi

## some config settings
# travis docs say we get 1.5 CPUs
MAKE="make -j2"
DUMP_CONFIG_LOG="short"
DO_MAKE_CHECK="yes"
DO_MAKE_INSTALL="yes"
export TS_OPT_parsable="yes"
test "$DO_MAKE_CHECK" = "yes" || xxx='TS_COMMAND="true"'

# workaround ugly warning on travis OSX,
# see https://github.com/direnv/direnv/issues/210
shell_session_update() { :; }

function xconfigure
{
	which "$CC"
	"$CC" --version

	export PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig
	export CFLAGS="-m32 -g -O2"

	./configure "$@" $OSX_CONFOPTS
	err=$?
	if [ "$DUMP_CONFIG_LOG" = "short" ]; then
		grep -B1 -A10000 "^## Output variables" config.log | grep -v "_FALSE="
	elif [ "$DUMP_CONFIG_LOG" = "full" ]; then
		cat config.log
	fi

	# use -Werror only for make not in configure
	if test -z "$WERROR"; then
		ccc="CFLAGS=$CFLAGS"
	elif test "$WERROR" = "yes" ; then
		ccc="CFLAGS=$CFLAGS -Werror"
	else
		ccc="CFLAGS=$CFLAGS -Werror $WERROR"
	fi

	return $err
}

# TODO: integrate checkusage into our regular tests and remove this function
function make_checkusage
{
	local tmp
	if ! tmp=$($MAKE checkusage 2>&1) || test -n "$tmp"; then
		echo "$tmp"
		echo "make checkusage failed" >&2
		return 1
	fi
}

function check_nonroot
{
	local opts="$MAKE_CHECK_OPTS --show-diff"

	xconfigure \
		--disable-use-tty-group \
		--disable-makeinstall-chown \
		--enable-all-programs \
		|| return
	$MAKE "$ccc"|| return

	osx_prepare_check
	$MAKE "$ccc" check $xxx TS_OPTS="$opts" || return

	make_checkusage || return

	test "$DO_MAKE_INSTALL" = "yes" || return 0
	$MAKE install DESTDIR=/tmp/dest || return
}

function check_root
{
	local opts="$MAKE_CHECK_OPTS --show-diff"

	xconfigure \
		--enable-all-programs \
		|| return
	$MAKE "$ccc" || return

	$MAKE "$ccc" check TS_COMMAND="true" || return
	osx_prepare_check
	sudo -E $MAKE check TS_OPTS="$opts" || return

	make_checkusage || return

	# root on osx has not enough permission for make install ;)
	[ "$TRAVIS_OS_NAME" = "osx" ] && return

	# keep PATH to make sure sudo would find $CC
	sudo env "PATH=$PATH" $MAKE install || return
}

function check_dist
{
	xconfigure \
		|| return
	$MAKE distcheck || return
}

# should work for all Ubuntu versions
function get_dist_codename()
{
	(. /etc/lsb-release &&
		test -n $DISTRIB_CODENAME && echo "$DISTRIB_CODENAME") && return

	(. /etc/os-release &&
		test -n $VERSION_CODENAME && echo "$VERSION_CODENAME") && return

	echo "error, unable to determine distro codename" >&2
	echo "unknown"
	return 1
}

# Prepare updates of $CC to $CCVER. This function sets CC and CC_PACKAGES and
# adds some custom repos. Should work for many Ubuntu versions.
function cc_update_prepare()
{
	# add some source repositories for optional compiler updates
	if echo "$CC" | grep -q "gcc"; then
		CC="gcc-$CCVER"
		CC_PACKAGES="gcc-$CCVER gcc-$CCVER-multilib"
		sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
	elif echo "$CC" | grep -q "clang"; then
		local subrepo=$(get_dist_codename) || return

		CC="clang-$CCVER"
		CC_PACKAGES="clang-$CCVER"

		if ! [[ $CCVER =~ ^3 ]]; then
			wget -O - http://llvm.org/apt/llvm-snapshot.gpg.key| sudo apt-key add -
			# the versioned repo may or may not exists ...
			sudo add-apt-repository -y "deb http://apt.llvm.org/$subrepo/ llvm-toolchain-$subrepo-$CCVER main"
		fi
	else
		echo "error, don't know how to update unknown CC='$CC'" >&2
		return 1
	fi

	# this function ignores most errors, after installation we will check $CC
}

function travis_install_script
{
	if [ "$TRAVIS_OS_NAME" = "osx" ]; then
		osx_install_script
		return
	fi

	# optionally update compiler
	local CC_PACKAGES
	if test -n "$CCVER"; then
		cc_update_prepare || return
		echo "NOTE: added packages '$CC_PACKAGES' to update CC='$CC'"
	fi

	local TEST_PACKAGES
	if test "$DO_MAKE_CHECK" = "yes"; then
	TEST_PACKAGES="
		bc \
		btrfs-tools \
		dnsutils \
		gtk-doc-tools \
		mdadm \
		ntp \
		socat \
		"
	fi

	echo "xxxxx: python before"
	ls -ld /usr/bin/pyth*
	file $(readlink -f $(which python))
	python --version

	# install required packages
	sudo apt-get -qq update --fix-missing
	sudo aptitude -y -V  install \
		autopoint \
		gettext \
		gcc-multilib \
		lib32ncursesw5-dev \
		lib32readline6-dev \
		libcap-ng:i386 \
		libcap-ng-dev:i386 \
		libpam-dev:i386 \
		libudev-dev:i386 \
		zlib1g-dev:i386 \
		$CC_PACKAGES \
		$TEST_PACKAGES \
		|| return


	sudo aptitude -y -V  install \
		libpython-all-dev:i386 \
		libpython-dev:i386 \
		python:i386 \
		python2.7-minimal:i386 \
		|| return

	echo "xxxxx: python after"
	ls -ld /usr/bin/pyth*
	file $(readlink -f $(which python))
	python --version
	dpkg -l | grep python

	sudo aptitude -y -V  install \
		python-minimal:i386 \
		python2.7:i386 \
		|| return

	echo "xxxxx: python after 2"
	ls -ld /usr/bin/pyth*
	file $(readlink -f $(which python))
	python --version
	dpkg -l | grep python

	# install only if available (e.g. Ubuntu Trusty)
	sudo aptitude -y -V  install \
		libsystemd-daemon-dev:i386 \
		libsystemd-journal-dev:i386 \
		|| true

	# check $CC
	if ! type "$CC"; then
		echo "error, update $CC failed" >&2
		return 1
	fi
}

function osx_install_script
{
	brew update >/dev/null

	brew install gettext ncurses socat xz
	brew link --force gettext
	brew link --force ncurses

	OSX_CONFOPTS="
		--disable-ipcrm \
		--disable-ipcs \
	"

	# workaround: glibtoolize could not find sed
	export SED="sed"
}

function osx_prepare_check
{
	[ "$TRAVIS_OS_NAME" = "osx" ] || return 0
	[ "$DO_MAKE_CHECK" = "yes" ] ||  return 0

	# these ones only need to be gnu for our test-suite
	brew install coreutils findutils gnu-tar gnu-sed

	# symlink minimally needed gnu commands into PATH
	mkdir ~/bin
	for cmd in readlink seq timeout truncate find xargs tar sed; do
		ln -s /usr/local/bin/g$cmd $HOME/bin/$cmd
	done
	hash -r

	export TS_OPT_col_multibyte_known_fail=yes
	export TS_OPT_colcrt_regressions_known_fail=yes
	export TS_OPT_column_invalid_multibyte_known_fail=yes
}

function travis_before_script
{
	set -o xtrace

	./autogen.sh
	ret=$?

	set +o xtrace
	return $ret
}

function travis_script
{
	local ret
	set -o xtrace

	case "$MAKE_CHECK" in
	nonroot)
		check_nonroot
		;;
	root)
		check_root
		;;
	dist)
		check_dist
		;;
	*)
		echo "error, check environment (travis.yml)" >&2
		false
		;;
	esac

	# We exit here with case-switch return value!
	ret=$?
	set +o xtrace
	return $ret
}

function travis_after_script
{
	local diff_dir
	local tmp

	# find diff dir from check as well as from distcheck
	diff_dir=$(find . -type d -name "diff" | grep "tests/diff" | head -n 1)
	if [ -d "$diff_dir" ]; then
		tmp=$(find "$diff_dir" -type f | sort)
		echo -en "dump test diffs:\n${tmp}\n"
		echo "$tmp" | xargs cat
	fi
}
