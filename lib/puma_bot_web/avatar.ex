defmodule PumaBotWeb.Avatar do
  @moduledoc """
  Generates deterministic SVG avatars locally based on a string identifier.
  Returns data URIs that can be used directly in img src attributes.
  """

  @size 64
  @grid_size 5

  @doc """
  Generate a data URI for an identicon-style avatar.
  The same input always produces the same avatar.
  """
  def generate(nil), do: generate("unknown")
  def generate({:name, name}), do: generate(name)
  def generate(identifier) when is_binary(identifier) do
    hash = :crypto.hash(:md5, identifier)
    hash_bytes = :binary.bin_to_list(hash)

    # Extract color from first 3 bytes
    [r, g, b | rest] = hash_bytes
    # Ensure colors are vibrant by keeping saturation high
    {h, s, _l} = rgb_to_hsl(r, g, b)
    {r2, g2, b2} = hsl_to_rgb(h, max(s, 0.5), 0.45)
    color = "rgb(#{r2}, #{g2}, #{b2})"

    # Generate symmetric pattern from remaining bytes
    pattern = generate_pattern(rest)

    svg = build_svg(pattern, color)
    "data:image/svg+xml;base64,#{Base.encode64(svg)}"
  end

  defp generate_pattern(bytes) do
    # Create a 5x5 grid, but only use left half + center (mirrored)
    cells_needed = div(@grid_size * (@grid_size + 1), 2)  # 15 cells for 5x5

    bytes
    |> Enum.take(cells_needed)
    |> Enum.with_index()
    |> Enum.flat_map(fn {byte, idx} ->
      if rem(byte, 2) == 0 do
        # Convert linear index to grid coordinates (left half + center)
        {row, col} = index_to_coords(idx)

        # Add the cell and its mirror
        if col == div(@grid_size, 2) do
          [{row, col}]  # Center column, no mirror
        else
          [{row, col}, {row, @grid_size - 1 - col}]  # Mirror horizontally
        end
      else
        []
      end
    end)
  end

  defp index_to_coords(idx) do
    cols_per_row = div(@grid_size, 2) + 1  # 3 for 5x5
    row = div(idx, cols_per_row)
    col = rem(idx, cols_per_row)
    {row, col}
  end

  defp build_svg(pattern, color) do
    cell_size = div(@size, @grid_size)

    rects =
      pattern
      |> Enum.map(fn {row, col} ->
        x = col * cell_size
        y = row * cell_size
        ~s(<rect x="#{x}" y="#{y}" width="#{cell_size}" height="#{cell_size}" fill="#{color}"/>)
      end)
      |> Enum.join("\n  ")

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@size}" height="#{@size}" viewBox="0 0 #{@size} #{@size}">
      <rect width="#{@size}" height="#{@size}" fill="#2a2a3a"/>
      #{rects}
    </svg>
    """
  end

  # Color conversion helpers
  defp rgb_to_hsl(r, g, b) do
    r = r / 255
    g = g / 255
    b = b / 255

    max_c = max(max(r, g), b)
    min_c = min(min(r, g), b)
    l = (max_c + min_c) / 2

    if max_c == min_c do
      {0, 0, l}
    else
      d = max_c - min_c
      s = if l > 0.5, do: d / (2 - max_c - min_c), else: d / (max_c + min_c)

      h = cond do
        max_c == r -> (g - b) / d + (if g < b, do: 6, else: 0)
        max_c == g -> (b - r) / d + 2
        true -> (r - g) / d + 4
      end

      {h / 6, s, l}
    end
  end

  defp hsl_to_rgb(h, s, l) do
    if s == 0 do
      v = round(l * 255)
      {v, v, v}
    else
      q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
      p = 2 * l - q

      r = hue_to_rgb(p, q, h + 1/3)
      g = hue_to_rgb(p, q, h)
      b = hue_to_rgb(p, q, h - 1/3)

      {round(r * 255), round(g * 255), round(b * 255)}
    end
  end

  defp hue_to_rgb(p, q, t) do
    t = cond do
      t < 0 -> t + 1
      t > 1 -> t - 1
      true -> t
    end

    cond do
      t < 1/6 -> p + (q - p) * 6 * t
      t < 1/2 -> q
      t < 2/3 -> p + (q - p) * (2/3 - t) * 6
      true -> p
    end
  end
end
