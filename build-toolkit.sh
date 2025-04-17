#!/usr/bin/env bash

export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib/pkgconfig:$PKG_CONFIG_PATH
export ACLOCAL_PATH=/usr/share/aclocal

OS_ARCH=""

for arg in "$@"; do
  if [[ $arg == --arch=* ]]; then
    # shellcheck disable=SC2034
    OS_ARCH="${arg#--arch=}"
  fi
done

LIBRARY_VERSIONS_INDEX=''
DEFAULT_BUILD_FOLDER="_build"
# shellcheck disable=SC2034
FREEDESKTOP_GIT="https://gitlab.com/freedesktop-sdk/mirrors/freedesktop/"
VS_BASE_PATH="/c/Program Files/Microsoft Visual Studio"
WINDOWS_KITS_BASE_PATH="/c/Program Files (x86)/Windows Kits/10"

try_setup_msvc() {
  if (is_windows); then
    VS_EDITION="$(get_vs_edition "$VS_BASE_PATH")"
    MSVC_VERSION="$(get_msvc_version "$VS_BASE_PATH" "$VS_EDITION")"
    WINDOWS_KITS_VERSION="$(get_windows_kits_version "$WINDOWS_KITS_BASE_PATH")"

    export PATH="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/bin/Hostx64/x64:$PATH"
    export LIB="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/lib/x64:$WINDOWS_KITS_BASE_PATH/Lib/$WINDOWS_KITS_VERSION/um/x64:$WINDOWS_KITS_BASE_PATH/Lib/$WINDOWS_KITS_VERSION/ucrt/x64"
    export INCLUDE="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/include:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/ucrt:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/um:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/shared"
    echo "Correctly set env vars for Visual Studio $VS_EDITION, MSVC $MSVC_VERSION and Windows Kits $WINDOWS_KITS_VERSION"
  fi
}

try_setup_xcode() {
  if (is_macos); then
    export MACOSX_DEPLOYMENT_TARGET=12.0
  fi
}

os_lib_format() {
  local is_static=false
  case "$1" in
    static)
      is_static=true
      ;;
    shared)
      is_static=false
      ;;
    *)
      echo "Unknown library type: $1" >&2
      exit 1
      ;;
  esac
  if (is_windows); then
    if $is_static; then
      echo "$2.lib"
    else
      echo "$2.dll"
    fi
  elif (is_linux); then
    if $is_static; then
      echo "lib$2.a"
    else
      echo "lib$2.so"
    fi
  elif (is_macos); then
    if $is_static; then
      echo "lib$2.a"
    else
      echo "lib$2.dylib"
    fi
  else
    echo "Unknown OS: $(uname -s)" >&2
    exit 1
  fi
}

import() {
  local is_import=true
  local file_name=$1
  local found_from=false
  local remote_source=''
  local internal_source=''
  local content=''

  for arg in "$@"; do
    if $is_import; then
      is_import=false
    elif [[ "$arg" == from ]]; then
      found_from=true
    elif $found_from; then
      remote_source="$arg"
      break
    else
      echo "Invalid argument: $arg" >&2
      return 1
    fi
  done

  if [[ -z "$remote_source" ]] && $found_from; then
    echo "No remote source provided for import $file_name" >&2
    return 1
  fi

  if [[ -z "$file_name" ]]; then
    echo "No file name provided for import" >&2
    return 1
  fi

  if [[ ! -f "$file_name" ]] && ! $found_from; then
    echo "Failed to import $file_name, file not found" >&2
    return 1
  fi

  if $found_from; then
    internal_source="$remote_source"
    internal_source="${internal_source%/}"
    internal_source="$internal_source/$file_name"
    normalized_source="${remote_source#http://}"

    normalized_source="${normalized_source#https://}"
    if [[ "$normalized_source" == github.com/* ]]; then
      temp_remote="${normalized_source/github.com\//}"
      temp_remote="${temp_remote%.git}"
      repo_owner="${temp_remote%%/*}"
      rest="${temp_remote#*/}"
      repo_name="${rest%%/*}"
      repo_path="${rest#*/}"
      repo_path="${repo_path%/}"
      if [[ "$rest" == "$repo_name" ]]; then
        repo_path=""
      fi
      remote_source="github.com/$repo_owner/$repo_name"
      internal_source="https://raw.githubusercontent.com/$repo_owner/$repo_name/master"
      if [[ -n "$repo_path" ]]; then
        remote_source="$remote_source/$repo_path"
        internal_source="$internal_source/$repo_path"
      fi
      internal_source="$internal_source/$file_name"
    fi

    response=$(curl -L -s -w "%{http_code}" "$internal_source")
    http_code="${response: -3}"
    content="${response:0:${#response}-3}"

    if [[ "$http_code" -ge 400 ]]; then
      echo "Failed to import $file_name from $remote_source, Server returned $http_code" >&2
      return 1
    elif [[ -z "$content" ]]; then
      echo "Failed to import $file_name from $remote_source" >&2
      return 1
    fi
  else
    content=$(<"$file_name")
  fi

  if [[ "$file_name" == *.properties ]]; then
    if [[ -z "$LIBRARY_VERSIONS_INDEX" ]]; then
      LIBRARY_VERSIONS_INDEX="$content"
    else
      LIBRARY_VERSIONS_INDEX=$(echo -e "$LIBRARY_VERSIONS_INDEX\n$content" | awk '!seen[$0]++')
    fi
  elif [[ "$file_name" == *.sh ]]; then
    source /dev/stdin <<< "$content"
  else
    echo "Unknown import file type: $file_name" >&2
    return 1
  fi
}

get_version() {
    grep "^$1=" <<< "$LIBRARY_VERSIONS_INDEX" | cut -d '=' -f2
}

is_windows() {
  case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*)
      return 0
      ;;
  esac
  return 1
}

