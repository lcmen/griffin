defmodule GriffinSSG.Layouts do
  @layout_extnames [".eex"]
  @layouts_max_nesting_level 10
  @compiled_layouts_table :griffin_build_layouts
  @layout_strings_table :griffin_build_layout_strings

  # def render(layout, options) do
  #   assigns = Map.get(options, :assigns, %{})
  #   rerender_partials = Map.get(options, :rerender_partials, true)

  #   content =
  #     options
  #     |> Map.fetch!(:content)
  #     |> EEx.eval_string(assigns: assigns)
  #     |> then(fn content_string ->
  #       case Map.get(options, :content_type, ".md") do
  #         md when md in [".md", ".markdown"] ->
  #           Earmark.as_html!(content_string)

  #         ".eex" ->
  #           content_string
  #       end
  #     end)

  #   layout_assigns =
  #     assigns
  #     |> Map.put(:content, content)
  #     # here we're re-rendering all existing partials when we might only need a very small subset.
  #     # TODO render only required partials by looking at args in the quoted expression for `layout`
  #     |> then(fn current_assigns ->
  #       if rerender_partials do
  #         Map.update(current_assigns, :partials, %{}, fn partials ->
  #           partials
  #           |> Enum.map(fn partial ->
  #             {compiled, _bindings} = Code.eval_quoted(partial, assigns: current_assigns)
  #             compiled
  #           end)
  #           |> Enum.into(%{})
  #         end)
  #       else
  #         current_assigns
  #       end
  #     end)
  #     |> Enum.to_list()

  #   {result, _bindings} = Code.eval_quoted(layout, assigns: layout_assigns)
  #   result
  # end

  def compile_layouts(layouts_dir) do
    try do
      :ets.new(@compiled_layouts_table, [:ordered_set, :public, :named_table])
      :ets.new(@layout_strings_table, [:ordered_set, :public, :named_table])
    rescue
      ArgumentError ->
        :ok
    end

    layout_partials_dir = layouts_dir <> "/partials"

    layout_files = GriffinSSG.Filesystem.search_directory(layouts_dir, @layout_extnames)
    layout_names = Enum.map(layout_files, &Path.basename(&1, Path.extname(&1)))
    num_layouts = length(layout_files)

    result =
      Enum.reduce_while(1..@layouts_max_nesting_level, layout_files, fn pass, acc ->
        case compile_layouts_rec(acc, layout_names) do
          :ok ->
            {:halt, :ok}

          not_compiled when pass < @layouts_max_nesting_level ->
            {:cont, not_compiled}

          not_compiled ->
            {:halt, {:error, :partial_failure, not_compiled}}
        end
      end)

    case result do
      :ok ->
        partial_layouts =
          GriffinSSG.Filesystem.search_directory(layout_partials_dir, @layout_extnames)

        num_partials = length(partial_layouts)

        # compile partials
        partials =
          Enum.reduce(partial_layouts, %{}, fn filepath, acc ->
            Map.put(
              acc,
              String.to_atom(Path.basename(filepath, Path.extname(filepath))),
              EEx.compile_file(filepath)
            )
          end)

        :ets.insert(@compiled_layouts_table, {:__partials__, partials})

        # compile fallback layout
        insert_layout("__fallback__", fallback_html_layout())

        {:ok, num_layouts, num_partials}

      {:error, :partial_failure, not_compiled} ->
        errored_layouts =
          not_compiled
          |> Enum.map(&Path.basename(&1, Path.extname(&1)))
          |> Enum.sort()
          |> Enum.join(", ")

        {:error, :layout_cyclic_dependency, errored_layouts}
    end
  end

  def fallback_list_collection_layout do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <title><%= @collection_name |> Atom.to_string() |> String.capitalize() %></title>
      </head>
      <body>
        <h1><%= @collection_name |> Atom.to_string() |> String.capitalize() %></h1>
        <ul>
        <%= for {collection_value, _pages} <- @collection_values do %>
        <li><a href="/<%= @collection_name %>/<%= collection_value %>/"><%= collection_value %></a></li>
        <% end %>
        </ul>
      </body>
    </html>
    """
  end

  def fallback_show_collection_layout do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <title>Pages with <%= @collection_name %> <%= @collection_value %></title>
      </head>
      <body>
      <h1>Pages with <%= @collection_name %> `<%= @collection_value %>`</h1>
      <ul>
      <%= for page <- @collection_value_pages do %>
      <li><a href="<%= page.data.url %>"><%= page.data.title %></a></li>
      <% end %>
      </ul>
      </body>
    </html>
    """
  end

  defp fallback_html_layout do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="X-UA-Compatible" content="ie=edge">
        <title><%= @title %></title>
      </head>
      <body>
      <%= @content %>
      </body>
    </html>
    """
  end

  defp compile_layouts_rec(layouts, not_compiled \\ [], layout_names)

  defp compile_layouts_rec([], [], _layout_names), do: :ok
  defp compile_layouts_rec([], not_compiled, _layout_names), do: not_compiled

  defp compile_layouts_rec([file | remaining], acc, layout_names) do
    layout_name = Path.basename(file, Path.extname(file))

    layout =
      file
      |> File.read!()
      |> GriffinSSG.parse()
      |> then(fn {:ok, result} -> result end)

    case maybe_compile_layout(layout, layout_name, layout_names) do
      {:error, :parent_layout_not_found} ->
        compile_layouts_rec(remaining, [file | acc], layout_names)

      :ok ->
        compile_layouts_rec(remaining, acc, layout_names)
    end
  end

  defp maybe_compile_layout(%{front_matter: front_matter, content: content}, name, all_layouts) do
    if front_matter[:layout] == nil do
      # layout has no parent
      insert_layout(name, content)
      insert_layout_string(name, content)
      :ok
    else
      parent = front_matter.layout

      unless parent in all_layouts do
        Mix.raise(
          "Layout #{name} specified parent layout `#{parent}` but no such layout was found"
        )
      end

      parent_layout = fetch_layout_string(parent)

      if parent_layout == nil do
        {:error, :parent_layout_not_found}
      else
        # there is currently no better way of doing this that I know of,
        # since compiled or eval'ed EEx strings replace all variables
        # and we only want to replace @content.
        # This isn't ideal because users might use different spacing
        # which wouldn't work with the way we're merging the layouts.
        content_patterns = [
          "<%= @content %>",
          "<%=@content%>",
          "<%=@content %>",
          "<%= @content%>"
        ]

        pattern =
          Enum.reduce(content_patterns, "<%= @content %>", fn pattern, acc ->
            if String.contains?(parent_layout, pattern) do
              pattern
            else
              acc
            end
          end)

        merged_content = String.replace(parent_layout, pattern, content)
        insert_layout(name, merged_content)
        insert_layout_string(name, merged_content)
        :ok
      end
    end
  end

  defp insert_layout(name, string) do
    ets_insert(@compiled_layouts_table, name, EEx.compile_string(string))
  end

  defp insert_layout_string(name, string) do
    ets_insert(@layout_strings_table, name, string)
  end

  defp fetch_layout_string(name) do
    ets_lookup(@layout_strings_table, name)
  end

  # defp fetch_layout(name) do
  #   ets_lookup(@compiled_layouts_table, name)
  # end

  defp ets_insert(table, key, value) do
    :ets.insert(table, {key, value})
  end

  defp ets_lookup(table, key) do
    case :ets.lookup(table, key) do
      [] -> nil
      [{^key, value}] -> value
    end
  end
end
