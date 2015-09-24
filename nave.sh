#!/bin/bash

# This program contains parts of narwhal's "sea" program,
# as well as bits borrowed from Tim Caswell's "nvm"

# nave install <version>
# Fetch the version of node and install it in nave's folder.

# nave use <version>
# Install the <version> if it isn't already, and then start
# a subshell with that version's folder at the start of the
# $PATH

# nave use <version> program.js
# Like "nave use", but have the subshell start the program.js
# immediately.

# When told to use a version:
# Ensure that the version exists, install it, and
# then add its prefix to the PATH, and start a subshell.

if [ "$NAVE_DEBUG" != "" ]; then
  set -x
fi

if [ -z "$BASH" ]; then
  cat >&2 <<MSG
Nave is a bash program, and must be run with bash.
MSG
  exit 1
fi

shell=`basename "$SHELL"`
case "$shell" in
  bash) ;;
  zsh) ;;
  *)
    echo "Nave only supports zsh and bash shells." >&2
    exit 1
    ;;
esac

# Use fancy pants globs
shopt -s extglob

# Try to figure out the os and arch for binary fetching
uname="$(uname -a)"
os=
arch=
case "$uname" in
  Linux\ *) os=linux ;;
  Darwin\ *) os=darwin ;;
  SunOS\ *) os=sunos ;;
  *\ Cygwin) os=cygwin ;;
esac
case "$uname" in
  *i386*) arch=x86 ;;
  *i686*) arch=x86 ;;
  *x86_64*) arch=x64 ;;
  *raspberrypi*) arch=arm-pi ;;
esac

tar=${TAR-tar}

main () {
  local SELF_PATH
  # get the absolute path of the executable
  SELF_PATH="$0"
  if [ "${SELF_PATH:0:1}" != "." ] && [ "${SELF_PATH:0:1}" != "/" ]; then
    SELF_PATH=./"$SELF_PATH"
  fi
  SELF_PATH=$( cd -P -- "$(dirname -- "$SELF_PATH")" \
            && pwd -P \
            ) && SELF_PATH=$SELF_PATH/$(basename -- "$0")

  # resolve symlinks
  SELF_PATH="$(resolve "$SELF_PATH")"
  NAVE_BIN_DIR="$(dirname -- "$SELF_PATH")"

  if [ -z "$NAVE_DIR" ]; then
    if [ -d "$HOME" ]; then
      NAVE_DIR="$HOME"/.nave
    else
      NAVE_DIR=/usr/local/lib/nave
    fi
  fi
  if ! [ -d "$NAVE_DIR" ] && ! mkdir -p -- "$NAVE_DIR"; then
    NAVE_DIR="$NAVE_BIN_DIR"
  fi

  nave_rc "$NAVE_DIR"

  export NAVE_DIR
  export NAVE_ENV_FILE="nave_env"
  export NAVE_SRC="$NAVE_DIR/src"
  export NAVE_ROOT="$NAVE_DIR/installed"
  export NAVE_GLOBAL_ROOT="$NAVE_DIR/global"
  export NAVE_GLOBAL_VERSION="$NAVE_GLOBAL_ROOT/version"
  ensure_dir "$NAVE_SRC"
  ensure_dir "$NAVE_ROOT"
  ensure_dir "$NAVE_GLOBAL_ROOT"

  local cmd="$1"
  shift
  case $cmd in
    ls-remote | ls-all)
      cmd="nave_${cmd/-/_}"
      ;;
#    use)
#      cmd="nave_named"
#      ;;
    install | modules | fetch | use | clean | test | named | npm | \
    ls | uninstall | usemain | latest | stable | has | installed )
      cmd="nave_$cmd"
      ;;
    * )
      cmd="nave_help"
      ;;
  esac
  $cmd "$@"
  local ret=$?
  if [ $ret -eq 0 ]; then
    exit 0
  else
    echo "failed with code=$ret" >&2
    exit $ret
  fi
}

