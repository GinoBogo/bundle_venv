# bundle_venv.sh

Relocate and self-contain a Python virtual environment created with
`--copies`.

`bundle_venv.sh` makes a Python environment deployable to machines without
internet access or to secured, locked-down machines by embedding the
interpreter and its dependencies. It rewrites internal paths, embeds the
base Python, bundles non-system shared library dependencies, and can build
a tarball or a single-file self-extracting installer. It is a Bash script
for Linux.

## Features

- Detects the original venv path from `pyvenv.cfg`.
- Rewrites binaries, shebangs, and configuration for a new location.
- Embeds the base Python with `--embed`.
- Copies the standard library and `libpython*.so`.
- Detects the base Python or accepts `--base-python`.
- Bundles runtime dependencies with `--bundle-runtime`.
- Includes or excludes libraries by regex, soname, glob, or path.
- Never bundles core glibc libraries.
- Patches ELF RPATH unless `--no-patchelf` is used.
- Builds tarballs and self-extracting installers.
- Supports dry-run, quiet, and overwrite controls.

## Requirements

- Bash
- Python 3 venv created with `python3 -m venv --copies`
- `patchelf`
- `tar` and `gzip`

## Quick Start

Create and populate a venv:

```bash
python3 -m venv --copies ./venv
source ./venv/bin/activate
pip install -r requirements.txt
```

Fix paths after moving:

```bash
./bundle_venv.sh ./venv
```

Embed Python and create a tarball:

```bash
./bundle_venv.sh --embed -o myapp_venv.tgz ./venv
```

Build an installer:

```bash
./bundle_venv.sh --embed -r -o myapp_venv.tgz ./venv
./myapp_venv.run /opt/myapp
```

## Usage

```text
bundle_venv.sh [OPTIONS] [VENV_DIR]
```

If `VENV_DIR` is omitted, the directory containing the script is used.

## Options

- `-n, --new PATH` - final venv path. Default is `VENV_DIR`.
- `-t, --test` - dry run; print planned changes.
- `-q, --quiet` - only warnings and summary.
- `-k, --keep-pycache` - keep pycache directories.
- `-h, --help` - show help.
- `-V, --version` - show version.
- `--embed` - force base Python embedding.
- `--no-embed` - skip embedding.
- `--base-python DIR` - override base Python detection.
- `--no-stdlib` - do not copy stdlib.
- `--no-libpython` - do not copy `libpython*.so`.
- `--no-patchelf` - do not patch ELF RPATH.
- `--bundle-runtime` - bundle non-system libraries.
- `--no-bundle-runtime` - disable runtime bundling.
- `--bundle-exclude REGEX` - exclude matching libraries.
- `--bundle-include LIST` - always bundle listed libraries.
- `-f, --force` - overwrite existing output.
- `-z, --compress` - create a tarball.
- `-o, --output FILE` - output archive path.
- `-r, --self-extract` - build a `.run` installer.
- `--self-extract=FILE` - set installer path.

## Workflow

1. Create a venv with `--copies`.
2. Install packages.
3. Embed Python and build an installer.
4. Transport the installer.
5. Run it into the final destination.
6. The installer extracts and fixes paths.

## Notes

- Venvs must use `--copies`.
- `libstdc++.so.6` is treated as system unless requested.
- Core glibc is never bundled.
- Default venv location is the repository directory.

## Tests

Regression tests are in `tests/test_bundle_venv.sh`.

```bash
bash tests/test_bundle_venv.sh
```

They locate `bundle_venv.sh` automatically and adapt to the repository
layout.

## Author

Gino Bogo

## Version

1.6.3

## License

MIT. See LICENSE.
```