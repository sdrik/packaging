#!/bin/bash -e

die()
{
    echo $1
    exit 1
}

help()
{
	echo "Usage: $0 [git_branch] [target_dir] [additional_patches]"
	echo "git_branch -> optional: the GIT branch of MythTV to build"
	echo "target_dir -> optional: the dir used for the & GIT checkouts"
	echo "additional_patches -> optional: space separated full path to all patches to apply"
	echo ""
	echo "If the target_dir already contains git checkouts, they"
	echo "will just be updated to the latest HEAD followed by the git"
	echo "checkout being checked out to the branch indicated."
	echo ""
	echo "Example:"
	echo " $0"
	echo "  This would check out the branch matching packaging branch name and build debs in `pwd`"
	echo ""
	echo " $0 fixes/0.27 /tmp"
	echo "  This would checkout out the fixes/0.27 branch, local packaging and build debs in /tmp"
	echo ""
	echo " $0 fixes/0.27 /tmp /full/path/to/patch"
	echo "  This would checkout the fixes/0.27 branch, local packaging, apply the patch called "
	echo "  'patch' located at /full/path/to/ to the build and then produce debs"
	exit 0
}

export QUILT_PATCHES="debian/patches"
[ -n "$GIT_BRANCH" ] && GIT_BRANCH=""
[ -n "$DIRECTORY" ] && DIRECTORY=""
[ -n "$PATCHES" ] && PATCHES=""
[ -z "$DEBUILD_FLAGS" ] && DEBUILD_FLAGS="-us -uc -i -I.git"

if [ ! -d `dirname $0`/debian ]; then
	die "WARNING: This script will not work without a full checkout from git://github.com/MythTV/packaging.git"
fi

for arg in "$@"; do
	if [ "$1" = "help" ] || [ "$1" = "--help" ] || [ "$1" = "/?" ]; then
		help
	fi
	if [ -z "$DIRECTORY" ] && [ -d "$arg" ]; then
		DIRECTORY=$arg
		continue
	fi
	if [ -f "$arg" ]; then
		PATCHES="$PATCHES $arg"
		continue
	fi
	if [ -z "$GIT_BRANCH" ]; then
		GIT_BRANCH=$arg
		continue
	fi
done

#identify running branch
pushd `dirname $0` >/dev/null
RUNNING_BRANCH=`git branch| sed '/*/!d; s,^* ,,'`
popd > /dev/null

if [ -z "$GIT_BRANCH" ]; then
	GIT_BRANCH=$RUNNING_BRANCH
elif [ "$GIT_BRANCH" != "$RUNNING_BRANCH" ]; then
	pushd `dirname $0` > /dev/null
	echo "Requested to build $GIT_BRANCH but running on $RUNNING_BRANCH."
	echo "Repeating checkout process."
	git checkout $GIT_BRANCH
	$0 $@
	exit 0
fi
if [ -z "$DIRECTORY" ]; then
	DIRECTORY=`pwd`
fi
if echo "$GIT_BRANCH" | grep fixes 2>&1 1>/dev/null; then
	GIT_TYPE="fixes"
	GIT_MAJOR_RELEASE=$(echo $GIT_BRANCH |sed 's,.*0.,,')
	DELIMITTER="+"
	echo "Building for fixes, v0.$GIT_MAJOR_RELEASE in $DIRECTORY"
elif echo "$GIT_BRANCH" | grep athome 2>&1 1>/dev/null; then
	GIT_TYPE="athome"
	GIT_MAJOR_RELEASE=$(echo $GIT_BRANCH |sed 's,.*0.,,')
	DELIMITTER="+"
	echo "Building for athome, v0.$GIT_MAJOR_RELEASE in $DIRECTORY"
else
	GIT_TYPE="master"
	DELIMITTER="~"
	echo "Building for master in $DIRECTORY"
fi

if [ "`basename $0`" = "build-dsc.sh" ]; then
    TYPE="source"
else
    TYPE="binary"
fi

#for checking out git
if ! which git 1>/dev/null; then
	echo "Missing git-core, marking for installation"
	sudo apt-get install git-core || die "Error installing git-core"
fi

#make sure we have debuild no matter what
if ! which debuild 1>/dev/null; then
    echo "Missing debuild, marking for installation"
    sudo apt-get install devscripts --no-install-recommends|| die "Error installing devscripts"
fi

#clone in our packaging branch
mkdir -p $DIRECTORY/mythtv
rm -rf $DIRECTORY/mythtv/debian
cp -R `dirname $0`/debian $DIRECTORY/mythtv
cp $DIRECTORY/mythtv/debian/changelog.in $DIRECTORY/mythtv/debian/changelog

#build packaging changelog
DATE=$(dpkg-parsechangelog -l$DIRECTORY/mythtv/debian/changelog | sed '/^Version/!d; s/.*~//; s/.*+//; s/-.*//;' | awk -F. '{print $2}')
TODAY=$(date +%Y%m%d)
pushd `dirname $0` >/dev/null
PACKAGING_HASH=$(git log -1 --oneline | awk '{ print $1 }')
if [ "$DATE" != "$TODAY" ]; then \
	echo "Packaging changes between $DATE and $TODAY:" > $DIRECTORY/mythtv/.gitout
	GIT_DATE=`echo $DATE | sed 's/^\(.\{4\}\)/\1./; s/^\(.\{7\}\)/\1./'`
	git log --grep="^deb: " --oneline --since="$GIT_DATE" | sed 's/^/[/; s/ deb:/]/' >> $DIRECTORY/mythtv/.gitout
