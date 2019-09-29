#!/bin/sh

# Currently, we build gnuradio 3.8 for Python3.7.
GNURADIO_BRANCH=3.8.0.0

# default os x path minus /usr/local/bin, which could have pollutants
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

EXTS="zip tar.gz tgz tar.bz2 tbz2 tar.xz"

SKIP_FETCH=true
SKIP_AUTORECONF=
SKIP_LIBTOOLIZE=
KEEP_ON_MISMATCH=
COPY_HASH_ON_MISMATCH=true

DEBUG=true

function top_srcdir() {
  local r
  pushd "$(dirname "${0}")" > /dev/null
  r="$(pwd -P)"
  popd > /dev/null
  echo "${r}"
}

function I() {
  echo "I: ${@}"
}

function E() {
  local r
  r=$?
  if [ 0 -eq $r ]; then
    r=1;
  fi
  echo "E: ${@}" > /dev/stderr
  exit 1;
}

function D() {
  if [ "" != "$DEBUG" ]; then
    echo "D: ${@}"
  fi
}

function ncpus() {
  sysctl -n hw.ncpu
}

[[ "$(uname)" = "Darwin" ]] \
  || E "This script is only intended to be run on Mac OS X"

XQUARTZ_APP_DIR=/Applications/Utilities/XQuartz.app

BUILD_DIR="$(top_srcdir)"
TMP_DIR=${BUILD_DIR}/tmp
APP_DIR="${APP_DIR:-"/Applications/GNURadio.app"}"
CONTENTS_DIR=${APP_DIR}/Contents
RESOURCES_DIR=${CONTENTS_DIR}/Resources
INSTALL_DIR=${CONTENTS_DIR}/MacOS

MAKE="${MAKE:-"make -j$(ncpus)"}"

PYTHON_VERSION=3.7
PYTHON_FRAMEWORK_DIR="/Library/Frameworks/Python.framework/Versions/${PYTHON_VERSION}"
PYTHON="${PYTHON_FRAMEWORK_DIR}/Resources/Python.app/Contents/MacOS/Python"
PYTHON_CONFIG="${PYTHON_FRAMEWORK_DIR}/lib/python3.7/config-3.7m-darwin/python-config.py"


export PYTHONPATH=${INSTALL_DIR}/usr/lib/python${PYTHON_VERSION}/site-packages
export SDLDIR=${INSTALL_DIR}/usr

function check_prerequisites() {
  
  XCODE_DEVELOPER_DIR_CMD="xcode-select -p"
  [[ "" = "$(${XCODE_DEVELOPER_DIR_CMD} 2>/dev/null)" ]] \
    && E "Xcode command-line developer tools are not installed. You can install them with 'xcode-select --install'"
  
  [[ -d ${XQUARTZ_APP_DIR} ]] \
    || E "XQuartz is not installed. Download it at http://www.xquartz.org/"

  [[ -d ${PYTHON_FRAMEWORK_DIR} ]] \
    || E "Python 3.7 is not installed. Download it here: https://www.python.org/downloads/"
}

function gen_version() {
  local dirty
  local last_tag
  local last_tag_commit
  local last_commit
  local short_last_commit
  local ver
  
  cd ${BUILD_DIR}

  last_commit="$(git rev-parse --verify HEAD)"    
  short_last_commit="$(git rev-parse --short HEAD)"
  last_tag="$(git describe --abbrev=0 --tags)"

  if git diff-index --quiet HEAD --; then
    dirty=""
  else
    dirty="-dirty"
  fi

  if [ "" = "${last_tag}" ]; then
    ver="${short_last_commit}"
  else
    last_tag_commit="$(git rev-list -n 1 ${last_tag})"
    if [ "${last_tag_commit}" = "${last_commit}" -a "" = "${dirty}" ]; then
      ver="${last_tag}"
    else
      ver="${short_last_commit}"
    fi
  fi

  ver+=${dirty}
  
  echo "${ver}"
}

function xpath_contains() {
  local x=${1}
  local y=${2}

  for p in ${x/:/ }; do
    if [ "${y}" = "${p}" ]; then
      return 0
    fi
  done
  return 1
}

function path_contains() {
  xpath_contains ${PATH} ${1}
}

function dyldlibpath_contains() {
  xpath_contains ${DYLD_LIBRARY_PATH} ${1}
}

function prefix_dyldlibpath_if_not_contained() {
  local x=${1}
  dyldlibpath_contains ${1}
  if [ $? -eq 0 ]; then
    return
  fi
  export DYLD_LIBRARY_PATH=${1}:${DYLD_LIBRARY_PATH}
}

function prefix_path_if_not_contained() {
  local x=${1}
  path_contains ${1}
  if [ $? -eq 0 ]; then
    return
  fi
  export PATH=${1}:${PATH}
}

function handle_hash_mismatch() {
  local FILETYPE=$(file "${1}")

  # Remove the mismatching file, unless we're explicitly keeping it.
  [ ${KEEP_ON_MISMATCH} ] || rm -f "${1}"

  # For convenience, copy the hash line to the clipboard, if desired.
  [ ${COPY_HASH_ON_MISMATCH} ] && (echo "CKSUM=sha256:${3}" | pbcopy)

  # And error out.
  E "File '${1}' does not match '${2}'.\nActual sha256 is '${3}'.\nFile is of type '${FILETYPE}'." 
}


function verify_sha256() {
  #local FILENAME="${1}"
  #local CKSUM="${2}"
  local CKSUM="$(shasum -a 256 -- "${1}" | cut -d' ' -f1)"
  test "${CKSUM}" = "${2}" \
    && D "File '${1}' matches '${2}'" \
    || handle_hash_mismatch "${1}" "${2}" "${CKSUM}" "sha256"
}

function verify_git() {
  #local FILENAME="${1}"
  #local CKSUM="${2}"
  # Verify the hash refers to a commit.
  #    http://stackoverflow.com/questions/18515488/how-to-check-if-the-commit-exists-in-a-git-repository-by-its-sha-1
  test "$( git -C "${1}" cat-file -t "${2}" 2>/dev/null )" = commit \
    || E "Repository '${1}' does not match '${2}'"
  # Then verify the hash is in the current branch.  (The branch may have newer commits.)
  #    http://stackoverflow.com/questions/4127967/validate-if-commit-exists
  test "$( git -C "${1}" rev-list HEAD.."${2}" | wc -l )" -eq 0 \
    || E "Repository '${1}' does not match '${2}'"
}

function verify_checksum() {
  #local FILENAME="${1}"
  #local CKSUM="${2}"
  test -e "${1}" || E "Missing: '${1}'"
  if [ -z "${2}" ]; then
    # Nag someone to get a checksum for this thing.
    I "No checksum: '${1}'"
    return 0
  fi
  # CKSUM is in the form of "format:data"
  # (We allow additional colons in data for future whatever, format:data0:data1:...)
  # Check the leading "format:" portion
  case "${2%%:*}" in
    "sha256")
      # Remove leading "sha256:", and invoke the correct function:
      verify_sha256 "${1}" "${2#*:}"
      ;;
    "git")
      # Remove leading "git:", and invoke the correct function:
      verify_git "${1}" "${2#*:}"
      ;;
    *)
      E "Unrecognized checksum format: ${2}"
      ;;
  esac
}

# XXX: @CF: use hash-checking for compressed archives
function fetch() {
  local P=${1}
  local URL=${2}
  local T=${3}
  local BRANCH=${4}
  local CKSUM=${5}
  local MVFROM=${6}

  I "fetching ${P} from ${URL}"

  if [ "git" = "${URL:0:3}" -o "" != "${BRANCH}" ]; then
    D "downloading to ${TMP_DIR}/${T}"
    if [ ! -d ${TMP_DIR}/${T} ]; then
      git clone ${URL} ${TMP_DIR}/${T} \
        ||  ( rm -Rf ${TMP_DIR}/${T}; E "failed to clone from ${URL}" )
    fi
    cd ${TMP_DIR}/${T} \
      && git reset \
      && git checkout . \
      && git checkout master \
      && git fetch \
      && git pull \
      && git ls-files --others --exclude-standard | xargs rm -Rf \
      ||  ( rm -Rf ${TMP_DIR}/${T}; E "failed to pull from ${URL}" )
    if [ "" != "${BRANCH}" ]; then
      git branch -D local-${BRANCH} &> /dev/null
      git checkout -b local-${BRANCH} ${BRANCH} \
        || ( rm -Rf ${TMP_DIR}/${T}; E "failed to checkout ${BRANCH}" )
    fi
    verify_checksum "${TMP_DIR}/${T}" "${CKSUM}"
  else
    if [ "" != "${SKIP_FETCH}" ]; then
      local Z=
      for zz in $EXTS; do
        D "checking for ${TMP_DIR}/${P}.${zz}"
        if [ -f ${TMP_DIR}/${P}.${zz} ]; then
          Z=${P}.${zz}
          D "already downloaded ${Z}"
          verify_checksum "${TMP_DIR}/${Z}" "${CKSUM}"
          return
        fi
      done
    fi
    cd ${TMP_DIR} \
    && curl -L --insecure -k -O ${URL} \
      || E "failed to download from ${URL}"
    verify_checksum "${URL##*/}" "${CKSUM}"
  fi
}