function join () {
  local IFS=" "; echo "$*";
}

function resolve () {
  local FILE="$1"
  local DIR SYM
  while [ -h "$FILE" ]; do
    DIR=$(dirname -- "$FILE")
    SYM=$(readlink -- "$FILE")
    FILE=$( cd -- "$DIR" \
         && cd -- $(dirname -- "$SYM") \
         && pwd )/$(basename -- "$SYM")
  done
  echo $FILE
}

ensure_dir () {
  if ! [ -d "$1" ]; then
    mkdir -p -- "$1" || fail "couldn't create $1"
  fi
}

remove_dir () {
  if [ -d "$1" ]; then
    rm -rf -- "$1" || fail "Could not remove $1"
  fi
}

fail () {
  echo "$@" >&2
  exit 1
}

nave_rc () {
  local dir="$1"
  # set up the naverc init file.
  # For zsh compatibility, we name this file ".zshenv" instead of
  # the more reasonable "naverc" name.
  # Important! Update this number any time the init content is changed.
  local rcversion="#4"
  local rcfile="$dir/.zshenv"
  if [ -f "$rcfile" ] && [ "$(head -n1 "$rcfile")" == "$rcversion" ]; then
    return 0
  fi

  cat > "$rcfile" <<RC
$rcversion
[ "\$NAVE_DEBUG" != "" ] && set -x || true
if [ "\$BASH" != "" ]; then
  if [ "\$NAVE_LOGIN" != "" ]; then
    [ -f ~/.bash_profile ] && . ~/.bash_profile || true
    [ -f ~/.bash_login ] && .  ~/.bash_login || true
    [ -f ~/.profile ] && . ~/.profile || true
  else
    [ -f ~/.bashrc ] && . ~/.bashrc || true
  fi
else
  [ -f ~/.zshenv ] && . ~/.zshenv || true
  export DISABLE_AUTO_UPDATE=true
  if [ "\$NAVE_LOGIN" != "" ]; then
    [ -f ~/.zprofile ] && . ~/.zprofile || true
    [ -f ~/.zshrc ] && . ~/.zshrc || true
    [ -f ~/.zlogin ] && . ~/.zlogin || true
  else
    [ -f ~/.zshrc ] && . ~/.zshrc || true
  fi
fi
unset ZDOTDIR
source \$NAVE_ENV
[ -f ~/.naverc ] && . ~/.naverc || true
RC

  cat > "$dir/.zlogout" <<RC
[ -f ~/.zlogout ] && . ~/.zlogout || true
RC

  # couldn't write file
  if ! [ -f "$rcfile" ] || [ "$(head -n1 "$rcfile")" != "$rcversion" ]; then
    fail "Nave dir $dir is not writable."
  fi
}

nave_write_env () {
  local name="$1"
  shift
  local version="$1"
  shift
  local target="$1"
  shift

  local prefix="$NAVE_ROOT/$name"
  [ "$target" != "" ] && prefix="$target"
  local env_file="$prefix/$NAVE_ENV_FILE"
  local bin="$prefix/bin"
  local lib="$prefix/lib/node"
  local modules="$prefix/lib/node_modules"
  local man="$prefix/share/man"
  local path="$bin"
  ensure_dir "$bin"
  ensure_dir "$lib"
  ensure_dir "$modules"
  ensure_dir "$man"

  if [ "$os" == "cygwin" ]; then
    # XXX: cygwin stores npm binaries in $prefix/lib instead
    # of bindir, need to force $bin for npm binaries
    path="$path:$prefix/lib"
    prefix="$(cygpath -w $prefix)\\lib"
    bin=$(cygpath -w $bin)
    lib=$(cygpath -w $lib)
    modules=$(cygpath -w $modules)
    man=$(cygpath -w $modules)
  fi

  local nave="$version"
  if [ "$version" != "$name" ]; then
    nave="$name"-"$version"
  fi

  local sep=":"
  [ "$os" == "cygwin" ] && sep=";"

  cat > $env_file <<ENDENV
export NAVEPATH="$path"
export NAVEBIN="$bin"
export NAVEVERSION="$version"
export NAVENAME="$name"
export NAVE="$nave"
export npm_config_binroot="$bin"
export npm_config_root="$lib"
export npm_config_manroot="$man"
export npm_config_prefix="$prefix"
export NODE_MODULES="$modules"
export NODE_PATH="$lib${sep}$modules"
export NAVE_DIR="$NAVE_DIR"
export PATH="\$NAVEPATH:\$PATH"
ENDENV
}

