#!/usr/bin/env bash

export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib/pkgconfig:$PKG_CONFIG_PATH
export ACLOCAL_PATH=/usr/share/aclocal

export OS_ARCH=""
RUN_UPDATES=false
RUN_NO_CACHE=false
: "${MAIN_SCRIPT:="$0"}"

for arg in "$@"; do
  if [[ $arg == --arch=* ]]; then
    export OS_ARCH="${arg#--arch=}"
  elif [[ $arg == --update ]]; then
    RUN_UPDATES=true
  elif [[ $arg == --no-cache ]]; then
    RUN_NO_CACHE=true
  fi
done

export BUILD_KIT_DIR
BUILD_KIT_DIR="$(pwd)/.buildkit"
export BUILD_KIT_CACHE="$BUILD_KIT_DIR/cache"
export DEFAULT_BUILD_FOLDER="$BUILD_KIT_DIR/build"
export VS_BASE_PATH="/c/Program Files/Microsoft Visual Studio"
export WINDOWS_KITS_BASE_PATH="/c/Program Files (x86)/Windows Kits/10"

mkdir -p "$BUILD_KIT_DIR"

try_setup_msvc() {
  if (is_windows); then
    VS_EDITION="$(get_vs_edition "$VS_BASE_PATH")"
    MSVC_VERSION="$(get_msvc_version "$VS_BASE_PATH" "$VS_EDITION")"
    WINDOWS_KITS_VERSION="$(get_windows_kits_version "$WINDOWS_KITS_BASE_PATH")"

    export PATH="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/bin/Hostx64/x64:$PATH"
    export LIB="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/lib/x64:$WINDOWS_KITS_BASE_PATH/Lib/$WINDOWS_KITS_VERSION/um/x64:$WINDOWS_KITS_BASE_PATH/Lib/$WINDOWS_KITS_VERSION/ucrt/x64"
    export INCLUDE="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/include:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/ucrt:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/um:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/shared"
    echo "[info] Correctly set env vars for Visual Studio $VS_EDITION, MSVC $MSVC_VERSION and Windows Kits $WINDOWS_KITS_VERSION" >&2
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
      echo "[error] Unknown library type: $1" >&2
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
    echo "[error] Unknown OS: $(uname -s)" >&2
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
      echo "[error] Invalid argument: $arg" >&2
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
      remote_source="github.com/$repo_owner/$repo_name"
      internal_source="https://raw.githubusercontent.com/$repo_owner/$repo_name/master/$file_name"
    fi

    response=$(curl -L -s -w "%{http_code}" "$internal_source")
    http_code="${response: -3}"
    content="${response:0:${#response}-3}"

    if [[ "$http_code" -ge 400 ]]; then
      echo "[error] Failed to import: $file_name" >&2
      echo "        source returned HTTP $http_code ($remote_source)" >&2
      exit 1
    elif [[ -z "$content" ]]; then
      echo "[error] Failed to import: $file_name" >&2
      echo "        empty content received from $remote_source" >&2
      exit 1
    fi
  else
    content=$(<"$file_name")
  fi

  if [[ "$file_name" == *.properties ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        raw_key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value//$'\r'/}"
         if [[ "$raw_key" =~ \.git$ ]]; then
           raw_key="${raw_key%.git}"
           echo "[warn] Trailing '.git' suffix detected in $raw_key" >&2
           echo "       This suffix is not required for the import" >&2
         fi
        if [[ ! "$raw_key" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
          echo "[error] Invalid import: $raw_key" >&2
          echo "        invalid characters in import declaration" >&2
          exit 1
        fi
        if [[ "$value" =~ ^\$ ]]; then
          var_ref="${value^^}"
          var_ref="${var_ref//-/_}"
          var_ref="LIB_${var_ref#\$}_VERSION"
          var_ref="${!var_ref}"
          if [[ -n "$var_ref" ]]; then
            value="$var_ref"
          else
            echo "[error] Invalid import: $raw_key" >&2
            echo "        invalid import reference in import declaration" >&2
            exit 1
          fi
        fi
        key=$(basename "$raw_key")
        key="${key^^}"
        key="${key//-/_}"
        version_var="LIB_${key}_VERSION"
        source_var="LIB_${key}_SOURCE"
        if [[ -n "${!version_var}" ]]; then
          echo "[warn] version for $raw_key already set" >&2
          echo "       previous value  : ${!version_var}" >&2
          echo "       declared at     : ${!source_var}" >&2
          echo "       overriding with : $value" >&2
          echo "       imported from   : $remote_source/$file_name" >&2
        fi
        if [[ ! "$raw_key" =~ ^(gitlab|github)\.com/ && ! "$raw_key" =~ ^bitbucket\.org/ ]]; then
          echo "[error] Invalid import: $raw_key" >&2
          echo "        not an accepted source (only \"gitlab.com\", \"github.com\" or \"bitbucket.org\" allowed)" >&2
          exit 1
        fi
        prefix=$(find_prefix_tag "$raw_key" "$value")
        ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
          exit 1
        fi
        export "$version_var=$value"
        export "$source_var=$remote_source/$file_name"
        export "LIB_${key}_GIT=$raw_key"
        export "LIB_${key}_PREFIX=$prefix"
      fi
    done <<< "$content"
  elif [[ "$file_name" == *.sh || "$file_name" == *.env ]]; then
    source /dev/stdin <<< "$content"
  else
    echo "[error] Unknown import file type: $file_name" >&2
    exit 1
  fi

  local caller_file="${BASH_SOURCE[1]}"
  local caller_line="${BASH_LINENO[0]}"
  local last_line
  if [[ "$caller_file" != "$MAIN_SCRIPT" ]]; then
      return
  fi
  last_line=$(
    grep -n -E '^[[:space:]]*import\b' "$caller_file" \
    | cut -d: -f1 \
    | sort -n \
    | tail -n1
  )
  if [[ "$caller_line" -eq "$last_line" ]] && $RUN_UPDATES; then
      update_dependencies
      exit 0
  fi
}

update_dependencies() {
  for var in $(compgen -v | grep 'LIB_.*_SOURCE$'); do
    local source_var="$var"
    local version_var="${var/_SOURCE/_VERSION}"
    local git_var="${var/_SOURCE/_GIT}"

    if [[ -z "${!source_var}" ]] || [[ ! "${!source_var}" =~ ^/ ]]; then
      continue
    fi

    echo "[info] Checking for updates in ${!git_var}" >&2
    latest_version="$(find_latest_version "${!git_var}" "${!version_var}")"

    if [[ -z "$latest_version" ]]; then
      echo "[error] Failed to find latest version for ${!git_var}" >&2
      exit 1
    fi

    if [[ "$latest_version" == "${!version_var}" ]]; then
      echo "[info] ${!git_var} is up to date" >&2
      continue
    fi

    echo "[info] ${!git_var} is outdated" >&2
    echo "       Current version: ${!version_var}" >&2
    echo "       Updating to $latest_version" >&2

    sed -i "s|^${!git_var}=.*|${!git_var}=$latest_version|" "${!source_var/\//}"
    echo "[info] Updated ${!git_var} to $latest_version" >&2
  done
}

git_api_request() {
  local repo="$1"
  local url_api
  local page=1

  git_loc="${repo/github.com\//}"
  git_loc="${git_loc/gitlab.com\//}"
  git_loc="${git_loc/bitbucket.org\//}"
  headers=()

  if [[ "$repo" =~ ^gitlab.com* ]]; then
    base_url="https://gitlab.com/api/v4/projects/$(url_encode "$git_loc")/repository/tags?per_page=100&page="
  elif [[ "$repo" =~ ^bitbucket.org.* ]]; then
    base_url="https://api.bitbucket.org/2.0/repositories/${git_loc}/refs/tags?page="
  else
    base_url="https://api.github.com/repos/${git_loc}/tags?per_page=100&page="
    [[ -n "$GITHUB_TOKEN" ]] && headers+=(-H "Authorization: token $GITHUB_TOKEN")
  fi

  while true; do
    url_api="${base_url}${page}"
    response=$(curl "${headers[@]}" -L -s -w "%{http_code}" "$url_api")
    http_code="${response: -3}"
    content="${response:0:${#response}-3}"

    if [[ "$http_code" -ge 400 ]]; then
      return 1
    fi

    echo "$content" | grep -oP '"name":\s*"\K[^"]+'

    if [[ "$repo" =~ ^gitlab.com* ]]; then
      next_page=$(echo "$response" | grep -i "X-Next-Page" | awk '{print $2}')
    elif [[ "$repo" =~ ^bitbucket.org* ]]; then
      next_page=$(echo "$response" | grep -o '"next": *"[^"]*"' | sed -E 's/.*"next": *"([^"]+)".*/\1/')
      if [[ -n "$next_page" ]]; then
        next_page=1
      fi
    else
      length=$(echo "$content" | tr -d '\n' | grep -oP '{.*?}' | wc -l)
      if [[ "$length" -eq 100 ]]; then
        next_page=1
      else
        next_page=0
      fi
    fi

    if [[ "$next_page" -eq 0 ]]; then
      break
    fi
    page=$((page + 1))
  done
}


write_cache_prefix() {
  local repo="$1"
  local prefix="$2"
  if $RUN_NO_CACHE; then
    return
  fi
  if [[ -f "$BUILD_KIT_CACHE" ]] && grep -q "^$repo=" "$BUILD_KIT_CACHE"; then
    sed -i "s|^$repo=.*|$repo=$prefix|" "$BUILD_KIT_CACHE"
  else
    echo "$repo=$prefix" >> "$BUILD_KIT_CACHE"
  fi
}

load_cache_prefix() {
  local repo="$1"
  if [[ -f "$BUILD_KIT_CACHE" ]] && ! $RUN_NO_CACHE; then
    local cached_prefix
     if grep -q "^$repo=" "$BUILD_KIT_CACHE"; then
       cached_prefix=$(grep "^$repo=" "$BUILD_KIT_CACHE" | cut -d= -f2-)
       echo "$cached_prefix"
       return 0
     fi
  fi
  return 1
}

retrieve_prefix() {
  local tags="$1"
  local base_version="$2"
  matching_tags=$(echo "$tags" | grep "$base_version" | head -n 1)
  if [[ -z "$matching_tags" ]]; then
    return 1
  fi
  echo "$matching_tags" | sed -E 's/[0-9]+\.[0-9]+.*//'
}

find_prefix_tag() {
  local repo="$1"
  local base_version="$2"

  prefix=$(load_cache_prefix "$repo")
  ret_code=$?
  if [[ $ret_code -eq 0 ]]; then
    echo "$prefix"
    return 0
  fi
  echo "[info] Importing $repo" >&2

  tags=$(git_api_request "$repo")
  prefix=$(retrieve_prefix "$tags" "$base_version")
  ret_code=$?
  if [[ $ret_code -ne 0 ]]; then
    echo "[error] Failed to find prefix for $repo" >&2
    return 1
  fi

  write_cache_prefix "$repo" "$prefix"
  echo "$prefix"
}

find_latest_version() {
  local repo="$1"
  local base_version="$2"
  local void_prefix
  local suffix

  tags=$(git_api_request "$repo")
  prefix=$(load_cache_prefix "$repo")
  if [[ -z "$prefix" ]]; then
    prefix=$(retrieve_prefix "$tags" "$base_version")
    write_cache_prefix "$repo" "$prefix"
  fi

  if [[ "$base_version" =~ ^[0-9] ]]; then
    void_prefix="[0-9]"
  fi

  if [[ "$base_version" =~ [0-9]$ ]]; then
    suffix=".*[0-9]$"
  else
    suffix=".*-$(echo "$base_version" | sed -E 's/.*[0-9]+-//')$"
  fi

  echo "$tags" \
    | grep "^$prefix$void_prefix$suffix" \
    | while read -r tag; do
        ver="${tag/$prefix/}"
        if [[ "$ver" == "$base_version" || "$ver" > "$base_version" ]] && [[ ! "$ver" =~ -rc[0-9]+$ ]]; then
          echo "$ver"
        fi
      done \
    | sort -V \
    | awk 'END { print $1 }'
}

url_encode() {
  local string="$1"
  local strlen=${#string}
  local encoded=""
  for (( pos=0 ; pos<strlen ; pos++ )); do
    c=${string:$pos:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"
         encoded+="$hex"
    esac
  done
  echo "$encoded"
}

dependency_version() {
  local key="$1"
  key="${key^^}"
  key="${key//-/_}"
  local tag_prefix="LIB_${key}_PREFIX"
  local version_var="LIB_${key}_VERSION"
  echo "${!tag_prefix}${!version_var}"
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
  echo ">>> ${new_args[*]}" >&2
  "${new_args[@]}"
  EXIT_CODE=$?
  if [[ ! ${IGNORE_ERRORS[*]} =~ $EXIT_CODE ]]; then
      echo "[error] Error while executing ${new_args[*]} $EXIT_CODE ${IGNORE_ERRORS[*]}" >&2
      exit $EXIT_CODE
  fi
}

require() {
  case "$1" in
    rust)
      if [ ! -d "$HOME/.cargo" ]; then
        run curl https://sh.rustup.rs -sSf | sh -s -- -y
      fi
      run source "$HOME"/.cargo/env
      ;;
    venv)
      if [ ! -d "venv" ]; then
        run python3 -m venv venv
      fi
      run source venv/bin/activate
      run python -m pip install meson ninja --root-user-action=ignore
      ;;
    *)
      echo "[error] Unknown requirement: $1" >&2
      exit 1
      ;;
  esac
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

build_and_install() {
  local repo_url=$1
  if [[ "$repo_url" =~ ^http(s)* ]]; then
    local branch=$2
    local build_type=$3
    shift 3
  else
    local lib_name="$1"
    lib_name="${lib_name^^}"
    lib_name="${lib_name//-/_}"
    local git_var="LIB_${lib_name}_GIT"
    local tag_prefix="LIB_${lib_name}_PREFIX"
    local version_var="LIB_${lib_name}_VERSION"
    repo_url="https://${!git_var}.git"
    if [[ -z "${!git_var}" ]]; then
      echo "[error] No dependency found for $1" >&2
      exit 1
    fi
    local branch="${!tag_prefix}${!version_var}"
    local build_type=$2
    shift 2
  fi

  local repo_name
  repo_name=$(basename "$repo_url" .git)

  local update_submodules=false
  local skip_build=false
  local setup_commands=""
  local cleanup_commands=""
  local build_dir=""
  local new_args=()
  current_dir="$(pwd)"

  for arg in "$@"; do
    if [[ "$arg" == "--update-submodules" ]]; then
      update_submodules=true
    elif [[ "$arg" == "--skip-build" ]]; then
      skip_build=true
    elif [[ "$arg" == --setup-commands* ]]; then
      setup_commands="${arg#--setup-commands=}"
    elif [[ "$arg" == --cleanup-commands* ]]; then
      cleanup_commands="${arg#--cleanup-commands=}"
    elif [[ "$arg" == --prefix=* || "$arg" == -DCMAKE_INSTALL_PREFIX=* ]];then
      build_dir="${arg#*=}"
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
      if needs_quotes "$arg"; then
        new_args+=("\"$arg\"")
      else
        new_args+=("$arg")
      fi
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

  if [[ $build_type =~ -static$ ]]; then
    is_static=true
  else
    is_static=false
  fi

  if [ -z "$build_dir" ]; then
    if $is_static; then
      build_dir="$DEFAULT_BUILD_FOLDER/$repo_name/build"
    else
      build_dir="/usr"
    fi
  fi

  case "$build_type" in
    autogen|autogen-static)
      if $is_static; then
        new_args+=("--enable-static" "--disable-shared" "--enable-pic")
      fi
      echo "[info] Running autogen.sh for $repo_name with options: ${new_args[*]}" >&2
      run ./autogen.sh --prefix="\"$build_dir\"" "${new_args[@]}"
      ;;
    configure|configure-static)
      if $is_static; then
        new_args+=("--enable-static" "--disable-shared" "--enable-pic")
      fi
      echo "[info] Running configure for $repo_name with options: ${new_args[*]}" >&2
      configure_autogen
      run ./configure --prefix="\"$build_dir\"" "${new_args[@]}"
      ;;
    meson|meson-static)
      if $is_static; then
        new_args+=("--default-library=static")
      fi
      echo "[info] Running meson for $repo_name with options: ${new_args[*]}" >&2
      run python -m mesonbuild.mesonmain setup build --prefix="\"$build_dir\"" --libdir=lib --buildtype=release "${new_args[@]}"
      ;;
    cmake|cmake-static)
      build_tool=$(process_args get "-G" "${new_args[@]}")
      build_tool="${build_tool%\"}"
      build_tool="${build_tool#\"}"
      cmake_options=$(process_args filter "-G" "${new_args[@]}")
      cmake_options=$(process_args filter "-DBUILD_SHARED_LIBS" "${cmake_options[@]}")
      if [[ -z "$build_tool" ]]; then
        build_tool="Unix Makefiles"
      fi
      if $is_static; then
        cmake_options+=("-DBUILD_SHARED_LIBS=OFF")
      fi
      echo "[info] Running cmake with options: ${new_args[*]}" >&2
      run cmake -S . -B build -DCMAKE_INSTALL_PREFIX="\"$build_dir\"" -G "$build_tool" "${cmake_options[@]}"
      ;;
    make)
      ;;
    *)
      echo "[error] Unknown build type: $build_type" >&2
      exit 1
      ;;
  esac

  if ! $skip_build; then
    if [[ "$build_type" == "autogen" || "$build_type" == "autogen-static" || "$build_type" == "configure" || "$build_type" == "configure-static" || "$build_type" == "make" || "$build_tool" == "Unix Makefiles" ]]; then
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
  cd "$current_dir" || exit 1
}

needs_quotes() {
  local val="$1"
  [[ "$val" =~ [[:space:]\$\&\|\>\<\;\(\)\*\'\"] ]]
}

process_args() {
  local mode="$1"; local arg="$2"; shift 2
  local -a list=( "$@" ) new_list=()
  local i=0 n=${#list[@]}

  while (( i < n )); do
    local v="${list[i]}"
    if [[ "$v" == "$arg" ]]; then
      if [[ "$mode" == "get" ]]; then
        echo "${list[i+1]}"
        return 0
      else
        (( i += 2 ))
        continue
      fi
    elif [[ "$v" == "$arg="* ]]; then
      if [[ "$mode" == "get" ]]; then
        echo "${v#*=}"
        return 0
      else
        (( i++ ))
        continue
      fi
    fi
    new_list+=( "$v" )
    (( i++ ))
  done

  if [[ "$mode" == "filter" ]]; then
    echo "${new_list[@]}"
  else
    return 1
  fi
}