function unpack() {
  local P=${1}
  local URL=${2}
  local T=${3}
  local MVFROM="${4}"
  local NAME="${5}"

  if [ "" = "${T}" ]; then
    T=${P}
  fi

  if [ "" = "${NAME}" ]; then
    if [ "" = "${MVFROM}" ]; then
      NAME=${P} 
    else
      NAME=${MVFROM}
    fi
  fi

  if [ "git" = "${URL:0:3}" -o "" != "${BRANCH}" ]; then
    I "git repository has been refreshed"
  else
    local opts=
    local cmd=
    local Z=
    if [ 1 -eq 0 ]; then
      echo 
    elif [ -e ${TMP_DIR}/${NAME}.zip ]; then
      Z=${NAME}.zip
      cmd=unzip
    elif [ -e ${TMP_DIR}/${NAME}.tar.gz ]; then
      Z=${NAME}.tar.gz
      cmd=tar
      opts=xpzf
    elif [ -e ${TMP_DIR}/${NAME}.tgz ]; then
      Z=${NAME}.tgz
      cmd=tar
      opts=xpzf
    elif [ -e ${TMP_DIR}/${NAME}.tar.bz2 ]; then
      Z=${NAME}.tar.bz2
      cmd=tar
      opts=xpjf
    elif [ -e ${TMP_DIR}/${NAME}.tbz2 ]; then
      Z=${NAME}.tbz2
      cmd=tar
      opts=xpjf
    elif [ -e ${TMP_DIR}/${NAME}.tar.xz ]; then
      Z=${NAME}.tar.xz
      cmd=tar
      opts=xpJf
    fi
    
    I "Extracting ${Z} to ${T}"
    rm -Rf ${TMP_DIR}/${T}
    cd ${TMP_DIR} \
    && echo "${cmd} ${opts} ${Z}" \
    && ${cmd} ${opts} ${Z} \
      || E "failed to extract ${Z}"

  fi

  if [ z"${MVFROM}" != z"" ]; then
    mv "${TMP_DIR}/${MVFROM}" "${TMP_DIR}/${T}"
  fi
  
  local PATCHES="$(ls -1 ${BUILD_DIR}/patches/${P}-*.patch 2>/dev/null)"
  if [ "" != "${PATCHES}" ]; then
    
    if [ ! -d ${TMP_DIR}/${T}/.git ]; then
      cd ${TMP_DIR}/${T} \
      && git init \
      && git add . \
      && git commit -m 'initial commit' \
      || E "failed to initialize local git (to make patching easier)"
    fi
    
    for PP in $PATCHES; do
      if [ "${PP%".sh.patch"}" != "${PP}" ]; then
        # This ends with .sh.patch, so source it:
        I "applying script ${PP}"
        cd ${TMP_DIR}/${T} \
          && . ${PP} \
          || E "sh ${PP} failed"
      else
        I "applying patch ${PP}"
        cd ${TMP_DIR}/${T} \
          && git apply ${PP} \
          || E "git apply ${PP} failed"
      fi
    done
  fi
}

function build_and_install_cmake() {

  local P=${1}
  local URL=${2}
  local CKSUM=${3}
  local T=${4}
  local BRANCH=${5}
  local MVFROM=${6}

  if [ "" = "${T}" ]; then
    T=${P}
  fi

  if [ -f ${TMP_DIR}/.${P}.done ]; then
    I "already installed ${P}"    
  else 
    fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
    unpack ${P} ${URL} ${T} ${BRANCH} "${MVFROM}"
  
    rm -Rf ${TMP_DIR}/${T}-build \
    && mkdir ${TMP_DIR}/${T}-build \
    && cd ${TMP_DIR}/${T}-build \
    && cmake ${EXTRA_OPTS} \
    && ${MAKE} \
    && ${MAKE} install \
    || E "failed to build ${P}"
  
    I "finished building and installing ${P}"

    touch ${TMP_DIR}/.${P}.done
  
  fi
}


function build_and_install_meson() {

  local P=${1}
  local URL=${2}
  local CKSUM=${3}
  local T=${4}
  local BRANCH=${5}
  local PATHNAME=${6}

  if [ "" = "${T}" ]; then
    T=${P}
  fi

  if [ -f ${TMP_DIR}/.${P}.done ]; then
    I "already installed ${P}"    
  else 
    fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}" "${PATHNAME}"
    unpack ${P} ${URL} ${T} ${BRANCH} "${PATHNAME}"
  
    rm -Rf ${TMP_DIR}/${T}-build \
    && mkdir ${TMP_DIR}/${T}-build \
    && cd ${TMP_DIR}/${T} \
    && AR="/usr/bin/ar" meson --prefix="${INSTALL_DIR}/usr" --buildtype=plain ${TMP_DIR}/${T}-build ${EXTRA_OPTS} \
    && ninja -v -C ${TMP_DIR}/${T}-build  \
    && ninja -C ${TMP_DIR}/${T}-build install \
    || E "failed to build ${P}"
  
    I "finished building and installing ${P}"

    touch ${TMP_DIR}/.${P}.done
  
  fi
}


function build_and_install_waf() {

  local P=${1}
  local URL=${2}
  local CKSUM=${3}
  local T=${4}
  local BRANCH=${5}

  if [ "" = "${T}" ]; then
    T=${P}
  fi

  if [ -f ${TMP_DIR}/.${P}.done ]; then
    I "already installed ${P}"    
  else 
    fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
    unpack ${P} ${URL} ${T} ${BRANCH}
  
    rm -Rf ${TMP_DIR}/${T}-build \
    && mkdir ${TMP_DIR}/${T}-build \
    && cd ${TMP_DIR}/${T} \
    && ${PYTHON} ./waf configure --prefix="${INSTALL_DIR}" \
    && ${PYTHON} ./waf build \
    && ${PYTHON} ./waf install \
    || E "failed to build ${P}"
  
    I "finished building and installing ${P}"

    touch ${TMP_DIR}/.${P}.done
  
  fi
}


function build_and_install_setup_py() {

  local P=${1}
  local URL=${2}
  local CKSUM=${3}
  local T=${4}
  local BRANCH=${5}

  if [ "" = "${T}" ]; then
    T=${P}
  fi

  if [ -f ${TMP_DIR}/.${P}.done ]; then
    I "already installed ${P}"    
  else 
  
    fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
    unpack ${P} ${URL} ${T}
  
    if [ ! -d ${PYTHONPATH} ]; then
      mkdir -p ${PYTHONPATH} \
        || E "failed to mkdir -p ${PYTHONPATH}"
    fi
  
    I "Configuring and building in ${T}"
    cd ${TMP_DIR}/${T} \
      && \
        ${PYTHON} setup.py install --prefix=${INSTALL_DIR}/usr \
      || E "failed to configure and install ${P}"
  
    I "finished building and installing ${P}"
    
    touch ${TMP_DIR}/.${P}.done
    
  fi
}

function build_and_install_autotools() {

  local P=${1}
  local URL=${2}
  local CKSUM=${3}
  local T=${4}
  local BRANCH=${5}
  local CONFIGURE_CMD=${6}
  
  if [ "" = "${CONFIGURE_CMD}" ]; then
    CONFIGURE_CMD="./configure --prefix=${INSTALL_DIR}/usr"
  fi

  if [ "" = "${T}" ]; then
    T=${P}
  fi

  if [ -f ${TMP_DIR}/.${P}.done ]; then
    I "already installed ${P}"
  else 
  
    fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
    unpack ${P} ${URL} ${T}
  
    if [[ ( "" = "${SKIP_AUTORECONF}" && "" != "$(which autoreconf)"  ) || ! -f ${TMP_DIR}/${T}/configure ]]; then
      I "Running autoreconf in ${T}"
      cd ${TMP_DIR}/${T} \
        && autoreconf -if  \
        || E "autoreconf failed for ${P}"
    fi

    if [[ "" = "${SKIP_LIBTOOLIZE}" && "" != "$(which libtoolize)" ]]; then
      I "Running libtoolize in ${T}"
      cd ${TMP_DIR}/${T} \
        && libtoolize -if \
        || E "libtoolize failed for ${P}"
    fi

    I "Configuring and building in ${T}"
    cd ${TMP_DIR}/${T} \
      && I "${CONFIGURE_CMD} ${EXTRA_OPTS}" \
      && ${CONFIGURE_CMD} ${EXTRA_OPTS} \
      && ${MAKE} \
      && ${MAKE} install \
      || E "failed to configure, make, and install ${P}"
  
    I "finished building and installing ${P}"
    
    touch ${TMP_DIR}/.${P}.done
    
  fi
  
  unset SKIP_AUTORECONF
  unset SKIP_LIBTOOLIZE
}

function build_and_install_qmake() {

  local P=${1}
  local URL=${2}
  local CKSUM=${3}
  local T=${4}
  local BRANCH=${5}
  
  if [ "" = "${T}" ]; then
    T=${P}
  fi

  if [ -f ${TMP_DIR}/.${P}.done ]; then
    I "already installed ${P}"
  else 
  
    fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
    unpack ${P} ${URL} ${T} ${BRANCH}
  
    I "Configuring and building in ${T}"
    cd ${TMP_DIR}/${T} \
      && I "qmake ${EXTRA_OPTS}" \
      && qmake ${EXTRA_OPTS} \
      && ${MAKE} \
      && ${MAKE} install \
      || E "failed to make and install ${P}"
  
    I "finished building and installing ${P}"
    
    touch ${TMP_DIR}/.${P}.done
    
  fi
  
  unset SKIP_AUTORECONF
  unset SKIP_LIBTOOLIZE
}

#function create_icns_via_cairosvg() {
#  local input="${1}"
#  local output="${2}"
#  local T="$(dirname ${output})/iconbuilder.iconset"
#  
#  mkdir -p ${T} \
#  && cd ${T} \
#  && for i in 16 32 128 256 512; do
#    j=$((2*i)) \
#    && I creating icon_${i}x${i}.png \
#    && cairosvg ${input} -W ${i} -H ${i} -o ${T}/icon_${i}x${i}.png \
#    && I creating icon_${i}x${i}@2x.png \
#    && cairosvg ${input} -W ${j} -H ${j} -o ${T}/icon_${i}x${i}@2x.png \
#    || E failed to create ${i}x${i} or ${i}x${i}@2x icons; \
#  done \
#  && iconutil -c icns -o ${output} ${T} \
#  && I done creating ${output} \
#  || E failed to create ${output} from ${input}
#}

