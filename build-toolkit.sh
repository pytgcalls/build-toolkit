 #!/usr/bin/env bash

 if [[ -z "$BASH_VERSION" ]]; then
   echo "[error] This script must be run with Bash (BASH_VERSION is not set)" >&2
   exit 1
 fi

 if [[ "$(uname -s)" == "Darwin" ]]; then
   if (( BASH_VERSINFO[0] < 3 && BASH_VERSINFO[1] < 2 )); then
     echo "[error] Bash 3.2 or newer is required (found $BASH_VERSION)" >&2
     exit 1
   fi
 else
   if (( BASH_VERSINFO[0] < 4 )); then
     echo "[error] Bash 4.0 or newer is required (found $BASH_VERSION)" >&2
     exit 1
   fi
 fi

 append_pkg_config_path() {
   local new_path="$1"
   if [[ ":$PKG_CONFIG_PATH:" != *":$new_path:"* ]]; then
     export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$new_path"
   fi
 }

 append_pkg_config_path /usr/local/lib/pkgconfig
 append_pkg_config_path /usr/local/share/pkgconfig
 append_pkg_config_path /usr/lib/pkgconfig
 export ACLOCAL_PATH=/usr/share/aclocal

 RUN_UPDATES=false
 RUN_NO_CACHE=false
 export OS_NAME
 OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
 : "${MAIN_SCRIPT:="$0"}"

 for arg in "$@"; do
   if [[ $arg == --update ]]; then
     RUN_UPDATES=true
   elif [[ $arg == --no-cache ]]; then
     RUN_NO_CACHE=true
   elif [[ $arg == --platform=* ]]; then
     export OS_NAME="${arg#--platform=}"
   fi
 done

 export BUILD_KIT_DIR
 BUILD_KIT_DIR="$(pwd)/.buildkit"
 export DEFAULT_BUILD_FOLDER="$BUILD_KIT_DIR/build"
 export DEFAULT_TOOLS_FOLDER="$BUILD_KIT_DIR/tools"

 export CACHE_FILE
 if $RUN_NO_CACHE; then
   CACHE_FILE="$(mktemp)"
   trap '[[ -f "$CACHE_FILE" ]] && rm -f "$CACHE_FILE"' EXIT
 else
   CACHE_FILE="$BUILD_KIT_DIR/fox.cache"
 fi

 export VS_BASE_PATH="/c/Program Files/Microsoft Visual Studio"
 export WINDOWS_KITS_BASE_PATH="/c/Program Files (x86)/Windows Kits/10"

 mkdir -p "$BUILD_KIT_DIR"

 os_lib_format() {
   local is_static=false
   case "$1" in
     static)
       is_static=true
       ;;
     dynamic)
       is_static=false
       ;;
     *)
       echo "[error] Unknown library type: $1" >&2
       exit 1
       ;;
   esac

   lib_name="${2#lib}"
   lib_name="${lib_name%.a}"
   lib_name="${lib_name%.dylib}"
   lib_name="${lib_name%.dll}"
   lib_name="${lib_name%.so}"

   if is_windows; then
     if $is_static; then
       echo "$lib_name.lib"
     else
       echo "$lib_name.dll"
     fi
   elif is_linux || is_android; then
     if $is_static; then
       echo "lib$lib_name.a"
     else
       echo "lib$lib_name.so"
     fi
   elif is_macos; then
     if $is_static; then
       echo "lib$lib_name.a"
     else
       echo "lib$lib_name.dylib"
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

   local allow_file_detection=true
   if $found_from; then
     case "$remote_source" in
     python*)
       if ! "$remote_source" -m pip show "$file_name" &>/dev/null; then
         "$remote_source" -m pip install "$file_name" -U
       fi
       allow_file_detection=false
       ;;
     rust)
       if ! cargo install --list | grep -q "^$file_name v"; then
         cargo install "$file_name"
       fi
       allow_file_detection=false
       ;;
     *)
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
       ;;
     esac
   else
     content=$(<"$file_name")
   fi

   if $allow_file_detection; then
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
           local is_updatable=true
           if [[ "$value" =~ ^\$ ]]; then
             var_ref="$(echo "$value" | tr '[:lower:]' '[:upper:]')"
             var_ref="${var_ref//-/_}"
             var_ref="LIB_${var_ref#\$}_VERSION"
             var_ref="${!var_ref}"
             if [[ -n "$var_ref" ]]; then
               value="$var_ref"
               is_updatable=false
             else
               echo "[error] Invalid import: $raw_key" >&2
               echo "        invalid import reference in import declaration" >&2
               exit 1
             fi
           fi
           key=$(basename "$raw_key")
           key="$(echo "$key" | tr '[:lower:]' '[:upper:]')"
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
           pkg_config_path="$(read_cache "lib" "$raw_key")"
           if [[ -n "$pkg_config_path" ]]; then
             append_pkg_config_path "$pkg_config_path/lib/pkgconfig"
           fi
           export "$version_var=$value"
           export "$source_var=$remote_source/$file_name"
           export "LIB_${key}_GIT=$raw_key"
           export "LIB_${key}_PREFIX=$prefix"
           if $is_updatable; then
             export "LIB_${key}_UPDATABLE=true"
           fi
         fi
       done <<< "$content"
     elif [[ "$file_name" == *.sh || "$file_name" == *.env ]]; then
       source /dev/stdin <<< "$content"
     else
       echo "[error] Unknown import file type: $file_name" >&2
       exit 1
     fi
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
  for var in $(compgen -v | grep 'LIB_.*_UPDATABLE$'); do
    local source_var="${var/_UPDATABLE/_SOURCE}"
    local version_var="${var/_UPDATABLE/_VERSION}"
    local rgx
    version_var="${!version_var}"
    local git_var="${var/_UPDATABLE/_GIT}"
    git_var="${!git_var}"

    if [[ -z "${!source_var}" ]] || [[ ! "${!source_var}" =~ ^/ ]]; then
      continue
    fi

    echo "[info] Checking for updates in $git_var" >&2
    latest_version="$(find_latest_version "$git_var" "$version_var")"

    if [[ -z "$latest_version" ]]; then
      echo "[error] Failed to find latest version for $git_var" >&2
      exit 1
    fi

    if [[ "$latest_version" == "$version_var" ]]; then
      echo "[info] $git_var is up to date" >&2
      continue
    fi

    echo "[info] $git_var is outdated" >&2
    echo "       Current version: $version_var" >&2
    echo "       Updating to $latest_version" >&2

    source_var="${!source_var/\//}"
    rgx="s|^$git_var=.*|$git_var=$latest_version|"
    if is_macos; then
      sed -i "" "$rgx" "$source_var"
    else
      sed -i "$rgx" "$source_var"
    fi
    echo "[info] Updated $git_var to $latest_version" >&2
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

    echo "$content" | grep -o '"name":\s*"[^\"]*"' | perl -nle 'print $1 if /"name":\s*"([^"]+)"/'

    if [[ "$repo" =~ ^gitlab.com* ]]; then
      next_page=$(echo "$response" | grep -i "X-Next-Page" | awk '{print $2}')
    elif [[ "$repo" =~ ^bitbucket.org* ]]; then
      next_page=$(echo "$response" | grep -o '"next": *"[^"]*"' | sed -E 's/.*"next": *"([^"]+)".*/\1/')
      if [[ -n "$next_page" ]]; then
        next_page=1
      fi
    else
      length=$(echo "$content" | tr -d '\n' | grep -o '{[^}]*}' | wc -l)
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

