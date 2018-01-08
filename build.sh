#!/usr/bin/env bash

function check_result {
  if [ "0" -ne "$?" ]
  then
    local err_message=${1:-""}
    local exit_die=${2:-"true"}
    local rm_roomservice=${3:-"true"}
    (repo forall -c "git reset --hard; git clean -fdx") >/dev/null
    rm -f .repo/local_manifests/dyn-*.xml
    if [ "$rm_roomservice" = "true" ]
    then
      rm -f .repo/local_manifests/roomservice.xml
    fi
    echo $err_message
    if [ "$exit_die" = "true" ]
    then
      exit 1
    fi
  fi
}

export LUNCH=choose_$CHOOSEADEVICE-userdebug

if [ -z "$HOME" ]
then
  echo HOME not in environment, guessing...
  export HOME=$(awk -F: -v v="$USER" '{if ($1==v) print $6}' /etc/passwd)
fi

if [ -z "$WORKSPACE" ]
then
  echo WORKSPACE not specified
  exit 1
fi

if [ ! -z "$GERRIT_BRANCH" ]
then
  export REPO_BRANCH=$GERRIT_BRANCH
fi

if [ -z "$REPO_BRANCH" ]
then
  echo REPO_BRANCH not specified
  exit 1
fi

if [ ! -z "$GERRIT_PROJECT" ]
then
  export ROM_BUILDTYPE=AUTOTEST
fi

if [ -z "$LUNCH" ]
then
  echo LUNCH not specified
  exit 1
fi

if [ -z "$CLEAN" ]
then
  echo CLEAN not specified
  exit 1
fi

if [ -z "$ROM_BUILDTYPE" ]
then
  echo ROM_BUILDTYPE not specified
  exit 1
fi

if [ -z "$SYNC_PROTO" ]
then
  SYNC_PROTO=git
fi

cd $WORKSPACE
rm -rf archive
mkdir -p archive
export BUILD_NO=$BUILD_NUMBER
unset BUILD_NUMBER

export PATH=~/bin:$PATH
export BUILD_WITH_COLORS=1

#if [[ "$ROM_BUILDTYPE" == "RELEASE" ]]
#then
#  export USE_CCACHE=0
#else
export USE_CCACHE=1
if [[ "CCACHING" == "1" ]]
then
  export CCACHE_NLEVELS=4
fi

#AOKP compability
export AOKP_BUILD=$ROM_BUILDTYPE

REPO=$(which repo)
if [ -z "$REPO" ]
then
  mkdir -p ~/bin
  curl https://dl-ssl.google.com/dl/googlesource/git-repo/repo > ~/bin/repo
  chmod a+x ~/bin/repo
fi

if [ -z "$BUILD_USER_ID" ]
then
  export BUILD_USER_ID=choose
fi

JENKINS_BUILD_DIR=choose-a

mkdir -p $JENKINS_BUILD_DIR
cd $JENKINS_BUILD_DIR

# always force a fresh repo init since we can build off different branches
# and the "default" upstream branch can get stuck on whatever was init first.
if [ -z "$CORE_BRANCH" ]
then
  CORE_BRANCH=$REPO_BRANCH
fi

if [ ! -z "$RELEASE_MANIFEST" ]
then
  MANIFEST="-m $RELEASE_MANIFEST"
else
  RELEASE_MANIFEST=""
  MANIFEST=""
fi

# remove manifests
rm -rf .repo/manifests*
rm -f .repo/local_manifests/dyn-*.xml
rm -f .repo/local_manifest.xml
repo init -u https://github.com/choose-a/android.git -b $REPO_BRANCH
check_result "repo init failed."
if [ ! -z "$CHERRYPICK_REV" ]
then
  cd .repo/manifests
  sleep 20
  git fetch origin $GERRIT_REFSPEC
  git cherry-pick $CHERRYPICK_REV
  cd ../..
fi

if [ $USE_CCACHE -eq 1 ]
then
  # make sure ccache is in PATH
  export PATH="$PATH:/opt/local/bin/:$PWD/prebuilts/misc/$(uname|awk '{print tolower($0)}')-x86/ccache"
  export CCACHE_DIR=/var/lib/jenkins/ccache
  mkdir -p $CCACHE_DIR
fi

if [ -f ~/.jenkins_profile ]
then
  . ~/.jenkins_profile
fi

