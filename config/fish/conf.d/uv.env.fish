
fish_add_path --prepend "$HOME/.nvm/current/bin"
fish_add_path --prepend "$HOME/.cargo/bin"
fish_add_path --prepend "$HOME/.local/go/bin"
fish_add_path --prepend "$HOME/.local/bin"

if test -f "$HOME/.local/bin/env.fish"
    source "$HOME/.local/bin/env.fish"
end

if test -f "$HOME/.cargo/env.fish"
    source "$HOME/.cargo/env.fish"
end