nave_fetch () {
  local version=$(ver "$1")
  if nave_has "$version"; then
    echo "already fetched $version" >&2
    return 0
  fi

  local src="$NAVE_SRC/$version"
  remove_dir "$src"
  ensure_dir "$src"

  local url
  local urls=(
    "https://iojs.org/dist/v$version/iojs-v$version.tar.gz"
    "http://nodejs.org/dist/v$version/node-v$version.tar.gz"
    "http://nodejs.org/dist/node-v$version.tar.gz"
    "http://nodejs.org/dist/node-$version.tar.gz"
  )
  for url in "${urls[@]}"; do
    get -#Lf "$url" > "$src".tar.gz
    if [ $? -eq 0 ]; then
      $tar xzf "$src".tar.gz -C "$src" --strip-components=1
      if [ $? -eq 0 ]; then
        echo "fetched from $url" >&2
        return 0
      fi
    fi
  done

  rm "$src".tar.gz
  remove_dir "$src"
  echo "Couldn't fetch $version" >&2
  return 1
}

get () {
  curl -H "user-agent:nave/$(curl --version | head -n1)" "$@"
  return $?
}

sha_check () {
  local file="$1"
  local base=$(basename -- $file)
  local sha=$(cat "$file.sha" | awk '{ printf $1; }')
  local length=$(echo -n "$sha" | wc -c)
  if [ $length == "64" ]; then
    echo "$sha  $file" | sha256sum -c #2>&1
  else
    echo "$sha  $file" | sha1sum -c #2>&1
  fi
  return $?
}

get_shasum () {
  local tgz="$1"
  local base=$(basename -- $tgz)
  local bin=${2:-$base}
  local sha="$tgz.sha"
  if ! [ -f "$sha" ]; then
    for url in "https://iojs.org/dist/v$version/SHASUMS256.txt" \
               "http://nodejs.org/dist/v$version/SHASUMS256.txt" \
               "http://nodejs.org/dist/v$version/SHASUMS.txt"; do
      get -#Lf "$url" | grep "${bin}" > "$sha"
      if [ $? -eq 0 ]; then break; fi
      rm "$sha"
    done
  fi
}

get_node () {
  local version="$1"
  local tgz="$2"
  local download="$3"
  if ! [ -f "$tgz" ] || ! sha_check "$tgz"; then
    # cygwin support
    local nodedir=""
    local iojsdir=""
    if [ "$os" == "cygwin" ]; then
      case "$arch" in
          x86) iojsdir="win-x86/" ;;
          x64)
            iojsdir="win-x64/"
            nodedir="x64/"
          ;;
      esac
    fi
    for url in "https://iojs.org/dist/v$version/${iojsdir}iojs$download" \
               "http://nodejs.org/dist/v$version/${nodedir}node$download"; do
      get -#Lf "$url" > "$tgz"
      if [ $? -eq 0 ]; then break; fi
      # binary download failed.  oh well.  cleanup, and proceed.
      rm "$tgz"
    done
  fi
}