fi
popd >/dev/null
cd $DIRECTORY/mythtv


##set changelog entry
#these can be filled in potentially from external sources
[ -z "$GIT_MAJOR_RELEASE" ] && GIT_MAJOR_RELEASE=$(dpkg-parsechangelog | sed '/^Version/!d; s/.*[0-9]:0.//; s/~.*//; s/+.*//' | awk -F. '{print $1 }')
[ -z "$GIT_MINOR_RELEASE_FIXES" ] && GIT_MINOR_RELEASE=$(dpkg-parsechangelog | sed '/^Version/!d; s/.*[0-9]:0.//; s/~.*//; s/+.*//' | awk -F. '{print $2 }')
[ -z "$DEBIAN_SUFFIX" ] && DEBIAN_SUFFIX=$(dpkg-parsechangelog | sed '/^Version/!d; s/.*-//;')
#these should always be parsed from the old changelog
EPOCH=$(dpkg-parsechangelog | sed '/^Version/!d; s/.* //; s/:.*//;')
#actually bump the changelog up. don't include a git hash here right now.
dch -b -v $EPOCH:0.$GIT_MAJOR_RELEASE.$GIT_MINOR_RELEASE$DELIMITTER$GIT_TYPE.$TODAY.-$DEBIAN_SUFFIX "Scripted Build from $GIT_TYPE git packaging [$PACKAGING_HASH]"
if [ -f .gitout ]; then
	while read line
	do
		dch -a "$line"
	done < .gitout
	rm .gitout
fi

#clean up any old patches (just in case)
if [ -d .pc ]; then
	quilt pop -a 2>/dev/null || rm -rf .pc
fi

#make sure that we have things stashed if necessary
DELTA=$(git status -s -uno || true)
if [ -n "$DELTA" ]; then
	git stash -q 2>/dev/null || true
fi

#check out/update checkout
debian/rules get-git-source LAST_GIT_HASH='' GIT_BRANCH=$GIT_BRANCH

#new upstream version
UPSTREAM_VERSION=$(dpkg-parsechangelog | sed '/^Version/!d; s/.*[0-9]://; s/-.*//')

# 0) Check for a orig tarball file.  If no file then:
# 1) build a tarball
# 2) is this an autobuild?  if so, double check whether the tarball already
#    existed in the primary archive
#    A) if so, this replaces it so that we have consistent md5sums
#    B) if it didn't this will do nothing.
if [ ! -f ../mythtv_$UPSTREAM_VERSION.orig.tar.gz ]; then
	debian/rules build-tarball
	if echo $DEBIAN_SUFFIX | grep 'mythbuntu' 2>&1 1>/dev/null; then
		debian/rules get-orig-source
	fi
fi

if [ "$TYPE" = "binary" ]; then
    #Make sure we have the package for dpkg-checkbuilddeps
    if ! which dpkg-checkbuilddeps 2>&1 1>/dev/null; then
        echo "Missing dpkg-dev, marking for installation"
        sudo apt-get install dpkg-dev --no-install-recommends -y || die "Error installing dpkg-dev"
    fi

    #mk-build-deps is used
    if ! which mk-build-deps 2>&1 1>/dev/null; then
        echo "Missing mk-build-deps, marking for installation"
        sudo apt-get install devscripts -y --no-install-recommends || die "Error installing devscripts"
    fi

    #equivs needed for mk-build-deps
    if ! which equivs-build 2>&1 1>/dev/null; then
        echo "Missing equivs-build, marking for installation"
        sudo apt-get install equivs -y --no-install-recommends || die "Error installing equivs"
    fi

    #test and install deps as necessary
    if ! dpkg-checkbuilddeps 1>/dev/null 2>&1; then
	echo "Missing build dependencies for mythtv, will install them now:"
        sudo mk-build-deps debian/control.in -ir || die "error installing dependencies"
    fi
elif [ "$TYPE" = "source" ]; then
    DEBUILD_FLAGS="-S $DEBUILD_FLAGS"
fi

#update changelog and control files
debian/rules update-control-files

#mark the ubuntu target in the changelog
[ -z "$UBUNTU_RELEASE" ] && UBUNTU_RELEASE=$(lsb_release -s -c)
dch -b --force-distribution -D $UBUNTU_RELEASE ""

#if we have patch arguments, apply them
if [ -n "$PATCHES" ]; then
	for PATCH in $PATCHES; do
		cp $PATCH debian/patches
		echo $(basename $PATCH) >> debian/patches/series
		dch -a "Applied $PATCH to build"
	done
fi

echo "Testing all patches before building the packages"
quilt push -aq || (quilt pop -aqf && exit 1)
quilt pop -aq

#build the packages
echo "Building the packages"
debuild $DEBUILD_FLAGS

#remove all patches and cleanup
#seems newer dpkg-source might not need the extra quilt pop
echo "Cleaning up"
quilt pop -aqf || true
debian/rules clean
