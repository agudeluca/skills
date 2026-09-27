# Global Rules

## "Fixeame el git" - Git Authentication Troubleshooting

When the user says "fixeame el git" (or similar: "fix git", "git no anda", "no puedo pushear"), run this diagnostic sequence:

1. **Check the error**: Ask the user to paste the error, or try `git push --dry-run 2>&1` to reproduce it.
2. **Check remote URL**: Run `git remote -v`. If it's HTTPS and should be SSH, offer to switch with `git remote set-url origin git@github.com:<org>/<repo>.git`.
3. **Check global git config for token overrides**: Run `git config --global --list` and look for `url.*.insteadof` entries that rewrite SSH/HTTPS URLs with expired tokens (e.g., `x-access-token:ghs_...`). These are commonly left by GitHub Actions or CI tools and silently break authentication.
4. **Remove expired token rewrites**: If found, remove them with `git config --global --unset-all <key>`. Preserve useful rewrites like `url.git@github.com:.insteadOf=https://github.com/` that map HTTPS to SSH.
5. **Verify SSH**: Run `ssh -T git@github.com` to confirm SSH authentication works.
6. **Retry**: Run `git push` to confirm the fix.

Always explain what you're doing and why at each step. Respond in the same language the user is using.

## Git Constraints

- **Avoid git worktrees by default.** Work directly on the current branch.
- **Exception — `.worktrees/` inside the repo:** when the user needs to keep the main checkout free for parallel work on another branch, you may create a worktree at `<repo>/.worktrees/<name>`. Never put worktrees as siblings of the repo or in unrelated paths. Add `.worktrees/` to `.git/info/exclude` (local-only, no commit) the first time you create one in a repo. Always confirm with the user before creating a worktree.

## "Clean metros" - Matar procesos de Metro Bundler

When the user says "clean metros" (or similar: "clean all metros", "limpiar metros", "clear metro", "clean metro cache", "metros sucios", "kill metro"), run this sequence:

1. **Matar procesos**: Run `pkill -f "expo start" 2>/dev/null; pkill -f "metro" 2>/dev/null`
2. **Verificar puertos comunes** (8081, 8082, 8089): Run `lsof -i :8081 -i :8082 -i :8089 2>/dev/null | grep LISTEN` — si hay procesos residuales, hacer `kill -9 <PID>` para cada uno.
3. **Limpiar archivos temporales**: Run `find "$TMPDIR" -maxdepth 1 \( -name "react-*" -o -name "metro-*" -o -name "haste-*" \) | xargs rm -rf`
4. **Watchman** (si está instalado): Run `watchman watch-del-all`
5. Confirmar que todo quedó limpio.

Always explain what you're doing and why at each step. Respond in the same language the user is using.
