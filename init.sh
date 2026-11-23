#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
PROJECT_DIR=""
PROJECT_NAME=""
EXTENSION_NAME=""
API_VERSION="4.7"

usage() {
    cat <<'EOF'
Usage:

  Existing Godot project:
    ./init.sh \
      --project /path/to/game \
      --name MyExtension

  New Godot project:
    ./init.sh \
      --new \
      --path /path/to/new/game \
      --project-name MyGame \
      --name MyExtension

Options:
	--project PATH       Existing Godot project directory. ABSOLUTE PATH.
  --new                Create a new Godot project.
  --path PATH          Destination for a new Godot project. ABSOLUTE PATH.
  --project-name NAME  New Godot project name.
  --name NAME          GDExtension name.
  --api-version VER    Godot API version (default: 4.7).
  -h, --help           Show this help.

EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --project)
            PROJECT_DIR="${2:?Missing path for --project}"
            MODE="existing"
            shift 2
            ;;
        --new)
            MODE="new"
            shift
            ;;
        --path)
            PROJECT_DIR="${2:?Missing path for --path}"
            shift 2
            ;;
        --project-name)
            PROJECT_NAME="${2:?Missing name for --project-name}"
            shift 2
            ;;
        --name)
            EXTENSION_NAME="${2:?Missing name for --name}"
            shift 2
            ;;
        --api-version)
            API_VERSION="${2:?Missing version for --api-version}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

# /////////////////////////////////
# ~ Validate args

[[ -n "$MODE" ]] || {
    usage
    die "Choose --project or --new."
}

[[ -n "$PROJECT_DIR" ]] ||
    die "A project path is required."

[[ -n "$EXTENSION_NAME" ]] ||
    die "An extension name is required (--name)."

if [[ "$MODE" == "existing" ]]; then
    [[ -f "$PROJECT_DIR/project.godot" ]] ||
        die "No project.godot found in: $PROJECT_DIR"
fi

if [[ "$MODE" == "new" && -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
fi

# /////////////////////////////////
# ~ Validate env

[[ "$(uname -s)" == "Darwin" ]] ||
    die "MacOS only."

ARCH="$(uname -m)"

case "$ARCH" in
    arm64)
        ;;
    *)
        die "Unsupported macOS architecture: $ARCH"
        ;;
esac

command -v git >/dev/null ||
    die "Git is required."

command -v cmake >/dev/null ||
    die "CMake is required."

command -v ninja >/dev/null ||
    die "Ninja is required."

# /////////////////////////////////
# ~ Normalize extension name

EXTENSION_SLUG="$(
    printf '%s' "$EXTENSION_NAME" |
        tr '[:upper:]' '[:lower:]' |
        sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
)"

[[ -n "$EXTENSION_SLUG" ]] ||
    die "Invalid extension name."

if [[ "$EXTENSION_SLUG" =~ ^[0-9] ]]; then
    EXTENSION_SLUG="extension_${EXTENSION_SLUG}"
fi

# /////////////////////////////////
# ~ Resolve project dst

mkdir -p "$PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

if [[ "$MODE" == "new" ]]; then
    if [[ -e "$PROJECT_DIR/project.godot" ]]; then
        die "A Godot project already exists at $PROJECT_DIR"
    fi

    cat > "$PROJECT_DIR/project.godot" <<EOF
; Engine configuration file.
; It's best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=5

[animation]

compatibility/default_parent_skeleton_in_mesh_instance_3d=true

[application]

config/name="$PROJECT_NAME"
config/features=PackedStringArray("$API_VERSION", "Forward Plus")
config/icon="res://icon.svg"
EOF

    mkdir -p "$PROJECT_DIR/scenes"
    mkdir -p "$PROJECT_DIR/scripts"

    printf 'Created Godot project: %s\n' "$PROJECT_DIR"
fi

# /////////////////////////////////
# ~ Generated dir structure

