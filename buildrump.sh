#! /usr/bin/env sh
#
# Copyright (c) 2013 Antti Kantee <pooka@iki.fi>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#

#
# This script will build rump kernel components and the hypervisor
# on a non-NetBSD host.  It will install the components as libraries
# to rump/lib and headers to rump/include.  For information on how to
# convert the installed files into running rump kernels, see the examples
# and tests directories.
#

# defaults
OBJDIR=./obj
DESTDIR=./rump
SRCDIR=./src
JNUM=4

#
# NetBSD source params
NBSRC_DATE=20130307
NBSRC_SUB=0

# for fetching the sources
NBSRC_CVSDATE="20130321 2000UTC"
NBSRC_CVSFLAGS='-z3 -d :pserver:anoncvs@anoncvs.netbsd.org:/cvsroot'

#
# support routines
#

# the parrot routine
die ()
{

	echo '>> ERROR:' >&2
	echo ">> $*" >&2
	exit 1
}

helpme ()
{

	exec 1>&2
	echo "Usage: $0 [-h] [options] [command] [command...]"
	printf "supported options:\n"
	printf "\t-d: location for headers/libs.  default: PWD/rump\n"
	printf "\t-o: location for build-time files.  default: PWD/obj\n"
	printf "\t-T: location for tools+rumpmake.  default: PWD/obj/tooldir\n"
	printf "\t-s: location of source tree.  default: PWD/src\n"
	printf "\n"
	printf "\t-j: value of -j specified to make.  default: ${JNUM}\n"
	printf "\t-q: quiet build, less compiler output.  default: noisy\n"
	printf "\t-r: release build (no -g, DIAGNOSTIC, etc.).  default: no\n"
	printf "\t-V: specify -V arguments to NetBSD build (expert-only)\n"
	printf "\t-D: increase debugginess.  default: -O2 -g\n"
	printf "\t-32: on supported hosts, build 32bit binaries.  default: 64\n"
	echo
	printf "supported commands (none supplied => fullbuild):\n"
	printf "\tcheckout:\tfetch NetBSD sources to srcdir from anoncvs\n"
	printf "\ttools:\t\tbuild necessary tools to tooldir\n"
	printf "\tbuild:\t\tbuild rump kernel components\n"
	printf "\tinstall:\tinstall rump kernel components into destdir\n"
	printf "\ttests:\t\trun tests to verify installation is functional\n"
	printf "\tfullbuild:\talias for \"tools build install tests\"\n"
	exit 1
}

#
# toolchain creation helper routines
#

appendmkconf ()
{
	[ ! -z "${1}" ] && echo "${2}${3}=${1}" >> "${BRTOOLDIR}/mk.conf"
}

#
# Not all platforms have  the same set of crt files.  for some
# reason unbeknownst to me, if the file does not exist,
# at least gcc --print-file-name just echoes the input parameter.
# Try to detect this and tell the NetBSD makefiles that the crtfile
# in question should be left empty.
chkcrt ()
{
	tst=`${CC} --print-file-name=${1}.o`
	up=`echo ${1} | tr [a-z] [A-Z]`
	[ -z "${tst%${1}.o}" ] && echo "_GCC_CRT${up}=" >>"${BRTOOLDIR}/mk.conf"
}

