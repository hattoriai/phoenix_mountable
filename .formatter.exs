locals_without_parens = [
  # options DSL
  option: 2,
  option: 3,
  # routes DSL
  live: 2,
  live: 3,
  live: 4,
  get: 3,
  get: 4,
  post: 3,
  post: 4,
  put: 3,
  put: 4,
  patch: 3,
  patch: 4,
  delete: 3,
  delete: 4,
  forward: 2,
  forward: 3,
  forward: 4,
  live_session: 2,
  live_session: 3,
  scope: 2,
  scope: 3,
  pipe_through: 1,
  pipeline: 2,
  plug: 1,
  plug: 2
]

[
  import_deps: [:phoenix, :ecto, :ecto_sql],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs,heex}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