#function create_icns_via_rsvg() {
#  local input="${1}"
#  local output="${2}"
#  local T="$(dirname ${output})/iconbuilder.iconset"
#  
#  mkdir -p ${T} \
#  && cd ${T} \
#  && for i in 16 32 128 256 512; do
#    j=$((2*i)) \
#    && I creating icon_${i}x${i}.png \
#    && rsvg-convert ${input} -W ${i} -H ${i} -o ${T}/icon_${i}x${i}.png \
#    && I creating icon_${i}x${i}@2x.png \
#    && rsvg-convert ${input} -W ${j} -H ${j} -o ${T}/icon_${i}x${i}@2x.png \
#    || E failed to create ${i}x${i} or ${i}x${i}@2x icons; \
#  done \
#  && iconutil -c icns -o ${output} ${T} \
#  && I done creating ${output} \
#  || E failed to create ${output} from ${input}
#}

#
# main
#

I "BUILD_DIR = '${BUILD_DIR}'"
I "INSTALL_DIR = '${INSTALL_DIR}'"

check_prerequisites

#rm -Rf ${TMP_DIR}

mkdir -p ${BUILD_DIR} ${TMP_DIR} ${INSTALL_DIR}

cd ${TMP_DIR}

prefix_path_if_not_contained ${INSTALL_DIR}/usr/bin

#prefix_dyldlibpath_if_not_contained ${INSTALL_DIR}/usr/lib

CPPFLAGS="-I${INSTALL_DIR}/usr/include -I/opt/X11/include"
#CPPFLAGS="${CPPFLAGS} -I${INSTALL_DIR}/usr/include/gdk-pixbuf-2.0 -I${INSTALL_DIR}/usr/include/cairo -I${INSTALL_DIR}/usr/include/pango-1.0 -I${INSTALL_DIR}/usr/include/atk-1.0"
export CPPFLAGS
export CC="clang -mmacosx-version-min=10.7"
export CXX="clang++ -mmacosx-version-min=10.7 -stdlib=libc++"
export LDFLAGS="-Wl,-undefined,error -L${INSTALL_DIR}/usr/lib -L/opt/X11/lib -Wl,-rpath,${INSTALL_DIR}/usr/lib -Wl,-rpath,/opt/X11/lib"
export PKG_CONFIG_PATH="${INSTALL_DIR}/usr/lib/pkgconfig:/opt/X11/lib/pkgconfig"

unset DYLD_LIBRARY_PATH

# install wrappers for ar and ranlib, which prevent autotools from working
mkdir -p ${INSTALL_DIR}/usr/bin \
 && cp ${BUILD_DIR}/scripts/ar-wrapper.sh ${INSTALL_DIR}/usr/bin/ar \
  && chmod +x ${INSTALL_DIR}/usr/bin/ar \
  && \
cp ${BUILD_DIR}/scripts/ranlib-wrapper.sh ${INSTALL_DIR}/usr/bin/ranlib \
  && chmod +x ${INSTALL_DIR}/usr/bin/ranlib \
  || E "failed to install ar and ranlib wrappers"

[[ $(which ar) = ${INSTALL_DIR}/usr/bin/ar ]] \
  || E "sanity check failed. ar-wrapper is not in PATH"


# Create a symlink that ensures we only ever build with the install python3;
# and put python3 where things expect it to be.
ln -sf ${PYTHON} ${INSTALL_DIR}/usr/bin/python
ln -sf ${PYTHON} ${INSTALL_DIR}/usr/bin/python3

#
# Install autoconf
# 

P=autoconf-2.69
URL=http://ftp.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz
CKSUM=sha256:954bd69b391edc12d6a4a51a2dd1476543da5c6bbf05a95b59dc0dd6fd4c2969

  SKIP_AUTORECONF=yes \
  SKIP_LIBTOOLIZE=yes \
  build_and_install_autotools \
    ${P} \
    ${URL} \
    ${CKSUM}

#
# Install automake
# 

P=automake-1.16
URL=http://ftp.gnu.org/gnu/automake/${P}.tar.gz
CKSUM=sha256:80da43bb5665596ee389e6d8b64b4f122ea4b92a685b1dbd813cd1f0e0c2d83f

SKIP_AUTORECONF=yes \
SKIP_LIBTOOLIZE=yes \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install libtool
# 

P=libtool-2.4.6
URL="http://gnu.spinellicreations.com/libtool/${P}.tar.xz"
CKSUM=sha256:7c87a8c2c8c0fc9cd5019e402bed4292462d00a718a7cd5f11218153bf28b26f

SKIP_AUTORECONF=yes \
SKIP_LIBTOOLIZE=yes \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM} \
  "" \
  "" \
  "./configure --prefix=${INSTALL_DIR}/usr"


#
# Install sed
# 

P=sed-4.7
URL=http://ftp.gnu.org/pub/gnu/sed/${P}.tar.xz
CKSUM=sha256:2885768cd0a29ff8d58a6280a270ff161f6a3deb5690b2be6c49f46d4c67bd6a

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}


#
# Install gettext
# 

P=gettext-0.20.1
URL=http://ftp.gnu.org/pub/gnu/gettext/${P}.tar.xz
CKSUM=sha256:53f02fbbec9e798b0faaf7c73272f83608e835c6288dd58be6c9bb54624a3800

build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install xz-utils
# 

P=xz-5.2.4
URL=https://tukaani.org/xz/${P}.tar.bz2
CKSUM=sha256:3313fd2a95f43d88e44264e6b015e7d03053e681860b0d5d3f9baca79c57b7bf

build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install GNU tar
# 

P=tar-1.29
URL=http://ftp.gnu.org/gnu/tar/tar-1.29.tar.bz2
CKSUM=sha256:236b11190c0a3a6885bdb8d61424f2b36a5872869aa3f7f695dea4b4843ae2f2

EXTRA_OPTS="--with-lzma=`which xz`"
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install pkg-config
# 

P=pkg-config-0.29.2
URL=https://pkg-config.freedesktop.org/releases/${P}.tar.gz
CKSUM=sha256:6fc69c01688c9458a57eb9a1664c9aba372ccda420a02bf4429fe610e7e7d591

EXTRA_OPTS="--with-internal-glib" \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}


#
# Install CMake
#

P=cmake-3.7.2
URL=http://cmake.org/files/v3.7/cmake-3.7.2.tar.gz
CKSUM=sha256:dc1246c4e6d168ea4d6e042cfba577c1acd65feea27e56f5ff37df920c30cae0
T=${P}

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

 fetch "${P}" "${URL}" "" "" "${CKSUM}"
 unpack ${P} ${URL}

 cd ${TMP_DIR}/${T} \
   && ./bootstrap \
   && ${MAKE} \
   && \
     ./bin/cmake \
       -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr \
       -P cmake_install.cmake \
   || E "failed to build cmake"

 touch ${TMP_DIR}/.${P}.done

fi

#
# Install Boost
# 

P=boost_1_71_0
URL=https://mirror.csclub.uwaterloo.ca/gentoo-distfiles/distfiles/${P}.tar.bz2
CKSUM=sha256:d73a8da01e8bf8c7eda40b4c84915071a8c8a0df4a6734537ddde4a8580524ee
T=${P}

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

  fetch "${P}" "${URL}" "" "" "${CKSUM}"
  unpack ${P} ${URL}

  cd ${TMP_DIR}/${T} \
    && sh bootstrap.sh --with-python-version=${PYTHON_VERSION} \
    && ./b2 \
      -j $(ncpus)                                  \
      -sLZMA_LIBRARY_PATH="${INSTALL_DIR}/usr/lib" \
      -sLZMA_INCLUDE="${INSTALL_DIR}/usr/include"  \
      stage \
    && rsync -avr stage/lib/ ${INSTALL_DIR}/usr/lib/ \
    && rsync -avr boost ${INSTALL_DIR}/usr/include \
    || E "building boost failed"
  
  touch ${TMP_DIR}/.${P}.done

fi

#
# Install PCRE
# 

  P=pcre-8.40
  URL=http://pilotfiber.dl.sourceforge.net/project/pcre/pcre/8.40/pcre-8.40.tar.gz
  CKSUM=sha256:1d75ce90ea3f81ee080cdc04e68c9c25a9fb984861a0618be7bbf676b18eda3e

  EXTRA_OPTS="--enable-utf" \
  build_and_install_autotools \
    ${P} \
    ${URL} \
    ${CKSUM}

#
# Install Swig
# 

P=swig-3.0.12
URL=http://pilotfiber.dl.sourceforge.net/project/swig/swig/${P}/${P}.tar.gz
CKSUM=sha256:7cf9f447ae7ed1c51722efc45e7f14418d15d7a1e143ac9f09a668999f4fc94d

SKIP_AUTORECONF=yes \
SKIP_LIBTOOLIZE=yes \
build_and_install_autotools \
    ${P} \
    ${URL} \
    ${CKSUM}

#
# Install ffi
# 

P=libffi-3.2.1
URL=ftp://sourceware.org/pub/libffi/libffi-3.2.1.tar.gz
CKSUM=sha256:d06ebb8e1d9a22d19e38d63fdb83954253f39bedc5d46232a05645685722ca37

build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}


#
# Install glib
# 

unset EXTRA_OPTS

V=2.62
VV=${V}.0
P=glib-2.62.0
URL="http://gensho.acc.umu.se/pub/gnome/sources/glib/${V}/${P}.tar.xz"
CKSUM=sha256:6c257205a0a343b662c9961a58bb4ba1f1e31c82f5c6b909ec741194abc3da10
    
# Build a dynamic version..
build_and_install_meson \
  ${P} \
  ${URL} \
  ${CKSUM}