ADDON_DIR="$PROJECT_DIR/addons/$EXTENSION_SLUG"
NATIVE_DIR="$PROJECT_DIR/native/$EXTENSION_SLUG"
GODOT_CPP_DIR="$NATIVE_DIR/godot-cpp"

[[ ! -e "$ADDON_DIR" ]] ||
    die "Extension addon directory already exists: $ADDON_DIR"

[[ ! -e "$NATIVE_DIR" ]] ||
    die "Native extension directory already exists: $NATIVE_DIR"

mkdir -p "$ADDON_DIR/bin/macos"
mkdir -p "$NATIVE_DIR"

# /////////////////////////////////
# ~ Validate generator template

[[ -f "$SCRIPT_DIR/CMakeLists.txt" ]] ||
    die "Template CMakeLists.txt not found."

[[ -d "$SCRIPT_DIR/src" ]] ||
    die "Template src directory not found."

# TODO: auto
[[ -f "$SCRIPT_DIR/.gitmodules" ]] ||
    die "Template .gitmodules not found."

# /////////////////////////////////
# ~ Init template godot-cpp submodule

printf '\nPreparing godot-cpp dependency...\n'

git -C "$SCRIPT_DIR" submodule update --init godot-cpp

GODOT_CPP_URL="$(
    git -C "$SCRIPT_DIR" config \
        -f .gitmodules \
        --get submodule.godot-cpp.url
)"

GODOT_CPP_COMMIT="$(
    git -C "$SCRIPT_DIR/godot-cpp" rev-parse HEAD
)"

[[ -n "$GODOT_CPP_URL" ]] ||
    die "Could not determine godot-cpp repository URL."

[[ -n "$GODOT_CPP_COMMIT" ]] ||
    die "Could not determine godot-cpp commit."

# NOTE: To git or not to git
# If dst project is a git repo register godot-cpp as a submodule,
# otherwise, export the pinned dependency source into the
# generated project without copying the generator's .git data.

if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree \
    >/dev/null 2>&1; then

    RELATIVE_CPP_PATH="native/$EXTENSION_SLUG/godot-cpp"

    git -C "$PROJECT_DIR" submodule add \
        "$GODOT_CPP_URL" \
        "$RELATIVE_CPP_PATH"

    git -C "$GODOT_CPP_DIR" checkout --detach "$GODOT_CPP_COMMIT"

    git -C "$PROJECT_DIR" add "$RELATIVE_CPP_PATH"

else
    mkdir -p "$GODOT_CPP_DIR"

    git -C "$SCRIPT_DIR/godot-cpp" archive HEAD |
        tar -x -C "$GODOT_CPP_DIR"

    printf 'Exported pinned godot-cpp source (not a Git submodule).\n'
fi

# /////////////////////////////////
# ~ Copy extension template

cp "$SCRIPT_DIR/CMakeLists.txt" "$NATIVE_DIR/CMakeLists.txt"

cp "$SCRIPT_DIR/build_profile.json" "$NATIVE_DIR/build_profile.json"

cp -R "$SCRIPT_DIR/src" "$NATIVE_DIR/src"

