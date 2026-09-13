#!/usr/bin/env python3
"""Static contract checks for the Windows Docker validation bundle.

This is not a substitute for executing the script on Windows. It catches
encoding mistakes, unbalanced PowerShell syntax delimiters, broken here-strings,
newer-language constructs that Windows PowerShell 5.1 cannot parse, and accidental
host-tool dependencies before packaging.
"""
from __future__ import annotations

import codecs
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PS1 = ROOT / "tools/windows/Run-ToRoute-Docker-Validation.ps1"
CMD = ROOT / "tools/windows/Run-ToRoute-Docker-Validation.cmd"
ROOT_CMD = ROOT / "RUN_DOCKER_VALIDATION.cmd"


def fail(message: str) -> "None":
    raise SystemExit(f"Windows validation contract failed: {message}")


def check_powershell_syntax(text: str) -> None:
    stack: list[tuple[str, int]] = []
    pairs = {')': '(', ']': '[', '}': '{'}
    opening = set(pairs.values())
    state = "normal"
    here_end = ""
    block_comment = False

    for number, raw_line in enumerate(text.splitlines(), 1):
        stripped = raw_line.strip()
        if state == "here":
            if stripped == here_end:
                state = "normal"
                here_end = ""
            continue
        if block_comment:
            if "#>" in raw_line:
                raw_line = raw_line.split("#>", 1)[1]
                block_comment = False
            else:
                continue
        if stripped.endswith("@'"):
            prefix = stripped[:-2]
            if "'" not in prefix and '"' not in prefix:
                state = "here"
                here_end = "'@"
                continue
        if stripped.endswith('@"'):
            prefix = stripped[:-2]
            if "'" not in prefix and '"' not in prefix:
                state = "here"
                here_end = '"@'
                continue

        quote = ""
        index = 0
        while index < len(raw_line):
            char = raw_line[index]
            nxt = raw_line[index + 1] if index + 1 < len(raw_line) else ""
            if quote == "single":
                if char == "'":
                    if nxt == "'":
                        index += 2
                        continue
                    quote = ""
                index += 1
                continue
            if quote == "double":
                if char == "`":
                    index += 2
                    continue
                if char == "\\" and nxt == '"':
                    fail(
                        f"C-style backslash escaping is invalid in a PowerShell "
                        f"expandable string on line {number}; use a backtick, a "
                        f"single-quoted string, or double the quote as appropriate"
                    )
                if char == "$":
                    # In expandable strings, `$name:` is parsed as a scoped/drive
                    # variable. Ordinary variables must use `${name}:` to delimit
                    # the name. Scope prefixes such as `$env:NAME` remain valid.
                    match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", raw_line[index + 1 :])
                    if match:
                        name = match.group(0)
                        after = index + 1 + len(name)
                        if after < len(raw_line) and raw_line[after] == ":":
                            scopes = {
                                "alias", "env", "function", "global", "local",
                                "private", "script", "using", "variable",
                            }
                            if name.lower() not in scopes:
                                fail(
                                    f"unbraced variable ${name}: in an expandable "
                                    f"string on line {number}; use ${{{name}}}:"
                                )
                if char == '"':
                    quote = ""
                index += 1
                continue
            if char == "#":
                break
            if char == "<" and nxt == "#":
                end = raw_line.find("#>", index + 2)
                if end == -1:
                    block_comment = True
                    break
                index = end + 2
                continue
            if char == "'":
                quote = "single"
            elif char == '"':
                quote = "double"
            elif char in opening:
                stack.append((char, number))
            elif char in pairs:
                if not stack or stack[-1][0] != pairs[char]:
                    fail(f"unmatched {char!r} on line {number}")
                stack.pop()
            index += 1
        if quote:
            fail(f"unterminated {quote} quote on line {number}")

    if state == "here":
        fail(f"unterminated PowerShell here-string; expected {here_end}")
    if block_comment:
        fail("unterminated PowerShell block comment")
    if stack:
        opener, number = stack[-1]
        fail(f"unclosed {opener!r} opened on line {number}")



