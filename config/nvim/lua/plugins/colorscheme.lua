return {
  -- add the onedarkpro theme
  { "olimorris/onedarkpro.nvim", priority = 1000 },

  -- tell LazyVim to use it
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "onelight",
    },
  },
}
