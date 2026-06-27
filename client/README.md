# Conductor Client

Flutter desktop shell for the controlled endpoint. It launches the Rust `conductor-agent`, passes connection settings through environment variables, and shows live stdout/stderr logs.

The main window focuses on status, start/stop controls, commands, and logs. Server URL, Agent Token, Agent Name, file root, audio input, and local approval are configured from the Settings page or baked in as build defaults.

Build the current host bundle from the repository root:

```sh
./scripts/build-client.sh
```

The build writes a distributable archive under `release/` and a matching
`.sha256` checksum file.

Build defaults can be supplied from the repository root:

```sh
./scripts/build-client.sh --server-url ws://server:8080/ws/agent --agent-token token
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1
```

The Windows build writes `release\conductor-client-windows-x64.zip` and
`release\conductor-client-windows-x64.zip.sha256`.

Windows build defaults:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -ServerUrl "ws://server:8080/ws/agent" -AgentToken "token"
```

More details: `docs/client.md`.