write_cache() {
  local index_name="$1"
  local repo="$2"
  local value="$3"
  local rgx=""
  if [[ -f "$CACHE_FILE" ]] && grep -q "^$index_name:$repo=" "$CACHE_FILE"; then
    rgx="s|^$index_name:$repo=.*|$index_name:$repo=$value|"
    if is_macos; then
      sed -i "" "$rgx" "$CACHE_FILE"
    else
      sed -i "$rgx" "$CACHE_FILE"
    fi
  else
    echo "$index_name:$repo=$value" >> "$CACHE_FILE"
  fi
}

read_cache() {
  local index_name="$1"
  local repo="$2"
  rgx="^$index_name:$repo="
  if [[ -f "$CACHE_FILE" ]]; then
    if grep -q "$rgx" "$CACHE_FILE"; then
      grep "$rgx" "$CACHE_FILE" | cut -d= -f2-
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
  echo "$matching_tags" | sed -E 's/[0-9]+(\.|_)[0-9]+.*//'
}

identify_separator() {
  local tags="$1"
  local base_version="$2"
  matching_tags=$(echo "$tags" | grep "$base_version" | head -n 1)
  if [[ -z "$matching_tags" ]]; then
    return 1
  fi
  if [[ "$matching_tags" =~ [0-9]+(\.|_)[0-9]+ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

apply_separator() {
  local version="$1"
  local separator="$2"
  echo "$version" | sed -E "s/([0-9]+)(\.|_)/\1$separator/g"
}

find_prefix_tag() {
  local repo="$1"
  local base_version="$2"

  index_cache=$(read_cache "prefix" "$repo")
  ret_code=$?
  if [[ $ret_code -eq 0 ]]; then
    echo "${index_cache%%;*}"
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
  separator=$(identify_separator "$tags" "$base_version")

  write_cache "prefix" "$repo" "$prefix;$separator"
  echo "$prefix"
}

find_latest_version() {
  local repo="$1"
  local base_version="$2"
  local void_prefix
  local suffix

  tags=$(git_api_request "$repo")
  index_cache=$(read_cache "prefix" "$repo")
  if [[ -z "$index_cache" ]]; then
    prefix=$(retrieve_prefix "$tags" "$base_version")
    separator=$(identify_separator "$tags" "$base_version")
    write_cache "prefix" "$repo" "$prefix;$separator"
  fi
  prefix="${index_cache%%;*}"
  separator="${index_cache#*;}"

  if [[ "$base_version" =~ ^[0-9] ]]; then
    void_prefix="[0-9]"
  fi

  if [[ "$base_version" =~ [0-9]$ ]]; then
    suffix=".*[0-9]$"
  else
    suffix=".*-$(echo "$base_version" | sed -E 's/.*[0-9]+-//')$"
  fi
  base_version="$(apply_separator "$base_version" "$separator")"
  pattern_version="^$(echo "$base_version" | perl -pe 's/\d+/\\d+/g; s/\./\\./g; s/\//\\\//g;')$"

  apply_separator "$(echo "$tags" \
    | grep "^$prefix$void_prefix$suffix" \
    | while read -r tag; do
        ver="${tag/$prefix/}"
        if [[ "$ver" == "$base_version" || "$ver" > "$base_version" ]] && \
            echo "$ver" | perl -ne 'exit 1 unless /'"$pattern_version"'/'; then
          echo "$ver"
        fi
      done \
    | sort -V \
    | awk 'END { print $1 }')" "."
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
  key="$(echo "$key" | tr '[:lower:]' '[:upper:]')"
  key="${key//-/_}"
  local tag_prefix="LIB_${key}_PREFIX"
  local version_var="LIB_${key}_VERSION"
  echo "${!tag_prefix}${!version_var}"
}

is_windows() {
  case "$OS_NAME" in
    cygwin*|mingw*|msys*|windows)
      return 0
      ;;
  esac
  return 1
}

is_linux() {
  case "$OS_NAME" in
    linux)
      return 0
      ;;
  esac
  return 1
}