# ... and a static one.
P=glib-static-${VV}
EXTRA_OPTS="--default-library static"
build_and_install_meson \
  ${P} \
  ${URL} \
  ${CKSUM} \
  "" \
  "" \
  "glib-${VV}"

#
# Install cppunit
# 

  P=cppunit-1.12.1
  URL='http://iweb.dl.sourceforge.net/project/cppunit/cppunit/1.12.1/cppunit-1.12.1.tar.gz'
  CKSUM=sha256:ac28a04c8e6c9217d910b0ae7122832d28d9917fa668bcc9e0b8b09acb4ea44a

  build_and_install_autotools \
    ${P} \
    ${URL} \
    ${CKSUM}

#
# Install mako
# 

P=Mako-1.0.3
URL=https://mirror.csclub.uwaterloo.ca/gentoo-distfiles/distfiles/Mako-1.0.3.tar.gz
CKSUM=sha256:7644bc0ee35965d2e146dde31827b8982ed70a58281085fac42869a09764d38c

LDFLAGS="${LDFLAGS} $(${PYTHON_CONFIG} --ldflags)" \
build_and_install_setup_py \
   ${P} \
   ${URL} \
   ${CKSUM}

#
# Install bison
# 

    P=bison-3.4.2
    URL="http://ftp.gnu.org/gnu/bison/${P}.tar.xz"
    CKSUM=sha256:27d05534699735dc69e86add5b808d6cb35900ad3fd63fa82e3eb644336abfa0

  SKIP_AUTORECONF=yes \
  build_and_install_autotools \
   ${P} \
   ${URL} \
   ${CKSUM}

#
# Install OpenSSL
# 
    P=openssl-1.1.0d
    URL='https://www.openssl.org/source/openssl-1.1.0d.tar.gz'
    CKSUM=sha256:7d5ebb9e89756545c156ff9c13cf2aa6214193b010a468a3bc789c3c28fe60df

  SKIP_AUTORECONF=yes \
  SKIP_LIBTOOLIZE=yes \
  EXTRA_OPTS="darwin64-x86_64-cc" \
  build_and_install_autotools \
    ${P} \
    ${URL} \
    ${CKSUM}

unset EXTRA_OPTS

#
# Install thrift
# 
#
#  V=0.12.0
#  P=thrift-${V}
#  URL="http://apache.mirror.gtcomm.net/thrift/${V}/${P}.tar.gz"
#  CKSUM=sha256:c336099532b765a6815173f62df0ed897528a9d551837d627c1f87fadad90428
#
#  SKIP_AUTORECONF="true" \
#  PY_PREFIX="${INSTALL_DIR}/usr" \
#  CXXFLAGS="${CPPFLAGS}" \
#  EXTRA_OPTS="--without-perl --without-php --without-qt4 --without-qt5" \
#  build_and_install_autotools \
#    ${P} \
#    ${URL} \
#    ${CKSUM}
#

#
# Install ninja
#


V=1.9.0
P=ninja-${V}
URL="https://github.com/ninja-build/ninja/archive/v${V}/${P}.tar.gz"
CKSUM=sha256:5d7ec75828f8d3fd1a0c2f31b5b0cea780cdfe1031359228c428c1a48bfcd5b9

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

 fetch "${P}" "${URL}" "" "" "${CKSUM}"
 unpack ${P} ${URL}

 # Ninja only produces a single binary; and doesn't really support "installing".
 # We'll just copy it to /usr/bin.
 cd ${TMP_DIR}/${P} \
   && ./configure.py --bootstrap \
   && cp ninja ${INSTALL_DIR}/usr/bin/ \
   || E "failed to build ${P}"

 touch ${TMP_DIR}/.${P}.done

fi


#
# Install meson
# 

V=0.51.2
P=meson-${V}
URL="https://github.com/mesonbuild/meson/releases/download/${V}/${P}.tar.gz"
CKSUM=sha256:23688f0fc90be623d98e80e1defeea92bbb7103bf9336a5f5b9865d36e892d76

build_and_install_setup_py \
   ${P} \
   ${URL} \
   ${CKSUM}


#
# Install orc
# 

    P=orc-0.4.30
    URL="https://gstreamer.freedesktop.org/src/orc/${P}.tar.xz"
    CKSUM=sha256:ba41b92146a5691cd102eb79c026757d39e9d3b81a65810d2946a1786a1c4972

  build_and_install_meson \
    ${P} \
    ${URL} \
    ${CKSUM}

#
# Install Cheetah
# 

    V=3.2.4
    P=cheetah3-${V}
    URL="https://github.com/CheetahTemplate3/cheetah3/archive/${V}/${P}.tar.gz"
    CKSUM=sha256:32780a2729b7acf1ab4df9b9325b33e4a1aaf7dcae8c2c66e6e83c70499db863

  LDFLAGS="${LDFLAGS} $(${PYTHON_CONFIG} --ldflags)" \
  build_and_install_setup_py \
    ${P} \
    ${URL} \
    ${CKSUM} \
  && ln -sf ${PYTHONPATH}/${P}-py3.7.egg ${PYTHONPATH}/Cheetah.egg


#
# Install Cython
# 

  V=0.29.13
  P=cython-${V}
  URL="https://github.com/cython/cython/archive/${V}/${P}.tar.gz"
  CKSUM=sha256:af71d040fa9fa1af0ea2b7a481193776989ae93ae828eb018416cac771aef07f

  LDFLAGS="${LDFLAGS} $(${PYTHON_CONFIG} --ldflags)" \
  build_and_install_setup_py \
    ${P} \
    ${URL} \
    ${CKSUM} \


#
# Install lxml
# 

    P=lxml-4.4.1
    T="${P}"
    URL="https://github.com/lxml/lxml/archive/${P}.tar.gz"
    CKSUM=sha256:a735879b25331bb0c8c115e8aff6250469241fbce98bba192142cd767ff23408

LDFLAGS="${LDFLAGS} $(python-config --ldflags)" \
  build_and_install_setup_py \
    ${P} \
    ${URL} \
    ${CKSUM} \
    "lxml-${P}"

#
# Install libtiff
#

P=tiff-4.0.10
URL="https://download.osgeo.org/libtiff/${P}.tar.gz"
CKSUM=sha256:2c52d11ccaf767457db0c46795d9c7d1a8d8f76f68b0b800a3dfe45786b996e4

  build_and_install_autotools \
    ${P} \
    ${URL} \
    ${CKSUM}

unset SKIP_AUTORECONF
unset SKIP_LIBTOOLIZE

#
# Install png
# 

P=libpng-1.6.37
URL="https://mirror.csclub.uwaterloo.ca/gentoo-distfiles/distfiles/${P}.tar.xz"
CKSUM=sha256:505e70834d35383537b6491e7ae8641f1a4bed1876dbfe361201fc80868d88ca

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}


#
# Install jpeg
#

P=jpegsrc.v6b
URL=http://mirror.csclub.uwaterloo.ca/slackware/slackware-8.1/source/ap/ghostscript/jpegsrc.v6b.tar.gz
CKSUM=sha256:75c3ec241e9996504fe02a9ed4d12f16b74ade713972f3db9e65ce95cd27e35d
T=jpeg-6b

  SKIP_AUTORECONF=yes \
  SKIP_LIBTOOLIZE=yes \
  EXTRA_OPTS="--mandir=${INSTALL_DIR}/usr/share/man" \
  build_and_install_autotools \
    ${P} \
    ${URL} \
    ${CKSUM} \
    ${T}


#
# Install pixman
# 

P='pixman-0.38.4'
URL="https://www.cairographics.org/releases/${P}.tar.gz"
CKSUM=sha256:da66d6fd6e40aee70f7bd02e4f8f76fc3f006ec879d346bae6a723025cfbdde7

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install freetype
# 

P=freetype-2.10.1
URL="http://mirror.csclub.uwaterloo.ca/nongnu//freetype/${P}.tar.gz"
CKSUM=sha256:3a60d391fd579440561bf0e7f31af2222bc610ad6ce4d9d7bd2165bca8669110

SKIP_AUTORECONF=yes \
SKIP_LIBTOOLIZE=yes \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}


#
# Install harfbuzz
# 

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
P=harfbuzz-2.6.1
URL="https://www.freedesktop.org/software/harfbuzz/release/${P}.tar.xz"
CKSUM=sha256:c651fb3faaa338aeb280726837c2384064cdc17ef40539228d88a1260960844f

EXTRA_OPTS="--with-coretext=yes " \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install fontconfig
# 

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
P=fontconfig-2.13.1
URL="https://www.freedesktop.org/software/fontconfig/release/${P}.tar.gz"
CKSUM=sha256:9f0d852b39d75fc655f9f53850eb32555394f36104a044bb2b2fc9e66dbbfa7f

build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install cairo
# 

P=zlib-1.2.11
URL="https://www.zlib.net/${P}.tar.xz"
CKSUM=sha256:4ff941449631ace0d4d203e3483be9dbc9da454084111f97ea0a2114e19bf066

EXTRA_OPTS="" \
SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}


#
# Install cairo
# 

P=cairo-1.16.0
URL="https://www.cairographics.org/releases/${P}.tar.xz"
CKSUM=sha256:5e7b29b3f113ef870d1e3ecf8adf21f923396401604bda16d44be45e66052331

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install pycairo
# 

V=1.18.1
P=pycairo-${V}
URL="https://github.com/pygobject/pycairo/releases/download/v${V}/${P}.tar.gz"
CKSUM=sha256:70172e58b6bad7572a3518c26729b074acdde15e6fee6cbab6d3528ad552b786

build_and_install_meson \
  ${P} \
  ${URL} \
  ${CKSUM}


#
# Install pygobject-introspection
# 

