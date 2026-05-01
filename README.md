# ssr4

**sineptic's spaced repetition** — a command-line spaced repetition system written in Zig.

## Overview

`ssr4` is an early-stage CLI application for learning and memorization through spaced repetition. It provides an interactive, terminal-based flashcard experience where you type answers from memory and rate your recall.

## Features

- **Interactive review** with full terminal support (arrow keys, delete, UTF-8)
- **SQLite storage** for persistent task management
- **Task parsing** with inline notes, plain text, and hidden blocks
- **Self-rating system**: `1=again`, `2=hard`, `3=good`, `4=easy`
- **Upcoming**: [FSRS-v6](https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm) scheduling algorithm with trainable weights

## Installation

Requires Zig 0.16.

```bash
git clone <repo-url>
cd ssr4
zig build -Doptimize=ReleaseSafe
```

The compiled binary will be in `zig-out/bin/ssr4`.

## Usage

Tasks are provided via **stdin** and processed in one of two modes:

### `ssr4 add`

Save a task to the SQLite database (`ssr4.db`). You can either:

- **Type interactively**: Run `ssr4 add` and type your task on stdin, then press `Ctrl+D`.
- **Pipe from a file**:
   ```bash
   cat task.txt | ssr4 add
   ```

### `ssr4 preview`

Run an interactive repetition session. Pipe your task into the preview mode:

```bash
cat task.txt | ssr4 preview
```

This enters a full-screen TUI that clears the terminal, hides the cursor, and presents your task block by block.

### Task Format

Tasks consist of three block types:

| Block Type | Syntax | Behavior |
|------------|--------|----------|
| Plain text | Write it normally | Displayed as-is during review |
| Hidden text | Wrap in backticks `` `like this` `` | Type to recall the answer |
| Comments | Start with `//` | Shown as notes during review |

**Example task (`task.txt`):**

```bash
hello `world`! // a greeting
// a comment
// another comment
plain text here
and `_this too` is hidden
```

## How Review Works

1. The task is parsed into blocks (text, hidden, note).
2. Hidden blocks are shown as `<empty>` — you type the answer.
3. Navigate between blocks with **Tab** / **Shift+Tab**.
4. Submit with **Ctrl+D**.
5. After all blocks are submitted, an overview shows your answers alongside the correct text.
6. Rate your recall:

| Key | Meaning |
|-----|---------|
| `1` | again |
| `2` | hard |
| `3` | good |
| `4` | easy |

## Development Status

`ssr4` is an **experimental prototype**. The core review loop works, but many things are incomplete:

- `preview` mode may crash during or after review
- No scheduling or spaced repetition logic implemented yet
- Frequent breaking changes expected

## License

No license — all rights reserved.