is_linux() {
  case "$(uname -s)" in
    Linux)
      return 0
      ;;
  esac
  return 1
}

is_macos() {
  case "$(uname -s)" in
    Darwin)
      return 0
      ;;
  esac
  return 1
}

get_vs_edition() {
    local VS_YEAR VS_EDITION year dir
    local VS_BASE_PATH="$1"

    for dir in "$VS_BASE_PATH"/*; do
        [[ -d "$dir" ]] || continue
        year="${dir##*/}"
        if [[ "$year" =~ ^[0-9]{4}$ ]]; then
            if [[ -z "$VS_YEAR" || "$year" -gt "$VS_YEAR" ]]; then
                VS_YEAR="$year"
            fi
        fi
    done

    local VS_BASE_PATH="$VS_BASE_PATH/$VS_YEAR"

    for edition in Enterprise Professional Community; do
        if [[ -d "$VS_BASE_PATH/$edition" ]]; then
            VS_EDITION="$edition"
            break
        fi
    done

    echo "$VS_YEAR/$VS_EDITION"
}

get_msvc_version() {
  local VS_BASE_PATH="$1"
  local VS_EDITION="$2"
  local msvc_dir version MSVC_VERSION

  for msvc_dir in "$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/"*; do
      [[ -d "$msvc_dir" ]] || continue
      version="${msvc_dir##*/}"
      if [[ "$version" =~ [0-9.]+ ]]; then
          if [[ -z "$MSVC_VERSION" || "$version" > "$MSVC_VERSION" ]]; then
              MSVC_VERSION="$version"
          fi
      fi
  done

  echo "$MSVC_VERSION"
}

get_windows_kits_version() {
  local WINDOWS_KITS_BASE_PATH="$1"
  local WINDOWS_KITS_VERSION=""
  local version dir

  for dir in "$WINDOWS_KITS_BASE_PATH/Include/"*; do
    [[ -d "$dir" ]] || continue
    version="${dir##*/}"
    if [[ "$version" =~ ^[0-9.]+$ ]]; then
      if [[ -z "$WINDOWS_KITS_VERSION" || "$version" > "$WINDOWS_KITS_VERSION" ]]; then
        WINDOWS_KITS_VERSION="$version"
      fi
    fi
  done

  echo "$WINDOWS_KITS_VERSION"
}

cpu_count() {
  if is_macos; then
    sysctl -n hw.logicalcpu
  else
    nproc
  fi
}

run() {
  local new_args=()
  local IGNORE_ERRORS=0
  local EXIT_CODE
  for arg in "$@"; do
    if [[ "$arg" == --ignore-errors* ]]; then
      IGNORE_ERRORS+=("${arg#--ignore-errors=}")
    else
      new_args+=("$arg")
    fi
  done
  echo ">>> ${new_args[*]}"
  "${new_args[@]}"
  EXIT_CODE=$?
  if [[ ! ${IGNORE_ERRORS[*]} =~ $EXIT_CODE ]]; then
      echo "Error while executing ${new_args[*]} $EXIT_CODE ${IGNORE_ERRORS[*]}" >&2
      exit $EXIT_CODE
  fi
}

require_venv() {
  if [ ! -d "venv" ]; then
      run python3 -m venv venv
  fi
  run source venv/bin/activate
  run python -m pip install meson ninja --root-user-action=ignore
}