V=1.62
VV=1.62.0
P=gobject-introspection-${VV}
URL="http://ftp.gnome.org/pub/gnome/sources/gobject-introspection/${V}/gobject-introspection-${VV}.tar.xz"
CKSUM=sha256:b1ee7ed257fdbc008702bdff0ff3e78a660e7e602efa8f211dc89b9d1e7d90a2

build_and_install_meson \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install pygobject
# 

V=3.34.0
P=pygobject-${V}
URL="https://github.com/GNOME/pygobject/archive/${V}/pygobject-${V}.tar.gz"
CKSUM=sha256:fe05538639311fe3105d6afb0d7dfa6dbd273338e5dea61354c190604b85cbca

build_and_install_meson \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install gdk-pixbuf
# 

V=2.36
VV=${V}.6
P=gdk-pixbuf-${VV}
URL="http://muug.ca/mirror/gnome/sources/gdk-pixbuf/${V}/${P}.tar.xz"
CKSUM=sha256:455eb90c09ed1b71f95f3ebfe1c904c206727e0eeb34fc94e5aaf944663a820c

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
EXTRA_OPTS="--without-libtiff --without-libjpeg" \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

unset EXTRA_OPTS

#
# Install libatk
# 

V=2.34
VV=${V}.1
P=atk-${VV}
URL="http://ftp.gnome.org/pub/gnome/sources/atk/${V}/${P}.tar.xz"
CKSUM=sha256:d4f0e3b3d21265fcf2bc371e117da51c42ede1a71f6db1c834e6976bb20997cb

build_and_install_meson \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install pango
# 

V=1.44
VV=${V}.6
P=pango-${VV}
URL="http://ftp.gnome.org/pub/GNOME/sources/pango/${V}/${P}.tar.xz"
CKSUM=sha256:3e1e41ba838737e200611ff001e3b304c2ca4cdbba63d200a20db0b0ddc0f86c

build_and_install_meson \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install gtk+
# 
V=2.24
VV=${V}.32
P=gtk+-${VV}
URL="http://gemmei.acc.umu.se/pub/gnome/sources/gtk+/${V}/${P}.tar.xz"
CKSUM=sha256:b6c8a93ddda5eabe3bfee1eb39636c9a03d2a56c7b62828b359bf197943c582e

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

##
## Install pygtk
## 
#
#V=2.24
#VV=${V}.0
#P=pygtk-${VV}
#URL="http://ftp.gnome.org/pub/GNOME/sources/pygtk/${V}/${P}.tar.gz"
#CKSUM=sha256:6e3e54fa6e65a69ac60bd58cb2e60a57f3346ac52efe995f3d10b6c38c972fd8
#
#SKIP_AUTORECONF=true \
#SKIP_LIBTOOLIZE=true \
#build_and_install_autotools \
#    ${P} \
#    ${URL} \
#    ${CKSUM}

  #ln -sf ${INSTALL_DIR}/usr/lib/${PYTHON}/site-packages/{py,}gtk.py

#
# Install numpy
# 

V=1.17.2
P=numpy-${V}
URL="https://github.com/numpy/numpy/releases/download/v${V}/${P}.tar.gz"
CKSUM=sha256:81a4f748dcfa80a7071ad8f3d9f8edb9f8bc1f0a9bdd19bfd44fd42c02bd286c

build_and_install_setup_py \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install fftw
# 

P=fftw-3.3.8
URL="http://www.fftw.org/${P}.tar.gz"
CKSUM=sha256:6113262f6e92c5bd474f2875fa1b01054c4ad5040f6b0da7c03c98821d9ae303

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
EXTRA_OPTS="--enable-single --enable-sse --enable-sse2 --enable-avx --enable-avx2 --enable-avx-128-fma --enable-generic-simd128 --enable-generic-simd256 --enable-threads" \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install f2c
#

P=f2c
URL=http://github.com/barak/f2c.git
CKSUM=git:fa8ccce5c4ab11d08b875379c5f0629098261f32
T=${P}
BRANCH=master

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}
  
  cd ${TMP_DIR}/${T}/src \
  && rm -f Makefile \
  && cp makefile.u Makefile \
  && I building f2c \
  && ${MAKE} \
  && I installing f2c \
  && cp f2c ${INSTALL_DIR}/usr/bin \
  && cp f2c.h ${INSTALL_DIR}/usr/include \
  && sed -e 's,^\([[:space:]]*CFLAGS[[:space:]]*=\).*$,\1"-I'"${INSTALL_DIR}"'/usr/include",' < "${BUILD_DIR}/scripts/gfortran-wrapper.sh" > "${INSTALL_DIR}/usr/bin/gfortran" \
  && chmod +x ${INSTALL_DIR}/usr/bin/gfortran \
    || E "failed to build and install f2c"  

  touch ${TMP_DIR}/.${P}.done
fi

#
# Install libf2c
#

P=libf2c-20130927
URL=http://mirror.csclub.uwaterloo.ca/gentoo-distfiles/distfiles/libf2c-20130927.zip
CKSUM=sha256:5dff29c58b428fa00cd36b1220e2d71b9882a658fdec1aa094fb7e6e482d6765
T=${P}
BRANCH=""

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  
  rm -Rf ${TMP_DIR}/${T} \
  && mkdir -p ${TMP_DIR}/${T} \
  && cd ${TMP_DIR}/${T} \
  && unzip ${TMP_DIR}/${P}.zip \
  || E "failed to extract ${P}.zip"
  
  cd ${TMP_DIR}/${T}/ \
  && rm -f Makefile \
  && cp makefile.u Makefile \
  && I building ${P} \
  && ${MAKE} \
  && I installing ${P} \
  && cp libf2c.a ${INSTALL_DIR}/usr/lib \
  || E "failed to build and install libf2c"

#  && mkdir -p foo \
#  && cd foo \
#  && ar x ../libf2c.a \
#  && rm main.o getarg_.o iargc_.o \
#  && \
#  ${CC} \
#    ${LDFLAGS} \
#    -dynamiclib \
#    -install_name ${INSTALL_DIR}/usr/lib/libf2c.dylib \
#    -o ../libf2c.dylib \
#    *.o \
#  && cd .. \

  touch ${TMP_DIR}/.${P}.done
fi

#
# Install blas
#

P=blas-3.7.0
URL=http://www.netlib.org/blas/blas-3.7.0.tgz
CKSUM=sha256:55415f901bfc9afc19d7bd7cb246a559a748fc737353125fcce4c40c3dee1d86
T=BLAS-3.7.0
BRANCH=""

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}
  
  cd ${TMP_DIR}/${T}/ \
  && I building ${P} \
  && \
    for i in *.f; do \
      j=${i/.f/.c} \
      && k=${j/.c/.o} \
      && I "f2c ${i} > ${j}" \
      && f2c ${i} > ${j} 2>/dev/null \
      && I "[CC] ${k}" \
      && \
        ${CC} \
          -I${INSTALL_DIR}/usr/include \
          -c ${j} \
          -o ${k} \
      || E "build of ${P} failed"; \
    done \
  && I creating libblas.a \
  && /usr/bin/libtool -static -o libblas.a *.o \
  && cp libblas.a ${INSTALL_DIR}/usr/lib/ \
  || E "failed to build and install libblas"  

#  && I creating libblas.dylib \
#  && \
#    ${CC} \
#      ${LDFLAGS} \
#      -dynamiclib \
#      -install_name ${INSTALL_DIR}/usr/lib/libblas.dylib \
#      -o libblas.dylib \
#      *.o \
#      -lf2c \
  
  touch ${TMP_DIR}/.${P}.done
fi