build_npm () {
  local version="$1"
  local target="$2"
  local tab="$NAVE_SRC/index.tab"
  rm -f $tab
  # merge all tab files
  for url in "https://iojs.org/dist/index.tab" \
               "http://nodejs.org/dist/index.tab"; do
    get -#Lf "$url" >> "$tab"
  done
  local npm_ver=$(cat $tab | grep "v$version" | awk '{ printf $4; }')
  local tgz="$NAVE_SRC/npm-${npm_ver}.tar.gz"
  if ! [ -f "$tgz" ]; then
    get -#Lf "https://github.com/npm/npm/archive/v${npm_ver}.tar.gz" >> "$tgz"
    if [ $? -ne 0 ] || ! [ -f $tgz ]; then
      echo "Cannot download npm" >&2
      rm $tgz
      return 1
    fi
  fi
  local npm_dir="$target/lib/node_modules/npm"
  ensure_dir "$npm_dir"
  $tar xzf "$tgz" -C "$npm_dir" --strip-components 1
  if [ $? -ne 0 ]; then
    echo "Cannot unpack npm" >&2
    return 1
  fi
  # Install binaries
  cp "$npm_dir/bin/npm" "$target/bin/"
  chmod 0755 "$npm_dir/bin/npm"
  if [ $? -ne 0 ]; then return 1; fi
  if [ "$os" == "cygwin" ]; then
    cp "$npm_dir/bin/npm.cmd" "$target/bin/"
    chmod 0755 "$npm_dir/bin/npm.cmd"
    if [ $? -ne 0 ]; then return 1; fi
    # node_modules/npm must be near node.exe create symlink
    local bin_dir=$(cygpath -w "$target/bin/node_modules/")
    rm -f "$bin_dir"
    cmd /c "mklink /D $bin_dir ..\\lib\\node_modules"
    if [ $? -ne 0 ]; then return 1; fi
    # set cygwin python as npm python (for gyp)
    local python=`cygpath -w $(which python)`
    nave_npm "$version" "-g" "config" "set" "python" "'$python'"
    return $?
  fi
}

build_cygwin () {
  local version="$1"
  local target="$2"
  local tgz="$NAVE_SRC/${version}.exe"
  local nodevars="$NAVE_SRC/nodevars.bat"
  local nv_url="https://raw.githubusercontent.com/nodejs/node/master/tools/msvs/nodevars.bat"
  # check iojs support
  get_shasum "$tgz" "node.exe"
  get_node "$version" "$tgz" ".exe"
  if ! [ -f "$nodevars" ]; then
    get -#Lf "$nv_url" > "$nodevars"
  fi
  if [ -f "$nodevars" ] && [ -f "$tgz" ] && sha_check "$tgz"; then
    ensure_dir "$target/bin/"
    cp "$tgz" "$target/bin/node.exe"
    cp "$nodevars" "$target/bin/"
    chmod 0755 "$target/bin/node.exe" "$target/bin/nodevars.bat"
    build_npm "$version" "$target"
    if [ $? -eq 0 ]; then
      echo "installed from binary" >&2
      return 0
    fi
    nave_uninstall "$version"
    echo "Binary unpack failed." >&2
  else
    rm -f "$tgz"
  fi
  return 1
}

build_unix () {
  local version="$1"
  local target="$2"
  # shortcut - try the binary if possible.
  if [ -n "$os" ]; then
    local binavail
    # binaries started with node 0.8.6
    case "$version" in
      0.8.[012345]) binavail=0 ;;
      0.[1234567]) binavail=0 ;;
      *) binavail=1 ;;
    esac
    if [ $binavail -eq 1 ]; then
      local t="$version-$os-$arch"
      local tgz="$NAVE_SRC/$t.tar.gz"
      get_shasum "$tgz"
      get_node "$version" "$tgz" "-v${t}.tar.gz"
      if [ -f "$tgz" ] && sha_check "$tgz"; then
        # unpack straight into the build target.
        $tar xzf "$tgz" -C "$target" --keep-directory-symlink \
          --strip-components 1
        if [ $? -eq 0 ]; then
          # it worked!
          echo "installed from binary" >&2
          return 0
        fi
        rm "$tgz"
        nave_uninstall "$version"
        echo "Binary unpack failed, trying source." >&2
      else
        echo "Binary download failed, trying source." >&2
      fi
    fi
  fi
  if [ "$os" == "cygwin" ]; then
    echo "Soruce build does not supported on cygwin";
    return 1
  fi
  build_src "$version" "$target"
  return $?
}

