#!/usr/bin/env python3
"""Compare native reword editors and generated exec/amend lines on real 50-commit repositories."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time


def run(helper: Path, mode: str):
    with tempfile.TemporaryDirectory(prefix="jit-rebase-spike-") as temporary:
        root = Path(temporary).resolve()
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                   GIT_AUTHOR_NAME="Spike Author", GIT_AUTHOR_EMAIL="author@jit.invalid",
                   GIT_COMMITTER_NAME="Spike Committer", GIT_COMMITTER_EMAIL="committer@jit.invalid")

        def git(*arguments):
            result = subprocess.run(["git", *arguments], cwd=root, env=env, check=True,
                                    capture_output=True, text=True)
            return result.stdout.strip()

        git("init", "-q")
        git("commit", "--allow-empty", "-qm", "Base")
        base = git("rev-parse", "HEAD")
        commits = []
        for index in range(50):
            (root / f"file-{index}.txt").write_text(f"{index}\n")
            git("add", "--", f"file-{index}.txt")
            git("commit", "-qm", f"Commit {index}")
            commits.append(git("rev-parse", "HEAD"))
        tree = git("rev-parse", "HEAD^{tree}")
        directory = root / ".git/jit-interactive-rebase"
        directory.mkdir(mode=0o700)
        messages = {oid: f"Reword {index}: quotes ' \" $() `literal`\n\nسلام {index}"
                    for index, oid in enumerate(commits)}
        (directory / "manifest.json").write_text(json.dumps({"gitDirectory": str(root / ".git"), "messages": messages}))
        todo = []
        for index, oid in enumerate(commits):
            if mode == "native-editors":
                todo.append(f"reword {oid}")
            else:
                message = directory / f"message-{index}"
                message.write_text(messages[oid] + "\n")
                todo += [f"pick {oid}", "exec git -c commit.gpgSign=false commit --amend --allow-empty --cleanup=verbatim -F " + shlex.quote(str(message))]
        (directory / "todo").write_text("\n".join(todo) + "\n")
        for path in directory.iterdir():
            path.chmod(0o600)
        env.update(JIT_REBASE_DIRECTORY=str(directory),
                   GIT_SEQUENCE_EDITOR=shlex.quote(str(helper)) + " sequence-editor",
                   GIT_EDITOR=shlex.quote(str(helper)) + " message-editor")
        start = time.perf_counter()
        git("-c", "commit.cleanup=verbatim", "-c", "commit.gpgSign=false", "rebase", "-i", "--force-rebase",
            "--keep-empty", "--no-autostash", "--no-autosquash", "--no-update-refs", base)
        elapsed = time.perf_counter() - start
        rewritten = git("log", "--reverse", "--format=%B%x00", base + "..HEAD").split("\0")
        actual = [message.strip() for message in rewritten if message.strip()]
        assert actual == list(messages.values())
        assert git("rev-parse", "HEAD^{tree}") == tree
        assert git("log", "-1", "--format=%an|%cn") == "Spike Author|Spike Committer"
        return {"mode": mode, "commits": 50, "elapsed_seconds": round(elapsed, 3),
                "all_messages_exact": True, "tree_unchanged": True, "author_preserved": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    helper = args.helper.resolve()
    if not helper.is_file():
        parser.error("build jit-git-helper first")
    results = {"git": subprocess.check_output(["git", "--version"], text=True).strip(),
               "results": [run(helper, mode) for mode in ["native-editors", "exec-amend"]]}
    text = json.dumps(results, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print(text, end="")