#
# Install cblas
# 
# XXX: @CF: requires either f2c or gfortran, both of which I don't care for right now
  P=cblas
  URL='http://www.netlib.org/blas/blast-forum/cblas.tgz'
  CKSUM=sha256:0f6354fd67fabd909baf57ced2ef84e962db58fae126e4f41b21dd4fec60a2a3
  T=CBLAS
  BRANCH=""

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}

  cd ${TMP_DIR}/${T}/src \
  && cd ${TMP_DIR}/${T}/src \
  && I compiling.. \
  && ${MAKE} CFLAGS="${CPPFLAGS} -DADD_" all \
  && I building static library \
  && mkdir -p ${TMP_DIR}/${T}/libcblas \
  && cd ${TMP_DIR}/${T}/libcblas \
  && ar x ${TMP_DIR}/${T}/lib/cblas_LINUX.a \
  && /usr/bin/libtool -static -o ../libcblas.a *.o \
  && cd ${TMP_DIR}/${T} \
  && I installing ${P} to ${INSTALL_DIR}/usr/lib \
  && cp ${TMP_DIR}/${T}/libcblas.* ${INSTALL_DIR}/usr/lib \
  && cp ${TMP_DIR}/${T}/include/*.h ${INSTALL_DIR}/usr/include \
  || E failed to make cblas

#  && I building dynamic library \
#  && cd ${TMP_DIR}/${T}/lib/ \
#  && mkdir foo \
#  && cd foo \
#  && ar x ../*.a \
#  && ${CC} \
#    ${LDFLAGS} \
#    -dynamiclib \
#    -install_name ${INSTALL_DIR}/usr/lib/libcblas.dylib \
#    -o ${TMP_DIR}/${T}/lib/libcblas.dylib \
#    *.o \
#    -lf2c \
#    -lblas \


#  && \
#  for i in *.f; do \
#    j=${i/.f/.c} \
#    && I converting ${i} to ${j} using f2c \
#    && f2c ${i} | tee ${j} \
#    && mv ${i}{,_ignore} \
#    || E f2c ${i} failed; \
#  done \
#  && I done converting .f to .c \

  touch ${TMP_DIR}/.${P}.done
fi

#
# Install gnu scientific library
# 
# XXX: @CF: required by gr-wavelet, depends on cblas

P=gsl-2.6
URL="http://ftp.wayne.edu/gnu/gsl/${P}.tar.gz"
CKSUM=sha256:b782339fc7a38fe17689cb39966c4d821236c28018b6593ddb6fd59ee40786a8

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
LDFLAGS="${LDFLAGS} -lcblas -lblas -lf2c" \
EXTRA_OPTS="" \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install libusb
# 

V=1.0.23
P=libusb-${V}
URL="https://github.com/libusb/libusb/releases/download/v${V}/${P}.tar.bz2"
CKSUM=sha256:db11c06e958a82dac52cf3c65cb4dd2c3f339c8a988665110e0d24d19312ad8d

SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install uhd
#

V=3.14.1.1
P=uhd-${V}
URL="https://github.com/EttusResearch/uhd/archive/v${V}/${P}.tar.gz"
CKSUM=sha256:8cbcb22d12374ceb2859689b1d68d9a5fa6bd5bd82407f66952863d5547d27d0
BRANCH=master

EXTRA_OPTS="-DENABLE_E300=ON -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr ${TMP_DIR}/${P}/host" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# install SDL
#

EXTRA_OPTS=""

P=SDL-1.2.15
URL=https://www.libsdl.org/release/SDL-1.2.15.tar.gz
CKSUM=sha256:d6d316a793e5e348155f0dd93b979798933fb98aa1edebcc108829d6474aad00
T=${P}

LDFLAGS="${LDFLAGS} -framework CoreFoundation -framework CoreAudio -framework CoreServices -L/usr/X11R6/lib -lX11" \
SKIP_AUTORECONF="yes" \
SKIP_LIBTOOLIZE="yes" \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T}

#
# Install libzmq
#

  P=libzmq
  URL=git://github.com/zeromq/libzmq.git
  CKSUM=git:d17581929cceceda02b4eb8abb054f996865c7a6
  T=${P}

  EXTRA_OPTS="-DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr ${TMP_DIR}/${T}" \
  build_and_install_cmake \
    ${P} \
    ${URL} \
    ${CKSUM}

#
# Install cppzmq
#

  P=cppzmq
  URL=git://github.com/zeromq/cppzmq.git
  CKSUM=git:178a910ae1abaad59467ee38884289b8a29c5710
  T=${P}
  BRANCH=v4.2.1

  EXTRA_OPTS="-DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr ${TMP_DIR}/${T}" \
  build_and_install_cmake \
    ${P} \
    ${URL} \
    ${CKSUM} \
    ${T} \
    ${BRANCH}


#
# Get wx widgets
#

#V=3.1.2
#P=wxWidgets-${V}
#URL="https://github.com/wxWidgets/wxWidgets/releases/download/v${V}/${P}.tar.bz2"
#CKSUM=sha256:4cb8d23d70f9261debf7d6cfeca667fc0a7d2b6565adb8f1c484f9b674f1f27a
#
#SKIP_AUTORECONF=yes \
#SKIP_LIBTOOLIZE=yes \
#EXTRA_OPTS="--with-gtk --enable-utf8only" \
#build_and_install_autotools \
#  ${P} \
#  ${URL} \
#  ${CKSUM}
#
##
## install wxpython
##
#
#  P=wxPython-src-3.0.2.0
#  URL=http://svwh.dl.sourceforge.net/project/wxpython/wxPython/3.0.2.0/wxPython-src-3.0.2.0.tar.bz2
#  CKSUM=sha256:d54129e5fbea4fb8091c87b2980760b72c22a386cb3b9dd2eebc928ef5e8df61
#  T=${P}
#  BRANCH=""
#
#  if [ -f ${TMP_DIR}/.${P}.done ]; then
#    I "already installed ${P}"    
#  else 
#
#  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
#  unpack ${P} ${URL} ${T}
#
#  _extra_cflags="$(pkg-config --cflags gtk+-2.0) $(pkg-config --cflags libgdk-x11) $(pkg-config --cflags x11)"
#  _extra_libs="$(pkg-config --libs gtk+-2.0) $(pkg-config --libs gdk-x11-2.0) $(pkg-config --libs x11)"
#
#  D "Configuring and building in ${T}"
#  cd ${TMP_DIR}/${T}/wxPython \
#    && \
#      CC=${CXX} \
#      CFLAGS="${CPPFLAGS} ${_extra_cflags} ${CFLAGS}" \
#      CXXFLAGS="${CPPFLAGS} ${_extra_cflags} ${CXXFLAGS}" \
#      LDFLAGS="${LDFLAGS} ${_extra_libs}" \
#      ${PYTHON} setup.py WXPORT=gtk2 ARCH=x86_64 build \
#    && \
#      CC=${CXX} \
#      CFLAGS="${CPPFLAGS} ${_extra_cflags} ${CFLAGS}" \
#      CXXFLAGS="${CPPFLAGS} ${_extra_cflags} ${CXXFLAGS}" \
#      LDFLAGS="${LDFLAGS} ${_extra_libs}" \
#      ${PYTHON} setup.py WXPORT=gtk2 ARCH=x86_64 install \
#        --prefix="${INSTALL_DIR}/usr" \
#    && D "copying wx.pth to ${PYTHONPATH}/wx.pth" \
#    && cp \
#       ${TMP_DIR}/${T}/wxPython/src/wx.pth \
#       ${PYTHONPATH} \
#    || E "failed to build and install ${P}"
#
#  I "finished building and installing ${P}"
#  
#  touch ${TMP_DIR}/.${P}.done
#
#fi

#
# Install rtl-sdr
#

V=0.6.0
P=rtl-sdr-"${V}"
URL="https://github.com/osmocom/rtl-sdr/archive/${V}/${P}.tar.gz"
CKSUM=sha256:ee10a76fe0c6601102367d4cdf5c26271e9442d0491aa8df27e5a9bf639cff7c

EXTRA_OPTS="" \
LDFLAGS="${LDFLAGS} $(${PYTHON_CONFIG} --ldflags)" \
SKIP_AUTORECONF=true \
SKIP_LIBTOOLIZE=true \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM}

#
# Install QT
#

V=5.13
VV=${V}.1
P=qt-everywhere-src-${VV}
URL=https://download.qt.io/archive/qt/${V}/${VV}/single/${P}.tar.xz
URL="https://download.qt.io/official_releases/qt/${V}/${VV}/single/${P}.tar.xz"
CKSUM=sha256:adf00266dc38352a166a9739f1a24a1e36f1be9c04bf72e16e142a256436974e
T=${P}
BRANCH=""

if [ -f ${TMP_DIR}/.${P}.done ]; then
    I "already installed ${P}"
else
  INSTALL_QGL="yes"
  rm -Rf ${INSTALL_DIR}/usr/lib/libQt*
  rm -Rf ${INSTALL_DIR}/usr/include/Qt*

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}
  
  I configuring ${P} \
  && cd ${TMP_DIR}/${T} \
  && export OPENSOURCE_CXXFLAGS="-D__USE_WS_X11__" \
  && sh configure                                              \
    -v                                                         \
    -confirm-license                                           \
    -continue                                                  \
    -release                                                   \
    -prefix          ${INSTALL_DIR}/usr                                 \
    -docdir          ${INSTALL_DIR}/usr/share/doc/${name}               \
    -examplesdir     ${INSTALL_DIR}/usr/share/${name}/examples          \
    -demosdir        ${INSTALL_DIR}/usr/share/${name}/demos             \
    -stl \
    -no-qt3support \
    -no-xmlpatterns \
    -no-phonon \
    -no-phonon-backend \
    -no-webkit \
    -no-libmng \
    -nomake demos \
    -nomake examples \
    -system-libpng \
    -no-gif \
    -system-libtiff \
    -no-nis \
    -no-openssl \
    -no-dbus \
    -no-cups \
    -no-iconv \
    -no-pch \
    -arch x86_64 \
    -L${INSTALL_DIR}/usr/lib                                            \
    -liconv                                                    \
    -lresolv                                                   \
    -I${INSTALL_DIR}/usr/include \
    -I${INSTALL_DIR}/usr/include/glib-2.0                               \
    -I${INSTALL_DIR}/usr/lib/glib-2.0/include                           \
    -I${INSTALL_DIR}/usr/include/libxml2 \
  || E failed to configure ${P}
  
  # qmake obviously still has some Makefile generation issues..
  for i in $(find * -name 'Makefile*'); do
    j=${i}.tmp
    cat ${i} \
      | sed \
        -e 's|-framework\ -framework||g' \
        -e 's|-framework\ -prebind||g' \
      > ${j}
    mv ${j} ${i}    
  done 
  
  I building ${P} \
  && ${MAKE} \
  || E failed to build ${P}
  
  I installing ${P} \
  && ${MAKE} install \
  || E failed to install ${P}


  if [ "yes" = "${INSTALL_QGL}" ]; then
    cd ${TMP_DIR}/${T} \
    && cd src/opengl \
    && ${MAKE} \
    && ${MAKE} install \
    || E "failed to install qgl"
  fi

  touch ${TMP_DIR}/.${P}.done

fi

#
# Install qwt
#

P=qwt-6.1.3
URL=http://cytranet.dl.sourceforge.net/project/qwt/qwt/6.1.3/qwt-6.1.3.tar.bz2
CKSUM=sha256:f3ecd34e72a9a2b08422fb6c8e909ca76f4ce5fa77acad7a2883b701f4309733
T=${P}
BRANCH=""

QMAKE_CXX="${CXX}" \
QMAKE_CXXFLAGS="${CPPFLAGS}" \
QMAKE_LFLAGS="${LDFLAGS}" \
EXTRA_OPTS="qwt.pro" \
build_and_install_qmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}

#
# Install sip
#

P=sip-4.19.1
URL=http://svwh.dl.sourceforge.net/project/pyqt/sip/sip-4.19.1/sip-4.19.1.tar.gz
CKSUM=sha256:501852b8325349031b769d1c03d6eab04f7b9b97f790ec79f3d3d04bf065d83e
T=${P}
BRANCH=""

if [ -f ${TMP_DIR}/.${P}.done ]; then
  I already installed ${P}
else
  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}
  
  cd ${TMP_DIR}/${T} \
  && ${PYTHON} configure.py \
    --arch=x86_64 \
    -b ${INSTALL_DIR}/usr/bin \
    -d ${PYTHONPATH} \
    -e ${INSTALL_DIR}/usr/include \
    -v ${INSTALL_DIR}/usr/share/sip \
    --stubsdir=${PYTHONPATH} \
  && ${MAKE} \
  && ${MAKE} install \
  || E failed to build
    
  touch ${TMP_DIR}/.${P}.done
fi

#
# Install PyQt4
#

P=PyQt4_gpl_x11-4.12
URL=http://superb-sea2.dl.sourceforge.net/project/pyqt/PyQt4/PyQt-4.12/PyQt4_gpl_x11-4.12.tar.gz
CKSUM=sha256:3c1d4b55314adb3e1132de8fc2a92eed216d37e58aceed41294dbca210ca88db
T=${P}
BRANCH=""

if [ -f ${TMP_DIR}/.${P}.done ]; then
  I already installed ${P}
else
  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}
  
  cd ${TMP_DIR}/${T} \
  && \
  CFLAGS="${CPPFLAGS} $(pkg-config --cflags QtCore QtDesigner QtGui QtOpenGL)" \
  CXXFLAGS="${CPPFLAGS} $(pkg-config --cflags QtCore QtDesigner QtGui QtOpenGL)" \
  LDFLAGS="$(pkg-config --libs QtCore QtDesigner QtGui QtOpenGL)" \
  ${PYTHON} configure.py \
    --confirm-license \
    -b ${INSTALL_DIR}/usr/bin \
    -d ${PYTHONPATH} \
    -v ${INSTALL_DIR}/usr/share/sip \
  && ${MAKE} \
  && ${MAKE} install \
  || E failed to build
    
  touch ${TMP_DIR}/.${P}.done
fi

#
# Install gnuradio
#

P=gnuradio
URL=git://github.com/gnuradio/gnuradio.git
CKSUM=git:59daaff0d9d04373d3a6b14ea7b46e080bad7a1e
T=${P}
BRANCH=v${GNURADIO_BRANCH}

if [ ! -f ${TMP_DIR}/.${P}.done ]; then

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}
  
  rm -Rf ${TMP_DIR}/${T}/volk
  
  fetch volk git://github.com/gnuradio/volk.git gnuradio/volk v1.3 git:4465f9b26354e555e583a7d654710cb63cf914ce
  unpack volk git://github.com/gnuradio/volk.git gnuradio/volk v1.3

  rm -f ${TMP_DIR}/.${P}.done

EXTRA_OPTS="\
  -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr \
  -DFFTW3F_INCLUDE_DIRS=${INSTALL_DIR}/usr/include \
  -DZEROMQ_INCLUDE_DIRS=${INSTALL_DIR}/usr/include \
  -DTHRIFT_INCLUDE_DIRS=${INSTALL_DIR}/usr/include \
  -DCPPUNIT_INCLUDE_DIRS=${INSTALL_DIR}/usr/include/cppunit \
  -DPYTHON_EXECUTABLE=$(which ${PYTHON}) \
  '-DCMAKE_C_FLAGS=-framework Python' \
  '-DCMAKE_CXX_FLAGS=-framework Python' \
  -DSPHINX_EXECUTABLE=${INSTALL_DIR}/usr/bin/rst2html-2.7.py \
  -DGR_PYTHON_DIR=${INSTALL_DIR}/usr/share/gnuradio/python/site-packages \
  ${TMP_DIR}/${T} \
" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}
#&& \
#for i in $(find ${INSTALL_DIR}/usr/share/gnuradio/python/site-packages -name '*.so'); do \
#  ln -sf ${i} ${INSTALL_DIR}/usr/lib; \
#done

  touch ${TMP_DIR}/.${P}.done

fi

#
# Install SoapySDR
#

P=SoapySDR
URL=https://github.com/pothosware/SoapySDR.git
CKSUM=git:74f890ce73c58c37df08ea518541d3f49ffefadb
T=${P}
BRANCH=soapy-sdr-0.6.0

LDFLAGS="${LDFLAGS} $(python-config --ldflags)" \
EXTRA_OPTS="-DCMAKE_MACOSX_RPATH=OLD -DCMAKE_INSTALL_NAME_DIR=${INSTALL_DIR}/usr/lib -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr -DPYTHON_EXECUTABLE=$(which ${PYTHON}) ${TMP_DIR}/${T}" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}

#
# Install LimeSuite
#

P=LimeSuite
URL=https://github.com/myriadrf/LimeSuite.git
CKSUM=git:9c365b144dc8fcc277a77843adf7dd4d55ba6406
T=${P}
BRANCH=v17.06.0

LDFLAGS="${LDFLAGS} $(python-config --ldflags)" \
EXTRA_OPTS="-DCMAKE_MACOSX_RPATH=OLD -DCMAKE_INSTALL_NAME_DIR=${INSTALL_DIR}/usr/lib -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr -DPYTHON_EXECUTABLE=$(which ${PYTHON}) ${TMP_DIR}/${T}" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}

#
# Install osmo-sdr
#

P=osmo-sdr
URL=git://git.osmocom.org/osmo-sdr
CKSUM=git:ba4fd96622606620ff86141b4d0aa564712a735a
T=${P}
BRANCH=ba4fd96622606620ff86141b4d0aa564712a735a

LDFLAGS="${LDFLAGS} $(python-config --ldflags)" \
EXTRA_OPTS="-DCMAKE_MACOSX_RPATH=OLD -DCMAKE_INSTALL_NAME_DIR=${INSTALL_DIR}/usr/lib -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr -DPYTHON_EXECUTABLE=$(which ${PYTHON}) ${TMP_DIR}/${T}" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}

#
# Install libhackrf
#

P=hackrf-2017.02.1
URL=http://mirror.csclub.uwaterloo.ca/gentoo-distfiles/distfiles/hackrf-2017.02.1.tar.xz
CKSUM=sha256:1dd1fbec98bf2fa56c92f82fd66eb46801a2248c019c4707b3971bc187cb973a
T=${P}/host

EXTRA_OPTS="-DCMAKE_MACOSX_RPATH=OLD -DCMAKE_INSTALL_NAME_DIR=${INSTALL_DIR}/usr/lib -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr -DCMAKE_C_FLAGS=\"-I${INSTALL_DIR}/usr/include\" ${TMP_DIR}/${T}" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T}

#
# Install libbladerf
#

P=bladeRF-2016.06
URL=http://mirror.csclub.uwaterloo.ca/gentoo-distfiles/distfiles/bladerf-2016.06.tar.gz
CKSUM=sha256:6e6333fd0f17e85f968a6180942f889705c4f2ac16507b2f86c80630c55032e8
T=${P}/host

EXTRA_OPTS="-DCMAKE_MACOSX_RPATH=OLD -DCMAKE_INSTALL_NAME_DIR=${INSTALL_DIR}/usr/lib -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr -DCMAKE_C_FLAGS=\"-I${INSTALL_DIR}/usr/include\" ${TMP_DIR}/${T}" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T}

#
# Install libairspy
#

P=airspy
URL=http://github.com/airspy/host.git
CKSUM=git:5c86e53c484140a4a5038a24e4f40f4fb8e6240d
T=${P}
BRANCH=v1.0.9

EXTRA_OPTS="-DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr -DCMAKE_C_FLAGS=\"-I${INSTALL_DIR}/usr/include\" ${TMP_DIR}/${T}" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}

#
# Install libmirisdr
#

P=libmirisdr
URL=git://git.osmocom.org/libmirisdr
CKSUM=git:59ba3721b1cb7c746503d8de9c918f54fe7e8399
T=${P}
BRANCH=master

EXTRA_OPTS="" \
build_and_install_autotools \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}

#
# Install gr-osmosdr
#

P=gr-osmosdr
URL=git://git.osmocom.org/gr-osmosdr
CKSUM=git:a45968f3381f33b86ca344bb76bd62c131d98d93
T=${P}
BRANCH=c653754dde5e2cf682965e939cc016fbddbd45e4

LDFLAGS="${LDFLAGS} $(python-config --ldflags)" \
EXTRA_OPTS="-DCMAKE_MACOSX_RPATH=OLD -DCMAKE_INSTALL_NAME_DIR=${INSTALL_DIR}/usr/lib -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/usr -DPYTHON_EXECUTABLE=$(which ${PYTHON}) ${TMP_DIR}/${T}" \
build_and_install_cmake \
  ${P} \
  ${URL} \
  ${CKSUM} \
  ${T} \
  ${BRANCH}

## XXX: @CF: requires librsvg which requires Rust... meh!
##
## Install CairoSVG
## 
#
#  P=CairoSVG
#  URL=http://github.com/Kozea/CairoSVG.git
#  CKSUM=git:d7305b7f7239b51908688ad0c36fdf4ddd8f3dc9
#  T=${P}
#  BRANCH=1.0.22
#
#LDFLAGS="${LDFLAGS} $(python-config --ldflags)" \
#build_and_install_setup_py \
#  ${P} \
#  ${URL} \
#  ${CKSUM} \
#  ${T} \
#  ${BRANCH}

## XXX: @CF requires rust... FML!!
##
## Get rsvg-convert
##
#
#P=librsvg
#URL=git://git.gnome.org/librsvg
#CKSUM=git:e7aec5151543573c2f18484d4134959e219dc4a4
#T=${P}
#BRANCH=2.41.0
#
#  EXTRA_OPTS="" \
#  build_and_install_autotools \
#    ${P} \
#    ${URL} \
#    ${CKSUM} \
#    ${T} \
#    ${BRANCH}

#
# Install some useful scripts
#

P=scripts

# always recreate scripts
if [ 1 -eq 1 ]; then

  I creating grenv.sh script
  cat > ${INSTALL_DIR}/usr/bin/grenv.sh << EOF
PYTHON=${PYTHON}
INSTALL_DIR=${INSTALL_DIR}
ULPP=\${INSTALL_DIR}/usr/lib/\${PYTHON}/site-packages
PYTHONPATH=\${ULPP}:\${PYTHONPATH}
GRSHARE=\${INSTALL_DIR}/usr/share/gnuradio
GRPP=\${GRSHARE}/python/site-packages
PYTHONPATH=\${GRPP}:\${PYTHONPATH}
PATH=\${INSTALL_DIR}/usr/bin:/opt/X11/bin:\${PATH}

EOF

  if [ $? -ne 0 ]; then
    E unable to create grenv.sh script
  fi

  cd ${INSTALL_DIR}/usr/lib/${PYTHON}/site-packages \
  && \
    for j in $(for i in $(find * -name '*.so'); do dirname $i; done | sort -u); do \
      echo "DYLD_LIBRARY_PATH=\"\${ULPP}/${j}:\${DYLD_LIBRARY_PATH}\"" >> ${INSTALL_DIR}/usr/bin/grenv.sh; \
    done \
    && echo "" >> ${INSTALL_DIR}/usr/bin/grenv.sh \
  || E failed to create grenv.sh;
  
  cd ${INSTALL_DIR}/usr/share/gnuradio/python/site-packages \
  && \
    for j in $(for i in $(find * -name '*.so'); do dirname $i; done | sort -u); do \
      echo "DYLD_LIBRARY_PATH=\"\${GRPP}/${j}:\${DYLD_LIBRARY_PATH}\"" >> ${INSTALL_DIR}/usr/bin/grenv.sh; \
      echo "PYTHONPATH=\"\${GRPP}/${j}:\${PYTHONPATH}\"" >> ${INSTALL_DIR}/usr/bin/grenv.sh; \
    done \
  && echo "export DYLD_LIBRARY_PATH" >> ${INSTALL_DIR}/usr/bin/grenv.sh \
  && echo "export PYTHONPATH" >> ${INSTALL_DIR}/usr/bin/grenv.sh \
  && echo "export PATH" >> ${INSTALL_DIR}/usr/bin/grenv.sh \
  || E failed to create grenv.sh
  
  I installing find-broken-dylibs script \
  && mkdir -p ${INSTALL_DIR}/usr/bin \
  && cat ${BUILD_DIR}/scripts/find-broken-dylibs.sh \
      | sed -e "s|@INSTALL_DIR@|${INSTALL_DIR}|g" \
      > ${INSTALL_DIR}/usr/bin/find-broken-dylibs \
  && chmod +x ${INSTALL_DIR}/usr/bin/find-broken-dylibs \
  || E "failed to install 'find-broken-dylibs' script"

  I installing run-grc script \
  && mkdir -p ${INSTALL_DIR}/usr/bin \
  && cat ${BUILD_DIR}/scripts/run-grc.sh \
      > ${INSTALL_DIR}/usr/bin/run-grc \
  && chmod +x ${INSTALL_DIR}/usr/bin/run-grc \
  || E "failed to install 'run-grc' script"

fi

#
# Create the GNURadio.app bundle
# 

  P=gr-logo
  URL=http://github.com/gnuradio/gr-logo.git
  CKSUM=git:8f51887761b88b8c4facda0970ae121b61a0d905
  T=${P}
  BRANCH="master"

#if [ ! -f ${TMP_DIR}/.${P}.done ]; then

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH} 

  # create the gnuradio.icns

#  create_icns_via_rsvg \
#    ${TMP_DIR}/${P}/gnuradio_logo_icon_square.svg \
#    ${TMP_DIR}/${P}/gnuradio.icns \
#  || E failed to create gnuradio.icns

#  create_icns_via_cairosvg \
#    ${TMP_DIR}/${P}/gnuradio_logo_icon_square.svg \
#    ${TMP_DIR}/${P}/gnuradio.icns \
#  || E failed to create gnuradio.icns

#  mkdir -p ${RESOURCES_DIR}/ \
#  && cp ${TMP_DIR}/${P}/gnuradio.icns ${RESOURCES_DIR}/ \
#  && I copied gnuradio.icns to ${RESOURCES_DIR} \
#  || E failed to install gnuradio.icns

  mkdir -p ${RESOURCES_DIR}/ \
  && cp ${BUILD_DIR}/gnuradio.icns ${RESOURCES_DIR}/ \
  && I copied gnuradio.icns to ${RESOURCES_DIR} \
  || E failed to install gnuradio.icns

  # create Info.plist

mkdir -p ${CONTENTS_DIR} \
&& I creating Info.plist \
&& cat > ${CONTENTS_DIR}/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleGetInfoString</key>
  <string>GNURadio</string>
  <key>CFBundleExecutable</key>
  <string>usr/bin/run-grc</string>
  <key>CFBundleIdentifier</key>
  <string>org.gnuradio.gnuradio-companion</string>
  <key>CFBundleName</key>
  <string>GNURadio</string>
  <key>CFBundleIconFile</key>
  <string>gnuradio.icns</string>
  <key>CFBundleShortVersionString</key>
  <string>${GNURADIO_BRANCH}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>grc</string>
        <string>GRC</string>
        <string>grc.xml</string>
        <string>GRC.XML</string>
      </array>
      <key>CFBundleTypeIconFile</key>
      <string>gnuradio.icns</string>
      <key>CFBundleTypeMIMETypes</key>
      <array>
        <string>application/gnuradio-grc</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>GNU Radio Companion Flow Graph</string>
      <key>CFBundleTypeOSTypes</key>
      <array>
        <string>GRC </string>
      </array>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSIsAppleDefaultForType</key>
      <true />
      <key>LSItemContentTypes</key>
      <array>
        <string>org.gnuradio.grc</string>
      </array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.xml</string>
      </array>
      <key>UTTypeDescription</key>
      <string>GNU Radio Companion Flow Graph</string>
      <key>UTTypeIconFile</key>
      <string>gnuradio.icns</string>
      <key>UTTypeIdentifier</key>
      <string>org.gnuradio.grc</string>
      <key>UTTypeReferenceURL</key>
      <string>http://www.gnuradio.org/</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>com.apple.ostype</key>
        <string>GRC </string>
        <key>public.filename-extension</key>
        <array>
          <string>grc</string>
          <string>GRC</string>
          <string>grc.xml</string>
          <string>GRC.XML</string>
        </array>
        <key>public.mime-type</key>
        <array>
          <string>application/gnuradio-grc</string>
        </array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF
if [ $? -ne 0 ]; then
  E failed to create Info.plist
fi
I created Info.plist

#  touch ${TMP_DIR}/.${P}.done 
#fi

#
# Create .dmg file
#

P=create-dmg
URL=http://github.com/andreyvit/create-dmg.git
CKSUM=git:5acf22fa87e1b751701f377efddc7429877ecb0a
T=${P}
BRANCH=master

#if [ ! -f ${TMP_DIR}/${P}.done ]; then

  fetch "${P}" "${URL}" "${T}" "${BRANCH}" "${CKSUM}"
  unpack ${P} ${URL} ${T} ${BRANCH}
  
  #XXX: @CF: add --eula option with GPLv3. For now, just distribute LICENSE in dmg
  
  VERSION="$(gen_version)"
  
  I creating GNURadio-${VERSION}.dmg
  
  cd ${TMP_DIR}/${P} \
  && I "copying GNURadio.app to temporary folder (this can take some time)" \
  && rm -Rf ${TMP_DIR}/${P}/temp \
  && rm -f ${BUILD_DIR}/*GNURadio-${VERSION}.dmg \
  && mkdir -p ${TMP_DIR}/${P}/temp \
  && rsync -ar ${APP_DIR} ${TMP_DIR}/${P}/temp \
  && cp ${BUILD_DIR}/LICENSE ${TMP_DIR}/${P}/temp \
  && I "executing create-dmg.. (this can take some time)" \
  && I "create-dmg \
    --volname "GNURadio-${VERSION}" \
    --volicon ${BUILD_DIR}/gnuradio.icns \
    --background ${BUILD_DIR}/gnuradio-logo-noicon.png \
    --window-pos 200 120 \
    --window-size 550 400 \
    --icon LICENSE 137 190 \
    --icon GNURadio.app 275 190 \
    --hide-extension GNURadio.app \
    --app-drop-link 412 190 \
    --icon-size 100 \
    ${BUILD_DIR}/GNURadio-${VERSION}.dmg \
    ${TMP_DIR}/${P}/temp \
  " \
  && ./create-dmg \
    --volname "GNURadio-${VERSION}" \
    --volicon ${BUILD_DIR}/gnuradio.icns \
    --background ${BUILD_DIR}/gnuradio-logo-noicon.png \
    --window-pos 200 120 \
    --window-size 550 400 \
    --icon LICENSE 137 190 \
    --icon GNURadio.app 275 190 \
    --hide-extension GNURadio.app \
    --app-drop-link 412 190 \
    --icon-size 100 \
    ${BUILD_DIR}/GNURadio-${VERSION}.dmg \
    ${TMP_DIR}/${P}/temp \
  || E "failed to create GNURadio-${VERSION}.dmg"

I "finished creating GNURadio-${VERSION}.dmg"

#  touch ${TMP_DIR}/.${P}.done 
#fi

I ============================================================================
I finding broken .dylibs and .so files in ${INSTALL_DIR}
I ============================================================================
${INSTALL_DIR}/usr/bin/find-broken-dylibs
I ============================================================================

I '!!!!!! DONE !!!!!!'