mkdir -p .repo/local_manifests
rm -f .repo/local_manifest.xml

echo Core Manifest:
cat .repo/manifest.xml

if [[ "$SYNC_REPOS" == "no" ]]
then
  echo Skip syncing... Starting build
else
  echo Syncing...
  # if sync fails:
  # clean repos (uncommitted changes are present), don't delete roomservice.xml, don't exit
  rm -rf vendor

  mkdir -p .repo/local_manifests
  cp  ../local.xml .repo/local_manifests/

  repo sync --force-sync -d -c -f -j24
  check_result "repo sync failed.", false, false

  # sync again, delete roomservice.xml if sync fails
  #repo sync --force-sync -d -c -f -j4
  #check_result "repo sync failed.", false, true

  # last sync, delete roomservice.xml and exit if sync fails
  #repo sync --force-sync -d -c -f -j4
  #check_result "repo sync failed.", true, true

  # SUCCESS
  echo Sync complete.
fi

#$WORKSPACE/hudson/cm-setup.sh

if [ -f .last_branch ]
then
  LAST_BRANCH=$(cat .last_branch)
else
  echo "Last build branch is unknown, assume clean build"
  LAST_BRANCH=$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST
fi

if [ "$LAST_BRANCH" != "$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST" ]
then
  echo "Branch has changed since the last build happened here. Forcing cleanup."
  CLEAN="true"
fi

export OUT_DIR=/var/lib/jenkins/choose-a
. build/envsetup.sh
lunch $LUNCH
sleep 2

echo "Forcing LUNCH..."
. build/envsetup.sh
lunch $LUNCH
check_result "lunch failed."

# save manifest used for build (saving revisions as current HEAD)

# include only the auto-generated locals
#TEMPSTASH=$(mktemp -d)
#mv .repo/local_manifests/* $TEMPSTASH
#mv $TEMPSTASH/roomservice.xml .repo/local_manifests/

# save it
#repo manifest -o $WORKSPACE/archive/manifest.xml -r

# restore all local manifests
#mv $TEMPSTASH/* .repo/local_manifests/ 2>/dev/null
#rmdir $TEMPSTASH

