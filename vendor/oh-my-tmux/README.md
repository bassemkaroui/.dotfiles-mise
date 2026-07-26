# vendored: oh-my-tmux `.tmux.conf.local` base snapshot

`tmux.conf.local` here is a **byte-for-byte copy** of upstream oh-my-tmux's
`.tmux.conf.local` *template* at the version our customized copy was last synced
against. It is the **base** for the 3-way merge done by `mise run update:tmux-local`:

    base   = vendor/oh-my-tmux/tmux.conf.local   (this file — last-synced upstream template)
    ours   = home/.config/tmux/tmux.conf.local   (the template + our customizations)
    theirs = ~/.tmux/.tmux.conf.local            (upstream now, in the fast-forwarded clone)

`update:tmux-local` folds `base → theirs` changes into `ours`, then advances this
snapshot to the new upstream version. **Do not hand-edit it** — any drift from the
pristine upstream template corrupts the merge base and produces spurious conflicts.
The task rewrites it automatically after a successful merge.

Upstream: <https://github.com/gpakosz/.tmux> (`.tmux.conf.local`).