is_macos() {
  case "$OS_NAME" in
    darwin)
      return 0
      ;;
  esac
  return 1
}

is_android() {
  case "$OS_NAME" in
    android)
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
  echo ">>> $(quote_args "${new_args[@]}")" >&2
  "${new_args[@]}"
  EXIT_CODE=$?
  if [[ ! ${IGNORE_ERRORS[*]} =~ $EXIT_CODE ]]; then
      echo "[error] Error while executing $(quote_args "${new_args[@]}")" >&2
      exit $EXIT_CODE
  fi
}

require() {
  case "$1" in
    rust)
      if [ ! -d "$HOME/.cargo" ]; then
        run curl https://sh.rustup.rs -sSf | sh -s -- -y
      fi
      source "$HOME"/.cargo/env
      ;;
    venv)
      if [ ! -d "venv" ]; then
        run python3 -m venv venv
      fi
      source venv/bin/activate
      ;;
    xcode)
      if is_macos; then
        export MACOSX_DEPLOYMENT_TARGET=12.0
      fi
      ;;
    msvc)
      if (is_windows); then
        VS_EDITION="$(get_vs_edition "$VS_BASE_PATH")"
        MSVC_VERSION="$(get_msvc_version "$VS_BASE_PATH" "$VS_EDITION")"
        WINDOWS_KITS_VERSION="$(get_windows_kits_version "$WINDOWS_KITS_BASE_PATH")"

        export PATH="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/bin/Hostx64/x64:$PATH"
        export LIB="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/lib/x64:$WINDOWS_KITS_BASE_PATH/Lib/$WINDOWS_KITS_VERSION/um/x64:$WINDOWS_KITS_BASE_PATH/Lib/$WINDOWS_KITS_VERSION/ucrt/x64"
        export INCLUDE="$VS_BASE_PATH/$VS_EDITION/VC/Tools/MSVC/$MSVC_VERSION/include:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/ucrt:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/um:$WINDOWS_KITS_BASE_PATH/Include/$WINDOWS_KITS_VERSION/shared"
        echo "[info] Correctly set env vars for Visual Studio $VS_EDITION, MSVC $MSVC_VERSION and Windows Kits $WINDOWS_KITS_VERSION" >&2
      fi
      ;;
    ndk)
      if is_android; then
        if [[ "$ANDROID_NDK_ROOT" == "" ]]; then
          export ANDROID_API=21
          platform_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
          case "$platform_name" in
              cygwin*|mingw*|msys*)
                platform_name="windows"
                ;;
          esac
          mkdir -p "$DEFAULT_TOOLS_FOLDER"
          ndk_name="android-ndk-r26b"
          export ANDROID_NDK_ROOT="$DEFAULT_TOOLS_FOLDER/$ndk_name"
          if [ ! -d "$DEFAULT_TOOLS_FOLDER" ]; then
            run curl -L "https://dl.google.com/android/repository/$ndk_name-$platform_name.zip" -o "$DEFAULT_TOOLS_FOLDER/android-ndk.zip"
            run unzip -q "$DEFAULT_TOOLS_FOLDER/android-ndk.zip" -d "$DEFAULT_TOOLS_FOLDER"
            rm "$DEFAULT_TOOLS_FOLDER/android-ndk.zip"
          fi
        elif [[ ! -d "$ANDROID_NDK_ROOT" ]]; then
          echo "[error] ANDROID_NDK_ROOT is set but the directory does not exist" >&2
          exit 1
        fi
        export ANDROID_PREBUILT;
        ANDROID_PREBUILT="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
      fi
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
  local sub_path=""
  if [[ "$repo_url" =~ ^http(s)* ]]; then
    local branch=$2
    local build_type=$3
    shift 3
  else
    lib_name="${1%%/*}"
    lib_name="$(echo "$lib_name" | tr '[:lower:]' '[:upper:]')"
    lib_name="${lib_name//-/_}"
    [[ "$1" == */* ]] && sub_path="${1#*/}"
    local git_var="LIB_${lib_name}_GIT"
    git_var="${!git_var}"
    local tag_prefix="LIB_${lib_name}_PREFIX"
    local version_var="LIB_${lib_name}_VERSION"
    version_var="${!version_var}"
    separator=$(read_cache "prefix" "$git_var")
    separator="${separator#*;}"
    version_var=$(apply_separator "$version_var" "$separator")
    ret_code=$?
    if [[ $ret_code -eq 1 ]]; then
      echo "[error] Failed to find prefix for $git_var" >&2
      exit 1
    fi
    repo_url="https://$git_var.git"
    if [[ -z "$git_var" ]]; then
      echo "[error] No dependency found for ${1%%/*}" >&2
      exit 1
    fi
    local branch="${!tag_prefix}$version_var"
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
  local build_tool=""
  local dir_after_build=""
  local new_args=()
  local executable_command=()
  local last_branch=""
  local pl_args=""
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
    elif [[ "$arg" =~ --(windows|linux|macos|android).*=.* ]]; then
      platforms="${arg%%=*}"
      platforms="${platforms#--}"
      IFS='-' read -r -a platform_list <<< "$platforms"
      platform_supported=false
      for platform in "${platform_list[@]}"; do
        case "$platform" in
          windows) is_windows && platform_supported=true ;;
          linux) is_linux && platform_supported=true ;;
          macos) is_macos && platform_supported=true ;;
          android) is_android && platform_supported=true ;;
        esac
      done

      if $platform_supported; then
        pl_args="${arg#--"$platforms"=}"
        pl_args="${pl_args//\/ }"
        eval "new_args+=($pl_args)"
      fi
    else
      new_args+=("$arg")
    fi
  done

  mkdir -p "$DEFAULT_BUILD_FOLDER"
  cd "$DEFAULT_BUILD_FOLDER" || exit 1

  if [[ ! -d "$repo_name" ]]; then
    run git clone "$repo_url" --branch "$branch" --depth 1
    write_cache "last_branch" "$git_var" "$branch"
  fi

  cd "$repo_name" || exit 1

  last_branch="$(read_cache "last_branch" "$git_var")"
  if [[ "$branch" != "$last_branch" ]]; then
    run git fetch origin tag "$branch" --depth=1
    run git checkout "$branch"
    run git reset --hard
    run git clean -fdx
    write_cache "last_branch" "$git_var" "$branch"
  fi

  if [ -n "$sub_path" ]; then
    cd "$sub_path" || exit 1
  fi

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

  if $is_static; then
    write_cache "lib_kind" "$git_var" "static"
  else
    write_cache "lib_kind" "$git_var" "dynamic"
  fi
  write_cache "lib" "$git_var" "$build_dir"

  case "$build_type" in
    autogen|autogen-static)
      executable_command=("./autogen.sh")
      if $is_static; then
        new_args+=("--enable-static" "--disable-shared" "--enable-pic")
      fi
      new_args+=("--prefix=$build_dir")
      ;;
    configure|configure-static)
      executable_command=("./configure")
      if $is_static; then
        new_args+=("--enable-static" "--disable-shared" "--enable-pic")
      fi
      new_args+=("--prefix=$build_dir")
      ;;
    meson|meson-static)
      executable_command=(python -m mesonbuild.mesonmain setup --reconfigure build)
      if $is_static; then
        new_args+=("--default-library=static")
      fi
      new_args+=("--prefix=$build_dir")
      new_args+=("--libdir=lib")
      new_args+=("--buildtype=release")
      ;;
    cmake|cmake-static)
      executable_command=(cmake)
      build_tool=$(process_args get "-G" "${new_args[@]}")
      dir_after_build=$(process_args get "-B" "${new_args[@]}")
      tmp_args=()
      while IFS= read -r line; do
        tmp_args+=("$line")
      done < <(process_args filter "-G" "${new_args[@]}")
      new_args=("${tmp_args[@]}")
      tmp_args=()
      while IFS= read -r line; do
        tmp_args+=("$line")
      done < <(process_args filter "-B" "${new_args[@]}")
      new_args=("${tmp_args[@]}")
      tmp_args=()
      while IFS= read -r line; do
        tmp_args+=("$line")
      done < <(process_args filter "-DCMAKE_INSTALL_PREFIX" "${new_args[@]}")
      new_args=("${tmp_args[@]}")
      tmp_args=()
      while IFS= read -r line; do
        tmp_args+=("$line")
      done < <(process_args filter "-DBUILD_SHARED_LIBS" "${new_args[@]}")
      new_args=("${tmp_args[@]}")
      if [[ -z "$build_tool" ]]; then
        build_tool="Unix Makefiles"
      fi
      if [[ -z "$dir_after_build" ]]; then
        dir_after_build="build"
      fi
      new_args+=("-G" "$build_tool")
      new_args+=("-B" "$dir_after_build")
      if $is_static; then
        new_args+=("-DBUILD_SHARED_LIBS=OFF")
      fi
      new_args+=("-DCMAKE_INSTALL_PREFIX=$build_dir")
      ;;
    make)
      ;;
    *)
      echo "[error] Unknown build type: $build_type" >&2
      exit 1
      ;;
  esac
  merged_commands=("${executable_command[@]}" "${new_args[@]}")

  echo "[info] Running $build_type with options: $(quote_args "${new_args[@]}")" >&2
  case "$build_type" in
    configure|configure-static)
      configure_autogen
      ;;
  esac
  write_cache "lib_include" "$git_var" ";"
  if [[ -n "${merged_commands[*]}" ]]; then
    save_headers run "${merged_commands[@]}"
  fi

  if ! $skip_build; then
    if [[ -n "$dir_after_build" ]]; then
      cd "$dir_after_build" || exit 1
    fi
    if [[ "$build_type" == autogen* || "$build_type" == configure* || "$build_type" == "make" || "$build_tool" == "Unix Makefiles" ]]; then
      run make clean --ignore-errors=2
      save_headers run make -j"$(cpu_count)" --ignore-errors=2
      save_headers run make install
    elif [[ "$build_type" == meson* || "$build_tool" == "Ninja" ]]; then
      run python -m ninja -C build -t clean
      save_headers run python -m ninja -C build -j"$(cpu_count)"
      save_headers run python -m ninja -C build install
    elif [[ -n "$build_tool" ]]; then
      run cmake --build . --target clean --config Release
      save_headers run cmake --build . --config Release -j"$(cpu_count)"
      save_headers run cmake --install . --config Release
    else
      echo "[error] Unknown build tool: $build_tool" >&2
      exit 1
    fi
  fi
  if [ -n "$cleanup_commands" ]; then
      local cleanup_commands_array
      eval "cleanup_commands_array=($cleanup_commands)"
      run "${cleanup_commands_array[@]}"
  fi
  cd "$current_dir" || exit 1
  append_pkg_config_path "$build_dir/lib/pkgconfig"
}