#
# Create tools and wrappers.  This step needs to be run at least once
# and is always run by default, but you might want to skip it for:
# 1) iteration speed on a slow-ish host
# 2) making manual modification to the tools for testing and avoiding
#    the script nuke them on the next iteration
#
# external toolchain links are created in the format that
# build.sh expects.
#
# TODO?: don't hardcore this based on PATH
# TODO2: cpp missing
maketools ()
{
	TOOLS='ar nm objcopy'

	# XXX: why can't all cc's that are gcc actually tell me
	#      that they're gcc with cc --version?!?
	if ${CC} --version | grep -q 'Free Software Foundation'; then
		CC_FLAVOR=gcc
	elif ${CC} --version | grep -q clang; then
		CC_FLAVOR=clang
		LLVM='-V HAVE_LLVM=1'
	else
		die Unsupported cc "(`which cc`)"
	fi

	#
	# Perform some toolchain feature tests to determine what options
	# we need to use for building.
	#

	cd ${OBJDIR}
	#
	# Try to test if cc supports -Wno-unused-but-set-variable.
	# This is a bit tricky since apparently gcc doesn't tell it
	# doesn't support it unless there is some other error to complain
	# about as well.  So we try compiling a broken source file...
	echo 'no you_shall_not_compile' > broken.c
	${CC} -Wno-unused-but-set-variable broken.c > broken.out 2>&1
	if ! grep -q Wno-unused-but-set-variable broken.out ; then
		W_UNUSED_BUT_SET=-Wno-unused-but-set-variable
	fi
	rm -f broken.c broken.out

	#
	# Check if the linker supports all the features of the rump kernel
	# component ldscript used for linking shared libraries.
	# If not, build only static rump kernel components.
	if [ ${LD_FLAVOR} = 'GNU' ]; then
		echo 'SECTIONS { } INSERT AFTER .data' > ldscript.test
		echo 'int main(void) {return 0;}' > test.c
		if ! $CC test.c -Wl,-T ldscript.test; then
			BUILDSHARED='-V NOPIC=1'
		fi
		rm -f test.c a.out ldscript.test
	fi

	#
	# Check if the host supports posix_memalign()
	printf '#include <stdlib.h>\nmain(){posix_memalign(NULL,0,0);}\n'>test.c
	${CC} test.c >/dev/null 2>&1 && POSIX_MEMALIGN='-DHAVE_POSIX_MEMALIGN'
	rm -f test.c a.out

	#
	# Create external toolchain wrappers.
	mkdir -p ${BRTOOLDIR}/bin || die "cannot create ${BRTOOLDIR}/bin"
	for x in ${CC_FLAVOR} ${TOOLS}; do
		# ok, it's not really --netbsd, but let's make-believe!
		tname=${BRTOOLDIR}/bin/${mach_arch}--netbsd${toolabi}-${x}

		if ${NATIVEBUILD}; then
			cmd="${x}"
		else
			cmd="${cc_target}-${x}"
		fi
		type ${cmd} >/dev/null 2>&1 \
		    || die Cannot find \"${cmd}\".  Please check \$PATH

		exec 3>&1 1>${tname}
		printf '#!/bin/sh\n\n'

		# Make the compiler wrapper mangle arguments suitable for ld.
		# Messy to plug it in here, but ...
		if [ $x = ${CC_FLAVOR} -a ${LD_FLAVOR} = 'sun' ]; then
			printf 'for x in $*; do\n'
        		printf '\t[ "$x" = "-Wl,-x" ] && continue\n'
	        	printf '\t[ "$x" = "-Wl,--warn-shared-textrel" ] '
			printf '&& continue\n\tnewargs="${newargs} $x"\n'
			printf 'done\nexec %s ${newargs}\n' ${cmd}
		else
			printf 'exec %s $*\n' ${cmd}
		fi
		exec 1>&3 3>&-
		chmod 755 ${tname}
	done

	cat > "${BRTOOLDIR}/mk.conf" << EOF
NOGCCERROR=1
BUILDRUMP_CPPFLAGS=-I${DESTDIR}/include
CPPFLAGS+=\${BUILDRUMP_CPPFLAGS}
CPPFLAGS+=${POSIX_MEMALIGN}
LIBDO.pthread=_external
RUMPKERN_UNDEF=${RUMPKERN_UNDEF}
INSTPRIV=-U
CFLAGS+=\${BUILDRUMP_CFLAGS}
AFLAGS+=\${BUILDRUMP_AFLAGS}
EOF

	appendmkconf "${W_UNUSED_BUT_SET}" "CFLAGS" +
	appendmkconf "${EXTRA_LDFLAGS}" "LDFLAGS" +
	appendmkconf "${EXTRA_CFLAGS}" "BUILDRUMP_CFLAGS"
	appendmkconf "${EXTRA_AFLAGS}" "BUILDRUMP_AFLAGS"
	appendmkconf "${RUMP_DIAGNOSTIC}" "RUMP_DIAGNOSTIC"
	appendmkconf "${RUMP_DEBUG}" "RUMP_DEBUG"
	appendmkconf "${RUMP_LOCKDEBUG}" "RUMP_LOCKDEBUG"
	appendmkconf "${DBG}" "DBG"
	[ ${LD_FLAVOR} = 'sun' ] && appendmkconf 'yes' 'HAVE_SUN_LD'

	chkcrt begins
	chkcrt ends
	chkcrt i
	chkcrt n

	# Run build.sh.  Use some defaults.
	# The html pages would be nice, but result in too many broken
	# links, since they assume the whole NetBSD man page set to be present.
	cd ${SRCDIR}
	env CFLAGS= ${binsh} build.sh -m ${machine} -u \
	    -D ${OBJDIR}/dest -w ${RUMPMAKE} \
	    -T ${BRTOOLDIR} -j ${JNUM} \
	    ${LLVM} ${BEQUIET} ${BUILDSHARED} ${BUILDSTATIC} ${SOFTFLOAT} \
	    -V EXTERNAL_TOOLCHAIN=${BRTOOLDIR} -V TOOLCHAIN_MISSING=yes \
	    -V TOOLS_BUILDRUMP=yes \
	    -V MKGROFF=no \
	    -V MKARZERO=no \
	    -V NOPROFILE=1 \
	    -V NOLINT=1 \
	    -V USE_SSP=no \
	    -V MKHTML=no -V MKCATPAGES=yes \
	    -V SHLIBINSTALLDIR=/usr/lib \
	    -V TOPRUMP="${SRCDIR}/sys/rump" \
	    -V MAKECONF="${BRTOOLDIR}/mk.conf" \
	    -V MAKEOBJDIR="\${.CURDIR:C,^(${SRCDIR}|${BRDIR}),${OBJDIR},}" \
	    ${BUILDSH_VARGS} \
	  tools
	[ $? -ne 0 ] && die build.sh tools failed
}