configure_autogen() {
  if [ -f configure.ac ]; then
    if [ ! -f autogen.sh ]; then
      run autoreconf -ivf
    else
      run ./autogen.sh
    fi
  fi
}

require_rust() {
  curl https://sh.rustup.rs -sSf | sh -s -- -y
  source "$HOME"/.cargo/env
}

build_and_install() {
  local repo_url=$1
  local repo_name
  repo_name=$(basename "$repo_url" .git)
  local branch=$2
  local build_type=$3
  shift 3

  local update_submodules=false
  local skip_build=false
  local setup_commands=""
  local cleanup_commands=""
  local new_args=()

  for arg in "$@"; do
    if [[ "$arg" == "--update-submodules" ]]; then
      update_submodules=true
    elif [[ "$arg" == "--skip-build" ]]; then
      skip_build=true
    elif [[ "$arg" == --setup-commands* ]]; then
      setup_commands="${arg#--setup-commands=}"
    elif [[ "$arg" == --cleanup-commands* ]]; then
      cleanup_commands="${arg#--cleanup-commands=}"
    elif [[ "$arg" =~ --(windows|linux|macos).*=.* ]]; then
      platforms="${arg%%=*}"
      platforms="${platforms#--}"
      IFS='-' read -r -a platform_list <<< "$platforms"
      platform_supported=false
      for platform in "${platform_list[@]}"; do
        case "$platform" in
          windows) is_windows && platform_supported=true ;;
          linux) is_linux && platform_supported=true ;;
          macos) is_macos && platform_supported=true ;;
        esac
      done

      if $platform_supported; then
        read -r -a tmp <<< "${arg#--"$platforms"=}"
        new_args+=("${tmp[@]}")
      fi
    else
      new_args+=("$arg")
    fi
  done

  mkdir -p "$DEFAULT_BUILD_FOLDER"
  cd "$DEFAULT_BUILD_FOLDER" || exit 1

  if [ -n "$repo_url" ] && [ -n "$branch" ]; then
    if [ ! -d "$repo_name" ]; then
      run git clone "$repo_url" --branch "$branch" --depth 1
    fi
  fi

  cd "$repo_name" || exit 1

  if [[ "$update_submodules" == "true" ]]; then
    run git submodule update --init --recursive
  fi

  if [ -n "$setup_commands" ]; then
      local setup_commands_array
      eval "setup_commands_array=($setup_commands)"
      run "${setup_commands_array[@]}"
  fi

  case "$build_type" in
    autogen)
      echo "Running autogen.sh for $repo_name with options: ${new_args[*]}"
      run ./autogen.sh --prefix=/usr "${new_args[@]}"
      ;;
    autogen-static)
      echo "Running autogen.sh for $repo_name with static build options: ${new_args[*]}"
      run ./autogen.sh --enable-static --disable-shared --enable-pic "${new_args[@]}"
      ;;
    configure)
      echo "Running configure for $repo_name with options: ${new_args[*]}"
      configure_autogen
      run ./configure --prefix=/usr "${new_args[@]}"
      ;;
    configure-static)
      echo "Running configure for $repo_name with static build options: ${new_args[*]}"
      configure_autogen
      run ./configure --enable-static --disable-shared --enable-pic "${new_args[@]}"
      ;;
    meson)
      echo "Running meson for $repo_name with options: ${new_args[*]}"
      run python -m mesonbuild.mesonmain setup build --prefix=/usr "${new_args[@]}"
      ;;
    meson-static)
      echo "Running meson for $repo_name with static build options: ${new_args[*]}"
      run python -m mesonbuild.mesonmain setup build --libdir=lib --buildtype=release --default-library=static "${new_args[@]}"
      ;;
    cmake)
      echo "Running cmake with options: ${new_args[*]}"
      run cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/usr -G Ninja "${new_args[@]}"
      ;;
    make)
      ;;
    *)
      echo "Unknown build type: $build_type" >&2
      exit 1
      ;;
  esac

  if ! $skip_build; then
    if [[ "$build_type" == "autogen" || "$build_type" == "autogen-static" || "$build_type" == "configure" || "$build_type" == "configure-static" || "$build_type" == "make" ]]; then
        run make -j"$(cpu_count)" --ignore-errors=2
        run make install
      else
        run python -m ninja -C build
        run python -m ninja -C build install
      fi
  fi
  if [ -n "$cleanup_commands" ]; then
      local cleanup_commands_array
      eval "cleanup_commands_array=($cleanup_commands)"
      run "${cleanup_commands_array[@]}"
  fi
  cd ../.. || exit 1
}