save_headers() {
  tmp_before=$(mktemp)
  tmp_after=$(mktemp)
  touch "$tmp_before"
  "$@"
  touch "$tmp_after"
  if [[ -d "$build_dir/include" ]]; then
    local new_headers=()
    while IFS= read -r line; do
      new_headers+=("$line")
    done < <(find "$build_dir/include" -type f \( -name "*.h" -o -name "*.hpp" \) -cnewer "$tmp_before" ! -cnewer "$tmp_after" | sort -u)
    old_cache=$(read_cache "lib_include" "$git_var")
    IFS=';' read -r -a old_headers <<< "$old_cache"
    all_headers=("${old_headers[@]}" "${new_headers[@]}")
    local unique_headers=()
    while IFS= read -r line; do
      unique_headers+=("$line")
    done < <(printf "%s\n" "${all_headers[@]}" | awk 'NF' | sort -u)
    write_cache "lib_include" "$git_var" "$(printf "%s;" "${unique_headers[@]}")"
  fi
  rm "$tmp_before" "$tmp_after"
}

normalize_arch() {
  local arch_name="$1"
  local style="$2"
  if [[ -z "$style" ]]; then
    style="arch"
  fi

  arch_output=""
  case "$arch_name" in
    x86_64|x86-64|amd64)
      arch_output="x86_64"
      case "$style" in
        cpu)
          arch_output="x86-64"
        ;;
        arch|ndk|ndk-cpu|fancy)
          arch_output="x86_64"
        ;;
      esac
    ;;
    arm64|aarch64|armv8-a|arm64-v8a)
      case "$style" in
        fancy)
          arch_output="arm64-v8a"
        ;;
        arch|ndk|ndk-cpu)
          arch_output="aarch64"
        ;;
        cpu)
          arch_output="armv8-a"
        ;;
      esac
    ;;
    armhf|armv7l|armv7a|arm|armv7-a)
      case "$style" in
        fancy)
          arch_output="armeabi-v7a"
        ;;
        arch|ndk-cpu)
          arch_output="arm"
        ;;
        cpu)
          arch_output="armv7-a"
        ;;
        ndk)
          arch_output="armv7a"
        ;;
      esac
    ;;
    x86|i386|i686)
      case "$style" in
        arch|fancy)
          arch_output="x86"
        ;;
        cpu|ndk|ndk-cpu)
          arch_output="i686"
        ;;
      esac
    ;;
    *)
      echo "[error] Unknown architecture: $arch_name" >&2
      exit 1
  esac

  if [[ -z "$arch_output" ]]; then
    echo "[error] Unknown architecture style: $style" >&2
    exit 1
  fi

  echo "$arch_output"
}

