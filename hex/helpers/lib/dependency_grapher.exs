# Log to stderr instead of stdout
:logger.remove_handler(:default)
:logger.add_handler(:to_stderr, :logger_std_h, %{config: %{type: :standard_error}})
Mix.shell(Mix.Shell.Quiet)

defmodule DependencyGrapher do
  @moduledoc """
  Builds a dependency graph for a Mix project using the `sbom` library.

  Generates a CycloneDX BOM for the given project directory and returns a list
  of dependency entries, each with the shape:
    %{purl: "pkg:hex/name@version", direct: bool, runtime: bool, dependencies: ["pkg:hex/..."]}

  PURLs are stripped of qualifiers to match the format used by all other Dependabot graphers.
  """

  def run(project_dir) do
    {:ok, _applications} = Application.ensure_all_started(:sbom)

    # Ignore duplicate module warnings when loading the user's mix.exs.
    Code.put_compiler_option(:ignore_module_conflict, true)

    # Load the user's project so Mix has a root component (needed for direct/indirect detection).
    app_name =
      project_dir
      |> :erlang.crc32()
      |> Integer.digits(26)
      |> Enum.map(&(&1 + ?a))
      |> List.to_string()
      |> String.to_atom()

    bom =
      Mix.Project.in_project(app_name, project_dir, fn _module ->
        SBoM.CycloneDX.bom(system_dependencies: false, version: "1.7")
      end)

    root_bom_ref = bom.metadata.component.bom_ref

    root_dep_refs =
      bom.dependencies
      |> Enum.find(%SBoM.CycloneDX.V17.Dependency{}, &match?(%{ref: ^root_bom_ref}, &1))
      |> Map.get(:dependencies, [])
      |> Enum.map(& &1.ref)
      |> MapSet.new()

    ref_to_purl =
      Map.new(bom.components, fn c -> {c.bom_ref, canonical_purl(c.purl)} end)

    result =
      for component <- bom.components do
        component_bom_ref = component.bom_ref

        child_purls =
          bom.dependencies
          |> Enum.find(%SBoM.CycloneDX.V17.Dependency{}, &match?(%{ref: ^component_bom_ref}, &1))
          |> Map.get(:dependencies, [])
          |> Enum.map(&Map.get(ref_to_purl, &1.ref))
          |> Enum.reject(&is_nil/1)

        %{
          purl: canonical_purl(component.purl),
          direct: MapSet.member?(root_dep_refs, component.bom_ref),
          runtime: component.scope != :SCOPE_EXCLUDED,
          dependencies: child_purls
        }
      end

    {:ok, result}
  end

  # Strip qualifiers and subpath from a PURL string, keeping only
  # pkg:type/name@version to match the format used by all other Dependabot graphers.
  defp canonical_purl(purl_str) do
    case String.split(purl_str, "?", parts: 2) do
      [base, _qualifiers] -> base
      [base] -> base
    end
  end
end

project_dir = File.cwd!()

result =
  case DependencyGrapher.run(project_dir) do
    {:ok, graph} ->
      {:ok, graph}
  end

if not is_nil(result) do
  result
  |> :erlang.term_to_binary()
  |> Base.encode64()
  |> IO.write()
end