rm -f $OUT/*.zip*

UNAME=$(uname)

if [ ! -z "$CM_EXTRAVERSION" ]
then
  export CM_EXPERIMENTAL=true
fi


if [ ! -z "$GERRIT_CHANGE_NUMBER" ]
then
  export GERRIT_CHANGES=$GERRIT_CHANGE_NUMBER
fi

if [ ! -z "$GERRIT_TOPICS" ]
then
  IS_HTTP=$(echo $GERRIT_TOPICS | grep http)
  if [ -z "$IS_HTTP" ]
  then
    #python $WORKSPACE/choose-a/build/tools/repopick.py -t $GERRIT_TOPICS
    python $WORKSPACE/hudson/repopick.py -t $GERRIT_TOPICS
    check_result "gerrit picks failed."
  else
    #python $WORKSPACE/choose-a/build/tools/repopick.py -t $(curl $GERRIT_TOPICS)
    python $WORKSPACE/hudson/repopick.py -t $(curl $GERRIT_TOPICS)
    check_result "gerrit picks failed."
  fi
  if [ ! -z "$GERRIT_XLATION_LINT" ]
  then
    python $WORKSPACE/hudson/xlationlint.py $GERRIT_TOPICS
    check_result "basic XML lint failed."
  fi
fi
if [ ! -z "$GERRIT_CHANGES" ]
then
  export CM_EXPERIMENTAL=true
  IS_HTTP=$(echo $GERRIT_CHANGES | grep http)
  if [ -z "$IS_HTTP" ]
  then
    #python $WORKSPACE/choose-a/build/tools/repopick.py $GERRIT_CHANGES
    python $WORKSPACE/hudson/repopick.py $GERRIT_CHANGES
    check_result "gerrit picks failed."
  else
    #python $WORKSPACE/choose-a/build/tools/repopick.py $(curl $GERRIT_CHANGES)
    python $WORKSPACE/hudson/repopick.py $(curl $GERRIT_CHANGES)
    check_result "gerrit picks failed."
  fi
  if [ ! -z "$GERRIT_XLATION_LINT" ]
  then
    python $WORKSPACE/hudson/xlationlint.py $GERRIT_CHANGES
    check_result "basic XML lint failed."
  fi
fi

if [ $USE_CCACHE -eq 1 ]
then
  if [ ! "$(ccache -s|grep -E 'max cache size'|awk '{print $4}')" = "64.0" ]
  then
    ccache -M 24G
  fi
  echo "============================================"
  ccache -s
  echo "============================================"
fi


rm -f $WORKSPACE/changecount
WORKSPACE=$WORKSPACE LUNCH=$LUNCH bash $WORKSPACE/hudson/changes/buildlog.sh 2>&1
if [ -f $WORKSPACE/changecount ]
then
  CHANGE_COUNT=$(cat $WORKSPACE/changecount)
  rm -f $WORKSPACE/changecount
  if [ $CHANGE_COUNT -eq "0" ]
  then
    echo "Zero changes since last build, aborting"
    exit 1
  fi
fi

LAST_CLEAN=0
if [ -f .clean ]
then
  LAST_CLEAN=$(date -r .clean +%s)
fi
TIME_SINCE_LAST_CLEAN=$(expr $(date +%s) - $LAST_CLEAN)
# convert this to hours
TIME_SINCE_LAST_CLEAN=$(expr $TIME_SINCE_LAST_CLEAN / 60 / 60)

if [ $TIME_SINCE_LAST_CLEAN -gt "24" -o $CLEAN = "true" ]
then
  echo "Cleaning!"
  touch .clean
  make clobber
else
  echo "Skipping clean: $TIME_SINCE_LAST_CLEAN hours since last clean."
fi

echo "$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST" > .last_branch

### applying custom patches
### end custom petsjes

# envsetup.sh:mka = schedtool -B -n 1 -e ionice -n 1 make -j$(cat /proc/cpuinfo | grep "^processor" | wc -l) "$@"
# Don't add -jXX. mka adds it automatically...
time mka $MAKE_BLOB
check_result "Build failed."

if [ $USE_CCACHE -eq 1 ]
then
  echo "============================================"
  ccache -V
  echo "============================================"
  ccache -s
  echo "============================================"
fi

if [[ "$INCREMENTAL" == "yes" ]]
then
  echo Making incremental update using OpenDelta
  ## Create incremental update using opendelta
  sh $WORKSPACE/opendelta.sh
fi

# /archive

cp $OUT/choose*.zip* $WORKSPACE/archive/

if [ -f $OUT/utilties/update.zip ]
then
  cp $OUT/utilties/update.zip $WORKSPACE/archive/recovery.zip
fi
if [ -f $OUT/recovery.img ]
then
  cp $OUT/recovery.img $WORKSPACE/archive/$CHOOSEADEVICE-recovery.img
fi
if [ -f $OUT/boot.img ]
then
  cp $OUT/boot.img $WORKSPACE/archive/$CHOOSEADEVICE-boot.img
fi

# archive the build.prop as well
ZIP=$(ls $WORKSPACE/archive/choose*.zip)
unzip -p $ZIP system/build.prop > $WORKSPACE/archive/build.prop

# CORE: save manifest used for build (saving revisions as current HEAD)
#rm -f .repo/local_manifests/roomservice.xml

# Stash away other possible manifests
TEMPSTASH=$(mktemp -d)
mv .repo/local_manifests $TEMPSTASH

repo manifest -o $WORKSPACE/archive/core.xml -r

mv $TEMPSTASH/local_manifests .repo
rmdir $TEMPSTASH

# chmod the files in case UMASK blocks permissions
chmod -R ugo+r $WORKSPACE/archive

CMCP=$(which cmcp)
if [ ! -z "$CMCP" -a ! -z "$CM_RELEASE" ]
then
  MODVERSION=$(cat $WORKSPACE/archive/build.prop | grep ro.modversion | cut -d = -f 2)
  if [ -z "$MODVERSION" ]
  then
    MODVERSION=$(cat $WORKSPACE/archive/build.prop | grep ro.choose-a.version | cut -d = -f 2)
  fi
  if [ -z "$MODVERSION" ]
  then
    echo "Unable to detect ro.modversion or ro.choose-a.version."
    exit 1
  fi
  echo Archiving release to S3.
  for f in $(ls $WORKSPACE/archive)
  do
    cmcp $WORKSPACE/archive/$f release/$MODVERSION/$f > /dev/null 2> /dev/null
    check_result "Failure archiving $f"
  done
fi

##end with make clobber
echo "save ssd space. Making clobber"
time make clobber
