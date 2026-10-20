defmodule PhoenixMountable.Install do
  @schema [
    otp_app: [type: :atom, required: true, doc: "The library's application."],
    mounts: [
      type: {:list, :any},
      default: [],
      doc:
        "`{definition, path}` or `{definition, path, opts}`, opts as in `PhoenixMountable.Igniter.mount/4`."
    ],
    migrations: [type: :atom, doc: "The library's `PhoenixMountable.Migrations` module."],
    hook: [
      type: {:tuple, [:string, :string]},
      doc: "`{hook, package}`: the hook's name and its npm package."
    ],
    css: [
      type: {:list, :any},
      default: [],
      doc: "Style sheets, as in `PhoenixMountable.Igniter.add_css_imports/4`."
    ],
    tailwind: [
      type: :boolean,
      default: false,
      doc: "Add the library to the host's Tailwind sources."
    ],
    supervisor: [type: :boolean, default: false, doc: "Start the mounts' processes at boot."],
    shortdoc: [
      type: :string,
      doc: "The task's short doc. Defaults to `Installs <library> in a Phoenix app`."
    ],
    manual: [type: :string, doc: "What to do by hand, for a host without Igniter."]
  ]

  @moduledoc """
  A mountable library's installer, declared in one `use`:

      defmodule Mix.Tasks.MyLib.Install do
        use PhoenixMountable.Install,
          otp_app: :my_lib,
          mounts: [
            {MyLib.Router, "/my_lib", scope: "/admin", options: "resolver: {web}.MyLibResolver"}
          ],
          migrations: MyLib.Migrations,
          hook: {"MyLib", "my_lib"},
          css: ["my_lib.css", {"my_lib-dark.css", :comment}]
      end

  Hosts run `mix igniter.install my_lib`, which adds the dependency and
  runs the task, or `mix my_lib.install` once the dependency is there.
  [Igniter](https://hexdocs.pm/igniter) shows every change as a diff
  before it writes, and each step is idempotent, so running it again
  changes nothing.

  The steps, each one when its option is given, in this order:

    1. `:mounts` - mounts each definition in the host's router
       (`PhoenixMountable.Igniter.mount/4`), with its options.
    2. `:migrations` - writes the migration that installs the library's
       tables, or upgrades them (`PhoenixMountable.Igniter.gen_migration/3`).
    3. `:hook` - adds a LiveView hook to `assets/js/app.js`
       (`PhoenixMountable.Igniter.add_hook/4`), for components that render
       in the host's own pages.
    4. `:css` - imports style sheets in `assets/css/app.css`
       (`PhoenixMountable.Igniter.add_css_imports/4`).
    5. `:tailwind` - makes the host's Tailwind scan the library
       (`PhoenixMountable.Igniter.add_tailwind_source/2`), for libraries
       styled by the host.
    6. `:supervisor` - starts the mounts' processes at boot
       (`PhoenixMountable.Igniter.add_supervisor/2`).

  Then the library's own steps, in `c:install/1` (a child of the host's
  application with its options, a module of the host's to write):

      @impl PhoenixMountable.Install
      def install(igniter) do
        Igniter.Project.Application.add_new_child(igniter, {MyLib, repo: MyApp.Repo})
      end

  ## Without Igniter

  Igniter is an optional dependency of the library: in a host without it,
  the task says how to get it, and how to make the changes by hand (the
  `:manual` option, the text of the library's guide).

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @doc """
  The library's own steps, after the declared ones.
  """
  @callback install(igniter :: term) :: term

  @optional_callbacks install: 1

  @doc false
  def __config__(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} ->
        Map.new(opts)

      {:error, error} ->
        raise ArgumentError, "invalid options for use PhoenixMountable.Install: #{error.message}"
    end
  end

  @doc false
  def __shortdoc__(config) do
    config[:shortdoc] ||
      "Installs #{Macro.camelize(Atom.to_string(config.otp_app))} in a Phoenix app"
  end

  defmacro __using__(opts), do: __using__(opts, Code.ensure_loaded?(Igniter))

  @doc false
  # The task as Igniter's, or as a plain Mix task in a host without it.
  # Chosen here, when the macro expands, and not by an `if` in the quote:
  # the compiler expands the macros of both branches of an `if`, so `use
  # Igniter.Mix.Task` failed to compile where Igniter is not a dependency.
  def __using__(opts, igniter?) do
    config =
      quote bind_quoted: [opts: opts] do
        @phoenix_mountable_install PhoenixMountable.Install.__config__(opts)
        @shortdoc PhoenixMountable.Install.__shortdoc__(@phoenix_mountable_install)
        @behaviour PhoenixMountable.Install
      end

    task =
      if igniter? do
        quote do
          use Igniter.Mix.Task

          @impl Igniter.Mix.Task
          def info(_argv, _composing_task) do
            %Igniter.Mix.Task.Info{group: @phoenix_mountable_install.otp_app}
          end

          @impl Igniter.Mix.Task
          def igniter(igniter) do
            PhoenixMountable.Install.run(igniter, __MODULE__, @phoenix_mountable_install)
          end
        end
      else
        quote do
          use Mix.Task

          @impl Mix.Task
          def run(_argv) do
            PhoenixMountable.Install.without_igniter(@phoenix_mountable_install)
          end
        end
      end

    [config, task]
  end

  if Code.ensure_loaded?(Igniter) do
    @doc false
    def run(igniter, module, config) do
      igniter
      |> mounts(config.mounts)
      |> step(config[:migrations], &PhoenixMountable.Igniter.gen_migration(&1, &2))
      |> step(config[:hook], fn igniter, {hook, package} ->
        PhoenixMountable.Igniter.add_hook(igniter, hook, package)
      end)
      |> step(
        non_empty(config.css),
        &PhoenixMountable.Igniter.add_css_imports(&1, config.otp_app, &2)
      )
      |> step(config.tailwind || nil, fn igniter, true ->
        PhoenixMountable.Igniter.add_tailwind_source(igniter, config.otp_app)
      end)
      |> step(config.supervisor || nil, fn igniter, true ->
        PhoenixMountable.Igniter.add_supervisor(igniter)
      end)
      |> then(fn igniter ->
        if Code.ensure_loaded?(module) and function_exported?(module, :install, 1),
          do: module.install(igniter),
          else: igniter
      end)
    end

    defp mounts(igniter, mounts) do
      Enum.reduce(mounts, igniter, fn
        {definition, path}, igniter ->
          PhoenixMountable.Igniter.mount(igniter, definition, path)

        {definition, path, opts}, igniter ->
          PhoenixMountable.Igniter.mount(igniter, definition, path, opts)
      end)
    end

    defp step(igniter, nil, _fun), do: igniter
    defp step(igniter, value, fun), do: fun.(igniter, value)

    defp non_empty([]), do: nil
    defp non_empty(list), do: list
  end

  @doc false
  def without_igniter(config) do
    app = config.otp_app

    Mix.shell().info("""
    The installer of #{app} needs Igniter, which edits your code safely and shows
    each change first. Either run it with Igniter's archive:

        mix archive.install hex igniter_new
        mix igniter.install #{app}

    or add {:igniter, "~> 0.6", only: [:dev, :test]} to your deps and run this task
    again.
    #{if config[:manual], do: "\nOr make the changes by hand:\n\n" <> config.manual, else: ""}
    """)
  end
end
