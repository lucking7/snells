## Cursor Cloud specific instructions

This is a pure Bash shell script repository (7 independent `.sh` scripts). There is no build system, no package manager lockfile, and no application server to start.

### Dev tools

- **shellcheck** — installed via `apt-get install -y shellcheck`. Used for static analysis / linting.
- No other dev dependencies are required.

### Lint

```bash
# Syntax check all scripts
for f in *.sh; do bash -n "$f"; done

# ShellCheck (error-only)
shellcheck --severity=error *.sh

# ShellCheck (all warnings)
shellcheck *.sh
```

### Testing

The scripts are interactive server-administration tools that require root + systemd on a real Linux server. They cannot be fully executed in a dev/CI environment. Validation is limited to:

1. `bash -n` syntax checks
2. `shellcheck` static analysis

### Known pre-existing issues

- `realm.sh` line 967: `local` used outside a function (`SC2168`). This is a pre-existing issue in the repository.