# Fetches NetBSD source tree from anoncvs.netbsd.org
# Uses the version tag indicated at the start of this script.
checkout ()
{

	# make sure we know where SRCDIR is
	mkdir -p ${SRCDIR} || die cannot access ${SRCDIR}
	abspath SRCDIR

	if ! type cvs >/dev/null 2>&1 ;then
		echo '>> Need cvs for checkout functionality'
		echo '>> Ensure that cvs is in PATH and run again'
		echo '>> or fetch the NetBSD sources manually'
		die No cvs in PATH
	fi

	echo ">> Fetching the necessary subset of NetBSD source tree to:"
	echo "   ${SRCDIR}"
	echo '>> This will take a few minutes and requires ~200MB of disk space'

	cd ${SRCDIR}
	# trick cvs into "skipping" the module name so that we get
	# all the sources directly into $SRCDIR
	rm -f src
	ln -s . src

	# squelch .cvspass whine
	export CVS_PASSFILE=/dev/null

	# Next, we need listsrcdirs.  For some reason, we also need to
	# check out one file directly under src or we get weird errors later
	cvs ${NBSRC_CVSFLAGS} co -P -D "${NBSRC_CVSDATE}" \
	    src/build.sh src/sys/rump/listsrcdirs || die checkout failed

	# now, do the real checkout
	sh ./sys/rump/listsrcdirs -c | xargs cvs ${NBSRC_CVSFLAGS} co -P \
	    -D "${NBSRC_CVSDATE}" || die checkout failed

	# remove the symlink used to trick cvs
	rm -f src
	echo '>> checkout done'
}

probehost ()
{

	#
	# Check for ld because we need to make some adjustments based on it
	if ${CC} -Wl,--version 2>&1 | grep -q 'GNU ld' ; then
		LD_FLAVOR=GNU
	elif ${CC} -Wl,--version 2>&1 | grep -q 'Solaris Link Editor' ; then
		LD_FLAVOR=sun
	else
		die 'GNU or Solaris ld required'
	fi

	# Check for GNU ar
	# XXX: copypasted tool_ar stuff
	if ${NATIVEBUILD}; then
		tool_ar=ar
	else
		tool_ar="${cc_target}-ar"
	fi
	if ! ${tool_ar} --version 2>/dev/null | grep -q 'GNU ar' ; then
		die Need GNU toolchain in PATH, `which ar` is not
	fi
}

