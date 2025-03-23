export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib/pkgconfig:$PKG_CONFIG_PATH
export ACLOCAL_PATH=/usr/share/aclocal

LIBRARIES_FILE="libraries.properties"
# shellcheck disable=SC2034
FREEDESKTOP_GIT="https://gitlab.com/freedesktop-sdk/mirrors/freedesktop/"

get_version() {
    grep "^$1=" "$LIBRARIES_FILE" | cut -d '=' -f2
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
  local pre_autogen_command=""
  local new_args=()

  for arg in "$@"; do
    if [[ "$arg" == "--update-submodules" ]]; then
      update_submodules=true
    elif [[ "$arg" == "--skip-build" ]]; then
      skip_build=true
    elif [[ "$arg" == --pre-autogen-command* ]]; then
      pre_autogen_command="${arg#--pre-autogen-command=}"
    else
      new_args+=("$arg")
    fi
  done

  if [ -n "$repo_url" ] && [ -n "$branch" ]; then
    if [ ! -d "$repo_name" ]; then
      run git clone "$repo_url" --branch "$branch" --depth 1
    fi
  fi

  cd "$repo_name" || exit 1

  if [[ "$update_submodules" == "true" ]]; then
    run git submodule update --init --recursive
  fi

  if [ -n "$pre_autogen_command" ]; then
      local pre_autogen_command_array
      eval "pre_autogen_command_array=($pre_autogen_command)"
      run "${pre_autogen_command_array[@]}"
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
      run ./autogen.sh
      run ./configure --prefix=/usr "${new_args[@]}"
      ;;
    configure-static)
      echo "Running configure for $repo_name with static build options: ${new_args[*]}"
      run ./autogen.sh
      run ./configure --enable-static --disable-shared --enable-pic "${new_args[@]}"
      ;;
    meson)
      echo "Running meson for $repo_name with options: ${new_args[*]}"
      run python -m mesonbuild.mesonmain setup build --prefix=/usr "${new_args[@]}"
      ;;
    meson-static)
      echo "Running meson for $repo_name with static build options: ${new_args[*]}"
      run python -m mesonbuild.mesonmain setup build --prefix=/app/build_output --libdir=lib --buildtype=release --default-library=static "${new_args[@]}"
      ;;
    cmake)
      echo "Running cmake with options: ${new_args[*]}"
      run cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/usr -G Ninja "${new_args[@]}"
      ;;
    *)
      echo "Unknown build type: $build_type" >&2
      exit 1
      ;;
  esac

  if [[ "$skip_build" == "false" ]]; then
    if [[ "$build_type" == "autogen" || "$build_type" == "autogen-static" || "$build_type" == "configure" || "$build_type" == "configure-static" ]]; then
        run make -j"$(nproc)" --ignore-errors=2
        run make install
      else
        run python -m ninja -C build
        run python -m ninja -C build install
      fi
  fi
  cd .. || exit 1
}