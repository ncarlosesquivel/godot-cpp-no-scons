## godot-cpp extensions without scons

Because Scons should not exist, this template:

- Creates a godot project or uses an existing one
- Adds the extension to the project with the cmake config
- Adds a Makefile and a build.sh script to use with cmake
- It renames everything needing renaming (with the name of the extension)

### How to use

1. initialize the godot-cpp git submodule via `git submodule update --init` or not, `init.sh` will do it.
2. Create a new project and extension: `./init.sh --new --path /path/to/project --project-name HeheXD --name MyExtension` OR Create the extension in an already existing project: `./init --project /path/to/project --name MyExtension`
3. Go on `/path/to/project/native/MyExtension` and run `make build` or `./build.sh`


You can also pass `--build-profile` to include the `build_profile.json` file and the configuration in the `CMakeLists.txt` file.


Paths are absolute. API version is hardcoded to 4.7.

