"""
Agent-VM driver: executes Python cells received over a Unix socket so external
tools can drive the running VM via the native NixOS test-driver API.

This file is read verbatim into the testScript of a runNixOSTest by
the `mkAgentVm` helper in the consuming flake. The Nix wrapper prepends
`SOCKET_NAME = "...";`.

Trust boundary: the socket lives in $XDG_RUNTIME_DIR (user-private). Running
`eval`/`exec` against arbitrary input is intentional — only the owning user
can connect.

Wire protocol (one request and response per connection):
  Request  : a complete Python program, terminated by write-side EOF.
  Response : one line of JSON, either
               {"ok": true,  "result": <repr|null>}
             or
               {"ok": false, "error":  <traceback>}

The final expression of a program is returned, like a Python REPL or notebook
cell. Earlier statements and definitions execute normally in a namespace that
persists across connections.
"""

import ast
import base64
import json
import linecache
import os
import socket
import traceback
from pathlib import Path

start_all()

# The harness always names its test node `vm`. Bind the conventional `machine`
# name explicitly instead of relying on the test driver's deprecated
# single-node compatibility wrapper.
machine = vm


def sh(script, timeout=60, strict=False):
    """Run a shell script in the guest. Returns `(exit_code, output)`.

    Safer than `machine.execute`, which inlines the script into
    `bash -c 'set -euo pipefail; <script>'`: there the script text is in the
    wrapper's own command line (`pkill -f` matches and kills the caller), one
    non-zero command silently discards every later line, and stderr is lost to
    the console log. Running from a file avoids all three. Exit code 124 means
    `timeout` seconds elapsed.
    """
    body = f"set -euo pipefail\n{script}" if strict else script
    blob = base64.b64encode(body.encode()).decode()
    # exec so the in-guest timeout signals the script, not a wrapper shell;
    # nothing is left to remove the temp file, but guest /tmp is ephemeral.
    return machine.execute(
        "script=$(mktemp /tmp/agent-sh.XXXXXX)\n"
        f"printf %s {blob} | base64 -d >\"$script\"\n"
        f'exec timeout {timeout} bash "$script" 2>&1'
    )


# Keep user assignments out of the server's own globals while preserving all
# symbols provided by the NixOS test driver (`machine`, `nodes`, `subtest`, ...)
# and `sh` above.
NS = globals().copy()


def _execute(src, filename):
    """Execute one Python cell and return the value of its final expression."""
    tree = ast.parse(src, filename=filename, mode="exec")

    if tree.body and isinstance(tree.body[-1], ast.Expr):
        prefix = ast.Module(body=tree.body[:-1], type_ignores=tree.type_ignores)
        expression = ast.Expression(body=tree.body[-1].value)

        # Compile the complete cell before running any of it. A syntax error in
        # the final expression must not leave effects from the prefix behind.
        prefix_code = compile(prefix, filename, "exec")
        expression_code = compile(expression, filename, "eval")
        exec(prefix_code, NS)
        return eval(expression_code, NS)

    code = compile(tree, filename, "exec")
    exec(code, NS)
    return None


def _format_error(error):
    """Format errors with agent source frames but without driver internals."""
    formatted = traceback.TracebackException.from_exception(
        error,
        capture_locals=False,
    )

    def retain_agent_frames(exception):
        exception.stack = traceback.StackSummary.from_list(
            frame for frame in exception.stack if frame.filename.startswith("<agent:")
        )
        if exception.__cause__ is not None:
            retain_agent_frames(exception.__cause__)
        if exception.__context__ is not None:
            retain_agent_frames(exception.__context__)
        if exception.exceptions is not None:
            for nested in exception.exceptions:
                retain_agent_frames(nested)

    retain_agent_frames(formatted)
    return "".join(formatted.format()).rstrip()


runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
sock_path = Path(runtime_dir) / SOCKET_NAME
sock_path.unlink(missing_ok=True)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    srv.bind(str(sock_path))
    srv.listen(1)
    request_number = 0
    while True:
        conn, _ = srv.accept()
        with conn:
            try:
                with conn.makefile("r", encoding="utf-8") as request:
                    source = request.read()

                request_number += 1
                filename = f"<agent:{request_number}>"
                linecache.cache[filename] = (
                    len(source),
                    None,
                    source.splitlines(keepends=True),
                    filename,
                )

                value = _execute(source, filename)
                response = {
                    "ok": True,
                    "result": None if value is None else repr(value),
                }
            except SystemExit:
                raise
            except BaseException as error:
                response = {"ok": False, "error": _format_error(error)}

            try:
                conn.sendall((json.dumps(response) + "\n").encode())
            except OSError:
                # A timed-out or interrupted client must not take down the VM.
                pass
finally:
    srv.close()
    sock_path.unlink(missing_ok=True)