def check_parser_regressions() -> None:
    invalid = [
        'throw "Command failed with exit code $exitCode: command"',
        '$x = "awk \'$2==\\"00000000\\"{print $3}\' /proc/net/route"',
    ]
    for snippet in invalid:
        try:
            check_powershell_syntax(snippet)
        except SystemExit:
            continue
        fail(f"syntax checker accepted a known Windows PowerShell parser regression: {snippet}")

    valid = [
        'throw "Command failed with exit code ${exitCode}: command"',
        "$route = 'while read destination; do printf \"%s\\n\" \"$destination\"; done'",
        '$value = "$env:PATH"',
        '$value = "$script:state"',
    ]
    for snippet in valid:
        check_powershell_syntax(snippet)


def check_batch_control_flow(text: str, name: str) -> None:
    labels = re.findall(r"(?im)^:([A-Za-z0-9_.-]+)\s*$", text)
    if len(labels) != len(set(label.lower() for label in labels)):
        fail(f"{name} contains duplicate labels")
    known = {label.lower() for label in labels}
    for target in re.findall(r"(?i)\bgoto\s+:?([A-Za-z0-9_.-]+)", text):
        if target.lower() == "eof":
            continue
        if target.lower() not in known:
            fail(f"{name} jumps to missing label: {target}")