build_src () {
  local version="$1"
  local target="$2"
  nave_fetch "$version"
  if [ $? -ne 0 ]; then
    # fetch failed, don't continue and try to build it.
    return 1
  fi

  local src="$NAVE_SRC/$version"
  local jobs=$NAVE_JOBS
  jobs=${jobs:-$JOBS}
  jobs=${jobs:-$(sysctl -n hw.ncpu)}
  jobs=${jobs:-2}

  ( cd -- "$src"
    [ -f ~/.naverc ] && . ~/.naverc || true
    if [ "$NAVE_CONFIG" == "" ]; then
      NAVE_CONFIG=()
    fi
    JOBS=$jobs ./configure "${NAVE_CONFIG[@]}" --prefix="$target" \
      || fail "Failed to configure $version"
    JOBS=$jobs make -j$jobs \
      || fail "Failed to make $version"
    make install || fail "Failed to install $version"
  ) || fail "fail"
  return $?
}

build () {
  local version="$1"
  local target="$2"
  local cmd="fail"
  case "$os" in
    cygwin) cmd="build_cygwin" ;;
    *) cmd="build_unix" ;;
  esac
  $cmd "$version" "$target"
  local ret=$?
  if [ $ret -eq 0 ]; then
    nave_write_env "$version" "$version" "$target"
  fi
  return $ret
}

function main_prefix () {
  local wn=$(which node || true)
  local prefix="/usr/local"
  if [ "x$wn" != "x" ]; then
    prefix="${wn/\/bin\/node/}"
    if [ "x$prefix" == "x" ]; then
      prefix="/usr/local"
    fi
  fi
  echo $prefix
}

function global_version () {
  [ -f "$NAVE_GLOBAL_VERSION" ] || fail "No global version installed"
  echo $(cat "$NAVE_GLOBAL_VERSION")
}