#
# BEGIN SCRIPT
#

# scrub env in case they're set for crossbuilds
# (we handle these when creating wrappers)
unset AR CPP NM OBJCOPY

# check for crossbuild
NATIVEBUILD=true
if [ -z "${CC}" ]; then
	CC=cc
fi
[ ${CC} != 'cc' -a ${CC} != 'gcc' -a ${CC} != 'clang' ] && NATIVEBUILD=false
type ${CC} > /dev/null 2>&1 || die cannot find \$CC: \"${CC}\".  check env.

DBG='-O2 -g'
ANYHOSTISGOOD=false
NOISE=2
debugginess=0
BRDIR=$(dirname $0)
THIRTYTWO=false
while getopts '3:d:DhHj:o:qrs:T:V:' opt; do
	case "$opt" in
	3)
		[ ${OPTARG} != '2' ] && die 'invalid option. did you mean -32?'
		THIRTYTWO=true
		;;
	j)
		JNUM=${OPTARG}
		;;
	d)
		DESTDIR=${OPTARG}
		;;
	D)
		[ ! -z "${RUMP_DIAGNOSTIC}" ]&& die Cannot specify releasy debug

		debugginess=$((debugginess+1))
		[ ${debugginess} -gt 0 ] && DBG='-O0 -g'
		[ ${debugginess} -gt 1 ] && RUMP_DEBUG=1
		[ ${debugginess} -gt 2 ] && RUMP_LOCKDEBUG=1
		;;
	H)
		ANYHOSTISGOOD=true
		;;
	q)
		# build.sh handles value going negative
		NOISE=$((NOISE-1))
		;;
	o)
		OBJDIR=${OPTARG}
		;;
	r)
		[ ${debugginess} -gt 0 ] && die Cannot specify debbuggy release
		RUMP_DIAGNOSTIC=no
		DBG=''
		;;
	s)
		SRCDIR=${OPTARG}
		;;
	T)
		BRTOOLDIR=${OPTARG}
		;;
	V)
		BUILDSH_VARGS="${BUILDSH_VARGS} -V ${OPTARG}"
		;;
	-)
		break
		;;
	h|\?)
		helpme
		;;
	esac
done
shift $((${OPTIND} - 1))
BEQUIET="-N${NOISE}"
[ -z "${BRTOOLDIR}" ] && BRTOOLDIR=${OBJDIR}/tooldir

probehost

#
# Determine what which parts we should execute.
#
allcmds="checkout tools build install tests fullbuild"
fullbuildcmds="tools build install tests"

for cmd in ${allcmds}; do
	eval do${cmd}=false
done
if [ $# -ne 0 ]; then
	for arg in $*; do
		while true ; do
			for cmd in ${allcmds}; do
				if [ "${arg}" = "${cmd}" ]; then
					eval do${cmd}=true
					break 2
				fi
			done
			die "Invalid arg $arg"
		done
	done
else
	dofullbuild=true
fi
if ${dofullbuild} ; then
	for cmd in ${fullbuildcmds}; do
		eval do${cmd}=true
	done
fi

if [ ! -f "${SRCDIR}/build.sh" -o ! -f "${SRCDIR}/sys/rump/Makefile" ]; then
	[ $? -ne 0 ] && die \"${SRCDIR}\" is not a NetBSD source tree.  try -h
fi

mkdir -p ${OBJDIR} || die cannot create ${OBJDIR}
mkdir -p ${DESTDIR} || die cannot create ${DESTDIR}
mkdir -p ${BRTOOLDIR} || die "cannot create ${BRTOOLDIR} (tooldir)"

abspath ()
{

	curdir=`pwd -P`
	eval cd \${${1}}
	eval ${1}=`pwd -P`
	cd ${curdir}
}

# resolve critical directories
abspath DESTDIR
abspath OBJDIR
abspath BRTOOLDIR
abspath BRDIR

${docheckout} && checkout
abspath SRCDIR

# source test routines, to be run after build
. ${BRDIR}/tests/testrump.sh

# check if NetBSD src is new enough
oIFS="${IFS}"
IFS=':'
exec 3>&2 2>/dev/null
ver="`sed -n 's/^BUILDRUMP=//p' < ${SRCDIR}/sys/rump/VERSION`"
exec 2>&3 3>&-
set ${ver} 0
[ "1${1}" -lt "1${NBSRC_DATE}" \
  -o \( "1${1}" -eq "1${NBSRC_DATE}" -a "1${2}" -lt "1${NBSRC_SUB}" \) ] \
    && die "Update of NetBSD source tree to ${NBSRC_DATE}:${NBSRC_SUB} required"
IFS="${oIFS}"

hostos=`uname -s`
binsh=sh
THIRTYTWO_HOST=false
case ${hostos} in
"DragonFly")
	RUMPKERN_UNDEF='-U__DragonFly__'
	;;
