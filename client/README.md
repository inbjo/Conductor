# Conductor Client

Flutter desktop shell for the controlled endpoint. It launches the Rust `conductor-agent`, passes connection settings through environment variables, and shows live stdout/stderr logs.

Build the current host bundle from the repository root:

```sh
./scripts/build-client.sh
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1
```

More details: `docs/client.md`.