# non-bin files
NODE_FILES=("include/node lib/node lib/node_modules share/doc/node
  share/man/man1/node.1 share/man/man1/iojs.1
  share/systemtap/tapset/node.stp")
nave_global_install () {
  local version=$(ver "$1")
  local install="$NAVE_GLOBAL_ROOT/$version"
  local prefix=$(main_prefix)
  local files="$NODE_FILES"
  for file in $(ls $install/bin); do
    files="$files bin/$file"
  done

  for file in $files; do
    local dst="$prefix/$file"
    local src="$install/$file"
    if ! [ -e "$src" ]; then
      continue
    fi
    if [ -e "$dst" ]; then
      if ! [ -h "$dst" ]; then
        echo "Refuse to delete $dst since it is not symlink"
        return 1
      fi
    fi
    ensure_dir $(dirname "$dst")
    ln -snf -- "$src" "$dst"
  done

  # Create env & version files, global
  nave_write_env "global" "$version" "$prefix"
  echo -n "$version" > "$NAVE_GLOBAL_ROOT/version"
}

nave_global_uninstall () {
  local prefix="$(main_prefix)"
  local current=$(node -v 2>/dev/null || true)
  current="${current/v/}"
  if [ "$current" == "" ]; then
    echo "No node installed"
    return 0
  fi
  # Remove modules trash
  local bindir="$prefix/bin/node"
  bindir=`dirname $(resolve "$bindir")`
  for file in $(ls $bindir); do
    src="$bindir/$file"
    target="$prefix/bin/$file"
    if [ -h $target ] && [ "$target" -ef "$src" ]; then
      rm -f -- $target
    fi
  done
  # Remove node files
  for file in $NODE_FILES; do
    target="${prefix}/$file"
    if [ -h $target ]; then
      rm -f -- $target || fail "Could not remove $file"
      local dir=$(dirname "$file")
      while [ "$dir" != "." ] && [ "$(ls -A $prefix/$dir)" == "" ]; do
        remove_dir "$prefix/$dir"
        dir=$(dirname "$dir")
      done
    elif [ -e $target ]; then
      fail "$target is not a symlink"
    fi
  done
  # remove env file
  rm -f "$prefix/$NAVE_ENV_FILE"
  rm -f "$NAVE_GLOBAL_VERSION"
}

nave_usemain () {
  if [ ${NAVELVL-0} -gt 0 ]; then
    fail "Can't usemain inside a nave subshell. Exit to main shell."
  fi
  local version=$(ver "$1")
  nave_install "$version" "global"
  nave_global_install "$version"
}

nave_modules () {
  local version=$(ver "$1")
  local modules="$2"
  local group="$3"
  # do nothing on missing modules
  if [ -z "$modules" ] || ! [ -f "$modules" ]; then
    return 0
  fi

  local SCRIPT="$NAVE_BIN_DIR/node_modules.js"
  SCRIPT="$(resolve "$SCRIPT")"
  [ "$os" == "cygwin" ] && SCRIPT=$(cygpath -m $SCRIPT)

  # install bootstrap modules
  local BOOTSTRAP=("node-getopt rimraf semver")
  # XXX: remove
  [ "$os" != "cygwin" ] && BOOTSTRAP+=" sleep"
  for module in ${BOOTSTRAP[@]}; do
    # nave_npm is noticeable slow
    local prefix="$NAVE_ROOT/$version"
    [ "$version" == "global" ] && prefix="$NAVE_GLOBAL_ROOT/$(global_version)"
    if ! [ -f "$prefix/lib/node_modules/$module/package.json" ]; then
      nave_npm "$version" "-g" "install" "$module"
      local ret=$?
      if [ $ret -ne 0 ]; then
        echo "Cannot install $module from bootstrap"
        return $ret
      fi
    fi
  done

  if [ -z "$group" ]; then
    if [ "$version" == "global" ]; then
      group="global"
    else
      group="local"
    fi
  fi
  nave_run "$version" '$NAVEBIN/node' "$SCRIPT" "build" "$modules" "-v" "-s" \
      "-t" "$group" "-d" '$NODE_MODULES'
  return $?
}

nave_install () {
  local version=$(ver "$1")
  local global="$2"
  if [ -z "$version" ]; then
    fail "Must supply a version ('stable', 'latest' or numeric)"
  fi
  if nave_installed "$version" "$global"; then
    echo "Already installed: $version" >&2
    return 0;
  fi
  local root="$NAVE_ROOT"
  [ "$global" == "global" ] && root="$NAVE_GLOBAL_ROOT"
  local install="$root/$version"
  ensure_dir "$install"

  build "$version" "$install"
  local ret=$?
  if [ $ret -ne 0 ]; then
    remove_dir "$install"
  fi
  return $ret
}

nave_test () {
  local version=$(ver "$1")
  nave_fetch "$version"
  local src="$NAVE_SRC/$version"
  ( cd -- "$src"
    [ -f ~/.naverc ] && . ~/.naverc || true
    if [ "$NAVE_CONFIG" == "" ]; then
      NAVE_CONFIG=()
    fi
    ./configure "${NAVE_CONFIG[@]}" || fail "failed to ./configure"
    make test-all || fail "Failed tests"
  ) || fail "failed"
}

nave_ls () {
  ls -- $NAVE_SRC | version_list "src" \
    && ls -- $NAVE_ROOT | version_list "installed" \
    && nave_ls_named \
    || return 1
}

nave_ls_remote () {
  get -s http://nodejs.org/dist/ \
    | version_list "node remote" \
    || return 1
  get -s https://iojs.org/dist/ \
    | version_list "io.js remote" \
    || return 1
}

nave_ls_named () {
  echo "named:"
  ls -- "$NAVE_ROOT" \
    | egrep -v '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort \
    | while read name; do
      echo "$name: $(ver $($NAVE_ROOT/$name/bin/node -v 2>/dev/null))"
    done
}

nave_ls_all () {
  nave_ls \
    && (echo ""; nave_ls_remote) \
    || return 1
}

ver () {
  local version="$1"
  local nonames="$2"
  version="${version/v/}"
  case $version in
    latest | stable) nave_$version ;;
    +([0-9])\.+([0-9])) nave_version_family "$version" ;;
    +([0-9])\.+([0-9])\.+([0-9])) echo $version ;;
    *) [ "$nonames" = "" ] && echo $version ;;
  esac
}