"FreeBSD")
	RUMPKERN_UNDEF='-U__FreeBSD__'
	;;
"Linux")
	RUMPKERN_UNDEF='-Ulinux -U__linux -U__linux__ -U__gnu_linux__'
	EXTRA_RUMPUSER='-ldl'
	EXTRA_RUMPCLIENT='-lpthread -ldl'
	;;
"NetBSD")
	# what do you expect? ;)
	;;
"SunOS")
	RUMPKERN_UNDEF='-U__sun__ -U__sun -Usun'
	EXTRA_RUMPUSER='-lsocket -lrt -ldl -lnsl'
	EXTRA_RUMPCLIENT='-lsocket -ldl -lnsl'
	binsh=/usr/xpg4/bin/sh

	THIRTYTWO_HOST=true

	# I haven't managed to get static libs to work on Solaris,
	# so just be happy with shared ones
	BUILDSTATIC='-V NOSTATICLIB=1'
	;;
"CYGWIN_NT"*)
	BUILDSHARED='-V NOPIC=1'
	host_notsupp='yes'
	;;
*)
	host_notsupp='yes'
	;;
esac

if [ "${host_notsupp}" = 'yes' ]; then
	${ANYHOSTISGOOD} || die unsupported host OS: ${hostos}
fi

if ${THIRTYTWO}; then
	${THIRTYTWO_HOST} || ${ANYHOSTISGOOD} || \
	    die 'host not known to support 32bit.  get lucky with -H?'
fi

# Check the arch we're building for so as to work out the necessary
# NetBSD machine code we need to use.  Use ${CC} -v instead of -dumpmachine
# since at least older versions of clang don't support -dumpmachine ... yay!
cc_target=$(${CC} -v 2>&1 | sed -n '/^Target/{s/Target: //p;}' )
mach_arch=$(echo ${cc_target} | sed 's/-.*//' )
[ $? -ne 0 ] && die failed to figure out target arch of \"${CC}\"

case ${mach_arch} in
"x86_64")
	if ${THIRTYTWO} ; then
		machine="i386"
		mach_arch="i486"
		toolabi="elf"
		EXTRA_CFLAGS='-D_FILE_OFFSET_BITS=64 -m32'
		EXTRA_LDFLAGS='-m32'
		EXTRA_AFLAGS='-D_FILE_OFFSET_BITS=64 -m32'
	else
		machine="amd64"
	fi
	;;
"i386"|"i686")
	machine="i386"
	mach_arch="i486"
	toolabi="elf"
	;;
"arm"|"armv6l")
	machine="evbarm"
	mach_arch="arm"
	toolabi="elf"
	# XXX: assume at least armv6k due to armv6 inaccuracy in NetBSD
	EXTRA_CFLAGS='-march=armv6k'
	EXTRA_AFLAGS='-march=armv6k'

	# force hardfloat, the default (i.e. soft) doesn't work on all hosts
	SOFTFLOAT='-V MKSOFTFLOAT=no'
	;;