# cmake identifiers
perl -0pi -e "
    s/EXTENSION-NAME/$EXTENSION_SLUG/g;
    s/godot-cpp-template/$EXTENSION_SLUG/g;
    s/set\\(GODOT_PROJECT_DIR \"project\" CACHE STRING \"The directory of a Godot project folder\"\\)/set(GODOT_PROJECT_DIR \"..\\/..\\/addons\\/$EXTENSION_SLUG\" CACHE STRING \"The directory of a Godot project folder\")/;
" "$NATIVE_DIR/CMakeLists.txt"

# initialization symbol
if [[ -f "$NATIVE_DIR/src/register_types.cpp" ]]; then
    perl -pi -e \
        "s/example_library_init/${EXTENSION_SLUG}_library_init/g" \
        "$NATIVE_DIR/src/register_types.cpp"
fi

# extra hidden files
cp "$SCRIPT_DIR/.clang-format" "$NATIVE_DIR/.clang-format"
cp "$SCRIPT_DIR/.gitignore" "$NATIVE_DIR/.gitignore"

# /////////////////////////////////
# ~ Generate GDExtension descriptor
# TODO: platforms

cat > "$ADDON_DIR/$EXTENSION_SLUG.gdextension" <<EOF
[configuration]

entry_symbol = "${EXTENSION_SLUG}_library_init"
compatibility_minimum = "4.1"
reloadable = false

[libraries]

macos.single.debug = "./bin/macos/${EXTENSION_SLUG}.macos.template_debug.${ARCH}.dylib"
macos.single.release = "./bin/macos/${EXTENSION_SLUG}.macos.template_release.${ARCH}.dylib"
EOF

# /////////////////////////////////
# ~ Generate cmake presets

cat > "$NATIVE_DIR/CMakePresets.json" <<EOF
{
	"version": 6,
  "configurePresets": [
    {
      "name": "macos-${ARCH}-debug",
      "displayName": "macOS ${ARCH} Debug",
      "generator": "Ninja",
      "binaryDir": "\${sourceDir}/build",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_OSX_ARCHITECTURES": "${ARCH}",
        "GODOTCPP_API_VERSION": "${API_VERSION}",
        "GODOT_PROJECT_DIR": "../../addons/${EXTENSION_SLUG}"
      }
    }
  ],
  "buildPresets": [
    {
      "name": "macos-${ARCH}-debug",
      "configurePreset": "macos-${ARCH}-debug"
    }
  ]
}
EOF

# /////////////////////////////////
# ~ Build helper for the extension

cat > "$NATIVE_DIR/build.sh" <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

cd "\$(dirname "\${BASH_SOURCE[0]}")"

cmake --preset macos-${ARCH}-debug
cmake --build --preset macos-${ARCH}-debug
EOF

chmod +x "$NATIVE_DIR/build.sh"

# /////////////////////////////////
# ~ Makefile for the extension
# TODO: build.sh or Makefile not both

cat > "$NATIVE_DIR/Makefile" <<EOF
.PHONY: all configure build rebuild clean help

PRESET := macos-${ARCH}-debug
BUILD_DIR := build

all: build

configure:
	cmake --preset \$(PRESET)

build: configure
	cmake --build --preset \$(PRESET)

rebuild: clean build

clean:
	cmake -E rm -rf \$(BUILD_DIR)

help:
	@echo "Available commands:"
	@echo "  make           - Configure and build"
	@echo "  make configure - Configure CMake"
	@echo "  make build     - Build extension"
	@echo "  make rebuild   - Clean and rebuild"
	@echo "  make clean     - Remove build directory"
EOF

# /////////////////////////////////
# ~ Ignore local build output

cat > "$NATIVE_DIR/.gitignore" <<'EOF'
/build/
EOF

# /////////////////////////////////
# ~ README.md

cat > "$NATIVE_DIR/README.md" <<EOF
## ${EXTENSION_NAME}

Godot GDExtension implemented in C++

### Requirements

- CMake
- Ninja
- Git
- Python 3 (required by godot-cpp binding generation)
- Apple Clang

### Build

From this directory:

\`\`\`bash
./build.sh
\`\`\`

or read the Makefile.

The compiled library is copied automatically into:

\`\`\`
../../addons/${EXTENSION_SLUG}/bin/macos/
\`\`\`

The GDExtension descriptor is:

\`\`\`
../../addons/${EXTENSION_SLUG}/${EXTENSION_SLUG}.gdextension
\`\`\`
EOF

# /////////////////////////////////
# ~ Finish

printf '\n'
printf 'GDExtension generated successfully.\n'
printf '\n'
printf 'Godot project:\n  %s\n' "$PROJECT_DIR"
printf '\n'
printf 'Native extension:\n  %s\n' "$NATIVE_DIR"
printf '\n'
printf 'Godot addon:\n  %s\n' "$ADDON_DIR"
printf '\n'