nave_version_family () {
  local family="$1"
  family="${family/v/}"
  { get -s http://nodejs.org/dist/;
    get -s https://iojs.org/dist/; } \
    | egrep -o $family'\.[0-9]+' \
    | sort -u -k 1,1n -k 2,2n -k 3,3n -t . \
    | tail -n1
}

nave_latest () {
  get -s https://iojs.org/dist/ \
    | egrep -o '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u -k 1,1n -k 2,2n -k 3,3n -t . \
    | tail -n1
}

nave_stable () {
  get -s http://nodejs.org/dist/ \
    | egrep -o '[0-9]+\.[0-9]*[02468]\.[0-9]+' \
    | sort -u -k 1,1n -k 2,2n -k 3,3n -t . \
    | tail -n1
}

version_list_named () {
  egrep -v '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u -k 1,1n -k 2,2n -k 3,3n -t . \
    | organize_version_list \
    || return 1
}

version_list () {
  echo "$1:"
  egrep -o '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u -k 1,1n -k 2,2n -k 3,3n -t . \
    | organize_version_list \
    || return 1
}

organize_version_list () {
  local i=0
  local v
  while read v; do
    if [ $i -eq 8 ]; then
      i=0
      echo "$v"
    else
      let 'i = i + 1'
      echo -ne "$v\t"
    fi
  done
  echo ""
  [ $i -ne 0 ] && echo ""
  return 0
}

nave_has () {
  local version=$(ver "$1")
  [ -x "$NAVE_SRC/$version/configure" ] || return 1
}

nave_installed () {
  local version=$(ver "$1")
  local global="$2"
  local root="$NAVE_ROOT"
  [ "$global" == "global" ] && root="$NAVE_GLOBAL_ROOT"
  local node="$root/$version/bin/node"
  if [ "$os" == "cygwin" ]; then node="${node}.exe"; fi
  [ -x "$node" ] || return 1
}

nave_use () {
  local version=$(ver "$1")

  # if it's not a version number, then treat as a name.
  case "$version" in
    +([0-9])\.+([0-9])\.+([0-9])) ;;
    *)
      nave_named "$@"
      return $?
      ;;
  esac

  if [ -z "$version" ]; then
    fail "Must supply a version"
  fi

  if [ "$version" == "$NAVENAME" ]; then
    echo "already using $version" >&2
    if [ $# -gt 1 ]; then
      shift
      "$@"
    fi
    return $?
  fi

  nave_install "$version" || fail "failed to install $version"
  echo "using $version" >&2
  nave_login "$version"
  return $?
}

nave_login () {
  local name="$1"
  local args=()
  if [ "$shell" != "zsh" ]; then
    # bash, use --rcfile argument
    args=("--rcfile" "$NAVE_DIR/.zshenv")
  fi
  nave_exec_env "1" "$name" "${args[@]}"
  return $?
}

nave_run () {
  local name="$1"
  shift
  # source the nave env file, then run the command.
  local args=$(join ". $NAVE_DIR/.zshenv;" "$@")
  nave_exec_env "" "$name" "-c" "${args[@]}"
  return $?
}