copy_libs() {
  local lib_name="$1"
  local dest_dir="$2"
  local arch_name="$3"
  if [[ -n "$arch_name" ]]; then
    case "$arch_name" in
      x86_64|x86-64|amd64|arm64|aarch64|armv8-a|arm64-v8a|armhf|armv7l|armv7a|arm|armv7-a|x86|i386|i686)
        arch_name="$(normalize_arch "$arch_name" "fancy")"
        ;;
      default)
        arch_name=""
        shift 1
        ;;
      *)
        arch_name=""
        ;;
    esac
    if [[ -z "$arch_name" ]]; then
      shift 2
    else
      shift 3
    fi
  else
    shift 2
  fi
  local libs_list=("$@")
  if [[ ${#libs_list[@]} -eq 0 ]]; then
    libs_list=(
      "$lib_name"
    )
  fi
  import_lib_name="$(echo "$lib_name" | tr '[:lower:]' '[:upper:]')"
  import_lib_name="${import_lib_name//-/_}"
  git_var="LIB_${import_lib_name}_GIT"
  git_var="${!git_var}"
  if [[ -z "$git_var" ]]; then
    echo "[error] No dependency found for $lib_name" >&2
    exit 1
  fi
  base_path=$(read_cache "lib" "$git_var")
  is_static=$(read_cache "lib_kind" "$git_var")

  if [[ -z "$base_path" || -z "$is_static" ]]; then
    echo "[error] No build directory found for $lib_name" >&2
    echo "        please build the library first" >&2
    exit 1
  fi

  local lib_dir="$base_path/lib"
  local include_dir="$base_path/include"
  headers=()
  cached_headers="$(read_cache "lib_include" "$git_var")"

  if [[ -n "$cached_headers" ]]; then
    IFS=';' read -r -a headers <<< "$cached_headers"
  else
    echo "[error] No headers found for $lib_name" >&2
    echo "        please build the library first" >&2
    exit 1
  fi

  output_libs_dir="$dest_dir/lib"
  if [[ -n "$arch_name" ]]; then
    output_libs_dir="$output_libs_dir/$arch_name"
  fi

  mkdir -p "$output_libs_dir"

  if [[ -n "${headers[*]}" ]]; then
    for header in "${headers[@]}"; do
      lib_parent="${header//$include_dir\//}"
      echo "[info] Copying header $lib_parent" >&2
      mkdir -p "$(dirname "$dest_dir/include/$lib_parent")"
      cp "$include_dir/$lib_parent" "$dest_dir/include/$lib_parent"
    done
  fi

  for lib in "${libs_list[@]}"; do
    local lib_rgx
    if [[ "$is_static" == "static" ]]; then
      lib_rgx="$lib_dir/\(lib\)?${lib#lib}\.\(a\|lib\)"
    else
      lib_rgx="$lib_dir/\(lib\)?${lib#lib}\.\(so\|dll\|dylib\)"
    fi
    found_file=$(find "$lib_dir" -maxdepth 1 -iregex "$lib_rgx" \( -type f -o -type l \) -exec test -f {} \; -print -quit)
    if [[ -n "$found_file" ]]; then
      real_file=$(resolve_realpath "$found_file")
      lib_file_output=$(os_lib_format "$is_static" "$(basename "$found_file")")
      echo "[info] Copying $is_static library $lib_file_output" >&2
      cp "$real_file" "$output_libs_dir/$lib_file_output"
    else
      echo "[error] Library $(os_lib_format "$is_static" "$lib") not found in $lib_dir" >&2
      exit 1
    fi
  done
}

convert_to_static() {
  local lib_name="$1"
  shift 1
  local libs_list=("$@")
  if [[ ${#libs_list[@]} -eq 0 ]]; then
    libs_list=(
      "$lib_name"
    )
  fi
  import_lib_name="$(echo "$lib_name" | tr '[:lower:]' '[:upper:]')"
  import_lib_name="${import_lib_name//-/_}"
  git_var="LIB_${import_lib_name}_GIT"
  git_var="${!git_var}"
  if [[ -z "$git_var" ]]; then
    echo "[error] No dependency found for $lib_name" >&2
    exit 1
  fi
  base_path=$(read_cache "lib" "$git_var")
  if [[ -z "$base_path" ]]; then
    echo "[error] No build directory found for $lib_name" >&2
    echo "        please build the library first" >&2
    exit 1
  fi
  local curr_dir;
  local init_file;
  local tramp_file;
  curr_dir="$(pwd)"
  local lib_dir="$base_path/lib"

  mkdir -p "$DEFAULT_TOOLS_FOLDER"
  cd "$DEFAULT_TOOLS_FOLDER" || exit 1
  if [[ ! -d "$DEFAULT_TOOLS_FOLDER/Implib.so" ]]; then
    run git clone "https://github.com/yugr/Implib.so" --depth 1
  fi
  cd "Implib.so" || exit 1
  for lib in "${libs_list[@]}"; do
    local lib_file
    lib_file=$(os_lib_format "dynamic" "$lib")
    echo "[info] Converting $lib_file to static" >&2
    found_file=$(find "$lib_dir" -maxdepth 1 -iname "$lib_file" \( -type f -o -type l \) -exec test -f {} \; -print -quit)
    if [[ -n "$found_file" ]]; then
      real_file=$(resolve_realpath "$found_file")
      lib_file_output=$(os_lib_format "static" "$(basename "$found_file")")
      python implib-gen.py -q -o build "$real_file" || exit 1
      cd build || exit 1
      init_file="$(basename "$real_file").init"
      tramp_file="$(basename "$real_file").tramp"
      gcc -fPIC -c "$init_file.c" "$tramp_file.S"
      ar rcs "$lib_file_output" "$init_file.o" "$tramp_file.o"
      mv "$lib_file_output" "$lib_dir/$lib_file_output"
    else
      echo "[error] Library $lib_file not found in $lib_dir" >&2
      exit 1
    fi
    cd .. || exit 1
    rm -rf build
  done
  cd "$curr_dir" || exit 1
  write_cache "lib_kind" "$git_var" "static"
}

quote_args() {
  local first=true
  local unsafe_re="[[:space:]\$\&\|\>\<\;\(\)\*\'\"]"
  for arg in "$@"; do
    if ! $first; then
      printf " "
    else
      first=false
    fi
    if [[ "$arg" == *=* ]]; then
      local key="${arg%%=*}"
      local value="${arg#*=}"
      if [[ "$value" =~ $unsafe_re ]]; then
        value="\"${value//\"/\\\"}\""
      fi
      printf "%s=%s" "$key" "$value"
    elif [[ "$arg" =~ $unsafe_re ]]; then
      printf "\"%s\"" "${arg//\"/\\\"}"
    else
      printf "%s" "$arg"
    fi
  done
}

process_args() {
  local mode="$1";
  local arg="$2";
  shift 2
  local args=("$@")
  local new_args=()
  local i=0
  local n=${#args[@]}
  local v
  while (( i < n )); do
    v="${args[i]}"
    if [[ "$v" == "$arg" ]]; then
      if [[ "$mode" == "get" ]]; then
        echo "${args[i+1]}"
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
    new_args+=( "$v" )
    (( i++ ))
  done
  if [[ "$mode" == "filter" ]]; then
    printf '%s\n' "${new_args[@]}"
  else
    return 1
  fi
}

resolve_realpath() {
  local path="$1"

  if [ ! -L "$path" ]; then
    echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    return
  fi

  while [ -L "$path" ]; do
    if [[ "$path" != /* ]]; then
      path="$(dirname "$1")/$path"
    fi
    path_target=$(find "$(dirname "$path")" -maxdepth 1 -name "$(basename "$path")" -exec readlink -f {} \;)
    if [[ "$path_target" != /* ]]; then
      path="$(dirname "$path")/$path_target"
    else
      path="$path_target"
    fi
  done
  echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
}

android_tool() {
  local tool="$1"
  local arch="$2"
  if [[ -n "$arch" ]]; then
    arch="$(normalize_arch "$arch" "ndk")"
  fi

  case "$tool" in
   cc|cxx)
     local clang_ex="clang"
     local abi_name=""
     if [[ "$tool" == "cxx" ]]; then
       clang_ex="clang++"
     fi
     abi_name="android"
     if [[ "$arch" == "armv7a" ]]; then
       abi_name="${abi_name}eabi"
     fi
     echo "$ANDROID_PREBUILT/bin/$arch-linux-$abi_name$ANDROID_API-$clang_ex"
     ;;
   ar|ranlib|nm|strip)
     echo "$ANDROID_PREBUILT/bin/llvm-$tool"
     ;;
   sysroot)
     echo "$ANDROID_PREBUILT/sysroot"
     ;;
   toolchain)
     echo "$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake"
     ;;
   builtins)
     local builtin_path
     lib_name="libclang_rt.builtins-$(normalize_arch "$arch" "ndk-cpu")-android.a"
     builtin_path=$(find "$ANDROID_PREBUILT/lib/" -type f -name "$lib_name" | sort -V | tail -n 1)
     if [[ -z "$builtin_path" ]]; then
       echo "[error] $lib_name not found" >&2
       exit 1
     fi
     echo "$builtin_path"
     ;;
   *)
     echo "[error] Unknown tool: $tool" >&2
     exit 1
     ;;
   esac
 }