"sparc")
	# We assume it's an UltraSPARC.  If someone wants to build on
	# an actual 32bit SPARC, send patches (or always use -32)
	if ${THIRTYTWO} ; then
		machine="sparc"
		mach_arch="sparc"
		toolabi="elf"
		EXTRA_CFLAGS='-D_FILE_OFFSET_BITS=64'
		EXTRA_AFLAGS='-D_FILE_OFFSET_BITS=64'
	else
		machine="sparc64"
		mach_arch="sparc64"
		EXTRA_CFLAGS='-m64'
		EXTRA_LDFLAGS='-m64'
		EXTRA_AFLAGS='-m64'
	fi
	;;
esac
[ -z "${machine}" ] && die script does not know machine \"${mach_arch}\"

RUMPMAKE="${BRTOOLDIR}/rumpmake"
${dotools} && maketools

setupdest ()
{

	# set up $dest via symlinks.  this is easier than trying to teach
	# the NetBSD build system that we're not interested in an extra
	# level of "usr"
	mkdir -p ${DESTDIR}/include/rump || die create ${DESTDIR}/include/rump
	mkdir -p ${DESTDIR}/lib || die create ${DESTDIR}/lib
	mkdir -p ${DESTDIR}/man || die create ${DESTDIR}/man
	mkdir -p ${OBJDIR}/dest/usr/share/man \
	    || die create ${OBJDIR}/dest/usr/share/man
	ln -sf ${DESTDIR}/include ${OBJDIR}/dest/usr/include
	ln -sf ${DESTDIR}/lib ${OBJDIR}/dest/usr/lib
	for man in cat man ; do 
		for x in 1 2 3 4 5 6 7 8 9 ; do
			ln -sf ${DESTDIR}/man \
			    ${OBJDIR}/dest/usr/share/man/${man}${x}
		done
	done
}

#
# Now it's time to build.  This takes 4 passes, just like when
# building NetBSD the regular way.  The passes are:
# 1) obj
# 2) includes
# 3) dependall
# 4) install
#

${dobuild} && targets="obj includes dependall"
${dobuild} && setupdest
${doinstall} && targets="${targets} install"

DIRS_first='lib/librumpuser'
DIRS_second='lib/librump'
DIRS_final="lib/librumpclient lib/librumpdev lib/librumpnet lib/librumpvfs
    sys/rump/dev sys/rump/fs sys/rump/kern sys/rump/net sys/rump/include
    ${BRDIR}/brlib"
[ "`uname`" = "Linux" ] && \
    DIRS_final="${DIRS_final} lib/librumphijack sys/rump/kern/lib/libsys_linux"

# create the makefiles used for building
mkmakefile ()
{

	makefile=$1
	shift
	exec 3>&1 1>${makefile}
	printf '# GENERATED FILE, MIGHT I SUGGEST NOT EDITING?\n'
	printf 'SUBDIR='
	for dir in $*; do
		case ${dir} in
		/*)
			printf ' %s' ${dir}
			;;
		*)
			printf ' %s' ${SRCDIR}/${dir}
			;;
		esac
	done

	printf '\n\n.include <bsd.subdir.mk>\n'
	exec 1>&3 3>&-
}

mkmakefile ${OBJDIR}/Makefile.first ${DIRS_first}
mkmakefile ${OBJDIR}/Makefile.second ${DIRS_second}
mkmakefile ${OBJDIR}/Makefile.final ${DIRS_final}
mkmakefile ${OBJDIR}/Makefile.all ${DIRS_first} ${DIRS_second} ${DIRS_final}

domake ()
{

	${RUMPMAKE} -j ${JNUM} -f ${1} ${2}
	[ $? -eq 0 ] || die "make $1 $2"
}

# try to minimize the amount of domake invocations.  this makes a
# difference especially on systems with a large number of slow cores
for target in ${targets}; do
	if [ ${target} = "dependall" ]; then
		domake ${OBJDIR}/Makefile.first ${target}
		domake ${OBJDIR}/Makefile.second ${target}
		domake ${OBJDIR}/Makefile.final ${target}
	else
		domake ${OBJDIR}/Makefile.all ${target}
	fi
done

# run tests from testrump.sh we sourced earlier
${dotests} && alltests

exit 0