nave_exec_env () {
  local lvl=$[ ${NAVELVL-0} + 1 ]
  local isLogin="$1"
  shift
  local name="$1"
  shift
  # now $@ is the command to run, or empty if it's not an exec.

  local prefix="$NAVE_ROOT/$name"
  if [ "$name" == "global" ]; then
      prefix="$NAVE_GLOBAL_ROOT/$(global_version)"
  fi
  local env_file="$prefix/$NAVE_ENV_FILE"
  local exit_code
  NAVELVL=$lvl \
  NAVE_ENV=$env_file \
  ZDOTDIR="$NAVE_DIR" \
    "$SHELL" "$@"

  exit_code=$?
  hash -r
  return $exit_code
}

nave_named () {
  local name="$1"
  shift

  local version=$(ver "$1" NONAMES)
  if [ "$version" != "" ]; then
    shift
  fi

  add_named_env "$name" "$version" || fail "failed to create $name env"

  if [ "$name" == "$NAVENAME" ] && [ "$version" == "$NAVEVERSION" ]; then
    echo "already using $name" >&2
    if [ $# -gt 0 ]; then
      "$@"
    fi
    return $?
  fi

  if [ "$version" = "" ]; then
    version="$(ver "$("$NAVE_ROOT/$name/bin/node" -v 2>/dev/null)")"
  fi

  # get the version
  if [ $# -gt 0 ]; then
    nave_run "$name" "$@"
    return $?
  else
    nave_login "$name"
    return $?
  fi
}

add_named_env () {
  local name="$1"
  local version="$2"
  local cur="$(ver "$($NAVE_ROOT/$name/bin/node -v 2>/dev/null)" "NONAMES")"

  if [ "$version" != "" ]; then
    version="$(ver "$version" "NONAMES")"
  else
    version="$cur"
  fi

  if [ "$version" = "" ]; then
    echo "What version of node?"
    read -p "stable, latest, x.y, or x.y.z > " version
    version=$(ver "$version")
  fi

  # if that version is already there, then nothing to do.
  if [ "$cur" = "$version" ]; then
    return 0
  fi

  echo "Creating new env named '$name' using node $version" >&2

  nave_install "$version" || fail "failed to install $version"
  nave_write_env "$name" "$version"

  local binaries=("node npm node-waf")
  for bin in "${binaries[@]}"; do
    ln -sf -- "$NAVE_ROOT/$version/bin/$bin" "$NAVE_ROOT/$name/bin/$bin"
  done
}

nave_clean () {
  rm -rf "$NAVE_SRC/$(ver "$1")" "$NAVE_SRC/$(ver "$1")".tar.gz \
    "$NAVE_SRC/$(ver "$1")"-*.tar.gz
}

nave_uninstall () {
  local version=$(ver "$1")
  local global=$2
  if [ "$version" == "global" ]; then
      nave_global_uninstall
      return $?
  fi
  local root="$NAVE_ROOT"
  [ "$global" == "global" ] && root=$NAVE_GLOBAL_ROOT
  remove_dir "$root/$version"
}

nave_npm () {
  local version=$(ver "$1")
  shift
  nave_run "$version" '$NAVEBIN/npm' "$@"
}

nave_help () {
  cat <<EOF

Usage: nave <cmd>

Commands:

install <version>         Install the version passed (ex: 0.1.103).
modules <version> <list>  Install modules from specified list
use <version>             Enter a subshell where <version> is being used
use <ver> <program>       Enter a subshell, and run "<program>", then exit
use <name> <ver>          Create a named env, using the specified version.
                          If the name already exists, but the version differs,
                          then it will update the link.
usemain <version>         Install in /usr/local/bin (ie, use as your main nodejs)
clean <version>           Delete the source code for <version>
uninstall <version>       Delete the install for <version>
                          "global" as version will uninstall symlinks from prefix
                          "global" as second argument will uninstall from directory
npm <version> [args..]    Run npm in <version> env
ls                        List versions currently installed
ls-remote                 List remote node versions
ls-all                    List remote and local node versions
latest                    Show the most recent dist version
help                      Output help information

<version> can be the string "latest" to get the latest distribution.
<version> can be the string "stable" to get the latest stable version.

EOF
}

main "$@"
