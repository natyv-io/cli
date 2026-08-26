//! Real, minimal Zed extension for `ntx-lsp` -- Stage 1 of
//! `~/.claude/plans/lexical-wishing-penguin.md`. Same scope as the VS Code
//! extension at `../vscode-ntx/`: registers no feature providers of its
//! own, exists only to prove Zed can launch and handshake with `ntx-lsp`
//! over stdio.
//!
//! `ntx-lsp` isn't published/on PATH anywhere yet (Stage 6 will add it to
//! the same brew tap as `natyv`), so `worktree.which` is the correct
//! long-term lookup either way -- once that lands, this needs no changes
//! at all.

use zed_extension_api::{self as zed, Command, LanguageServerId, Result, Worktree};

struct NtxExtension;

impl zed::Extension for NtxExtension {
    fn new() -> Self {
        NtxExtension
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Command> {
        let path = worktree
            .which("ntx-lsp")
            .ok_or_else(|| "ntx-lsp not found on PATH".to_string())?;
        Ok(Command {
            command: path,
            args: Vec::new(),
            env: Vec::new(),
        })
    }
}

zed::register_extension!(NtxExtension);