def main() -> None:
    raw = PS1.read_bytes()
    if not raw.startswith(codecs.BOM_UTF8):
        fail("PowerShell file must use UTF-8 BOM for Windows PowerShell 5.1 Japanese text")
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        fail(f"PowerShell file is not valid UTF-8: {exc}")
    if "\x00" in text:
        fail("PowerShell file contains NUL")
    check_parser_regressions()
    check_powershell_syntax(text)

    required = [
        "[CmdletBinding()]",
        'Set-StrictMode -Version Latest',
        'Docker Engine 25.0',
        'Docker Compose 2.33.1',
        'buildx", "build"',
        'SOCKS5 remote DNS',
        'HTTP CONNECT',
        'NEWNYM・Control往復',
        'runtime metrics・package inventory',
        'arm64 QEMU build・config validation',
        'Compress-Archive',
        'result.json',
        'SUMMARY.md',
        'compose-logs-final.txt',
        'compose-containers-final.json',
        'Start-Transcript',
        'powershell-transcript.txt',
        'exit code ${exitCode}:',
        '[switch]$PreflightOnly',
        'Test-PowerShellRuntime',
        'Resolve-SourceCommit',
        'SOURCE_METADATA.json',
        'Source identity unavailable. Use a Git checkout or an official source package',
        'native-runner-self-test.ps1',
        'System.Diagnostics.ProcessStartInfo',
        'RedirectStandardOutput = $true',
        'RedirectStandardError = $true',
        'Convert-ToNativeCommandLineArgument',
        'Read-ContainerFile',
        'Convert-ToNonNegativeInt64',
        'Convert-CgroupValues',
        'Wait-ToRouteReadiness',
        'Resolve-DockerHealthAction',
        'Wait-DockerHealthSynchronization',
        'docker-health-sync.jsonl',
        'Docker health synchronization timed out after ${TimeoutSeconds}s',
        'Docker health starting transition self-test failed',
        'bootstrap-progress.jsonl',
        'Tor bootstrap timed out after ${TimeoutSeconds}s',
        'Native command arguments must not contain CR or LF',
        'cgroup v2 parser self-test failed',
        'cgroup v1 parser self-test failed',
        '/sys/fs/cgroup/memory.current',
        '/sys/fs/cgroup/cpu.stat',
        'proc-net-route.txt',
        '-ContinueOnFailure -Action {',
        'StdOut = $stdout.TrimEnd()',
        'StdErr = $stderr.TrimEnd()',
        "'-f=${binary:Package}\\t${Version}\\t${Installed-Size}\\n'",
    ]
    for fragment in required:
        if fragment not in text:
            fail(f"PowerShell file is missing required control: {fragment}")

    lower = text.lower()
    forbidden_dependencies = ["curl.exe", "invoke-webrequest", "python.exe", "python3", "wsl.exe", "bash.exe", "git-bash"]
    for dependency in forbidden_dependencies:
        if dependency in lower:
            fail(f"PowerShell runner unexpectedly depends on host tool {dependency}")
    unsupported = [r"\?\?", r"\?\.", r"\bForEach-Object\s+-Parallel\b", r"\busing\s+namespace\b"]
    for pattern in unsupported:
        if re.search(pattern, text):
            fail(f"PowerShell runner uses a construct outside the 5.1 compatibility contract: {pattern}")

    if "@Arguments 2>&1" in text:
        fail("native stdout/stderr may not be merged under Windows PowerShell 5.1")
    if re.search(r"&\s+\$FilePath\s+@Arguments", text):
        fail("native commands must use ProcessStartInfo rather than PowerShell's native stderr adapter")
    if "System.Collections.Generic.List" in text:
        fail("generic List conversion is not allowed in the Windows PowerShell 5.1 evidence path")
    if 'Get-Command git -ErrorAction SilentlyContinue' not in text or 'Join-Path $RepoRoot ".git"' not in text:
        fail("git probing must be conditional on an actual .git entry")
    if text.index('Join-Path $RepoRoot ".git"') > text.index('Join-Path $RepoRoot "SOURCE_METADATA.json"'):
        fail("a real Git checkout must take precedence over packaged source metadata")
    if 'return "source-archive"' in text:
        fail("unidentified source archives must fail closed instead of using a synthetic revision")
    if '"--wait"' in text or '"--wait-timeout"' in text:
        fail("Windows validator must poll ToRoute bootstrap directly rather than delegating readiness to Compose health state")
    if '& $FilePath @Arguments' in text:
        fail("PowerShell native invocation adapter must not be used for Docker commands")
    if '"/bin/sh", "-c"' in text or "'/bin/sh', '-c'" in text:
        fail("Windows validator must not pass shell programs through native argument quoting")
    if 'IndexOf("`r")' not in text or 'IndexOf("`n")' not in text:
        fail("native runner must reject multiline arguments before process creation")
    if "$script = @'" in text and 'Get-CgroupSample' in text:
        fail("cgroup metrics must use direct file reads rather than a multiline shell script")
    if 'Invoke-Check -Name "runtime metrics・package inventory" -ContinueOnFailure' not in text:
        fail("runtime metrics failure must not suppress log auditing or arm64 evidence")
    if 'Wait-DockerHealthSynchronization -ContainerId $torouteId -TimeoutSeconds 45' not in text:
        fail("direct Tor readiness must be synchronized with Docker health before hardened-state assertions")
    if text.index('Wait-DockerHealthSynchronization -ContainerId $torouteId') > text.index('$containerInspectResult = Invoke-Native'):
        fail("Docker health synchronization must run before the hardened container inspect assertion")
    for fragment in ['System.Diagnostics.ProcessStartInfo', 'ReadToEndAsync()', 'StandardOutputEncoding', 'StandardErrorEncoding']:
        if fragment not in text:
            fail(f"ProcessStartInfo native runner is missing {fragment}")
    if 'if ($PreflightOnly)' not in text or 'else {' not in text:
        fail("runtime preflight must be executable without Docker")

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    match = re.search(r'^##\s+(\d+\.\d+\.\d+-rc\.\d+)\b', changelog, re.MULTILINE)
    if not match:
        fail("unable to read current RC version from CHANGELOG")
    if f'$Version = "{match.group(1)}"' not in text:
        fail("PowerShell evidence version differs from CHANGELOG")

    cmd_raw = CMD.read_bytes()
    try:
        cmd_text = cmd_raw.decode("ascii")
    except UnicodeDecodeError as exc:
        fail(f"CMD wrapper must remain ASCII: {exc}")
    if b"\n" in cmd_raw.replace(b"\r\n", b""):
        fail("CMD wrapper contains bare LF; use CRLF")
    check_batch_control_flow(cmd_text, "inner CMD launcher")
    for fragment in [
        "TOROUTE_INVOKED_BY_ROOT",
        r"..\..\RUN_DOCKER_VALIDATION.cmd",
        "pwsh.exe",
        "powershell.exe",
        "Run-ToRoute-Docker-Validation.ps1",
        "System.Management.Automation.Language.Parser",
        "last-launch.log",
        "PowerShell parser preflight: PASS",
        "TOROUTE_PARSE_ONLY",
        "Parse-only validation completed successfully.",
        "%*",
    ]:
        if fragment not in cmd_text:
            fail(f"CMD wrapper is missing {fragment}")
    if "%ERRORLEVEL% EQU" in cmd_text:
        fail("CMD wrapper uses parse-time ERRORLEVEL expansion; use IF ERRORLEVEL instead")

    ci_text = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    for fragment in [
        "windows-launcher:",
        "runs-on: windows-latest",
        "shell: powershell",
        "TOROUTE_PARSE_ONLY",
        "-PreflightOnly",
        "archive-mode runtime self-test",
        "Remove-Item -LiteralPath (Join-Path $archiveRoot '.git')",
        "shell: pwsh",
        "needs: [source, policy, windows-launcher]",
    ]:
        if fragment not in ci_text:
            fail(f"CI is missing real Windows parser gate: {fragment}")

    root_raw = ROOT_CMD.read_bytes()
    try:
        root_text = root_raw.decode("ascii")
    except UnicodeDecodeError as exc:
        fail(f"root CMD launcher must remain ASCII: {exc}")
    if b"\n" in root_raw.replace(b"\r\n", b""):
        fail("root CMD launcher contains bare LF; use CRLF")
    check_batch_control_flow(root_text, "root CMD launcher")
    for fragment in [
        "tools\\windows\\Run-ToRoute-Docker-Validation.cmd",
        "launcher-bootstrap.log",
        "last-launch.log",
        '"%ComSpec%" /d /k call "%~f0" %*',
        "TOROUTE_CONSOLE_SESSION",
        "TOROUTE_INVOKED_BY_ROOT",
        "pause >nul",
        "This console is persistent and will not close automatically.",
        "RESULT: SUCCESS",
        "RESULT: FAILED",
        "%*",
    ]:
        if fragment not in root_text:
            fail(f"root CMD launcher is missing {fragment}")
    if re.search(r"ToRoute Docker Validation \\d", root_text):
        fail("root CMD launcher must not duplicate the validation version")
    if "exit /b %ERRORLEVEL%" in root_text:
        fail("root CMD launcher may not silently forward and close on ERRORLEVEL")
    if "TOROUTE_NO_PAUSE" in root_text or "TOROUTE_AUTOMATION" in root_text or "TOROUTE_NO_PAUSE" in cmd_text or "TOROUTE_AUTOMATION" in cmd_text:
        fail("interactive launcher may not honor user-controlled no-pause environment variables")
    if root_text.index("launcher-bootstrap.log") > root_text.index('"%ComSpec%" /d /k call "%~f0"'):
        fail("bootstrap log must be configured before the persistent child console is started")
    if cmd_text.index("TOROUTE_INVOKED_BY_ROOT") > cmd_text.index("PowerShell:"):
        fail("inner launcher must redirect direct execution before PowerShell discovery")


    docs_text = (ROOT / "docs/DOCKER_VALIDATION_WINDOWS_JA.md").read_text(encoding="utf-8")
    if "TOROUTE_NO_PAUSE" in docs_text or "TOROUTE_AUTOMATION" in docs_text:
        fail("user documentation may not expose a no-pause bypass")
    if "sanitize-validation-evidence.py" not in docs_text:
        fail("Windows evidence documentation must distinguish raw private evidence from a public-safe summary")

    print("Windows validation static contract passed")


if __name__ == "__main__":
    main()
