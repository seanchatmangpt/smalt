defmodule Smalt.Aoq.Arrow.Flatbuf do
  @moduledoc """
  AOQ Arrow schema flatbuffer encode/decode (lane 7, v26.11.6).

  Elixir face of the cgap-arrow `flatbuf.rs` wire law: the closed smalt
  grammar (`Smalt.Aoq.Arrow.Schema`, schema.ex mapping table) <-> the
  Arrow `Message`/`Schema` flatbuffer (Message{version, header_type=1
  (Schema), header, bodyLength}). Shared laws pinned by the
  cross-language courts in both repos: parents-first layout, forward
  i32 offsets, vtable soffset -4, tref-relative voffsets, `ARRO`
  identifier at bytes 4..8, closed grammar (NO Union), DoS fences
  (depth 32, fields 1024). DIV-7 (mirrors flatbuf.rs): Field.children
  is not emitted; type tables carry the children; the decoder reads
  type-table children with a Field.children fallback.
  """

  @depth_cap 32
  @field_cap 1024
  @ident "ARRO"
  @version_v5 4

  alias Smalt.Aoq.Arrow.Schema
  alias Schema.Field

 
@doc """
  Encode a schema message: Message{version: 4 (V5), header_type: 1,
  header: Schema, bodyLength: 0}; schema custom_metadata carries
  `smalt:schema_id`.
  """
  @spec decode(binary()) :: {:ok, Schema.t()} | {:error, term()}
  def decode(bin) when is_binary(bin) and byte_size(bin) >= 8 do
    try do
      case binary_part(bin, 4, 4) do
        @ident -> :ok
        <<0, 0, 0, 0>> -> :ok
        _ -> throw({:error, :bad_identifier})
      end
      tref = u32(bin, 0)
      {vt, vs} = vtable(bin, tref)
      header_type = scalar_u8(bin, tref, vt, vs, 1)
      if header_type != 1 do
        throw({:error, {:not_schema_message, header_type}})
      end
      schema_ref = follow_pos(bin, field_pos(bin, tref, vt, vs, 2))
      {svt, svs} = vtable(bin, schema_ref)
      fields = decode_fields(bin, schema_ref, svt, svs, @depth_cap)
      meta = decode_meta(bin, schema_ref, svt, svs)
      schema_id =
        case meta do
          %{"smalt:schema_id" => v} -> v
          _ -> :flatbuf_external
        end
      {:ok, Schema.new(schema_id, fields)}
    catch
      {:error, _} = e -> e
    end
  rescue
    e in ArgumentError -> {:error, {:bad_offset, e}}
  end

  def decode(_), do: {:error, :too_short}

  defp add(objs, next, spec), do: {next, objs ++ [{next, spec}], next + 1}

  # ---- decode helpers (bin passed everywhere; throw {:error, _}) ----
  defp u32(bin, at), do: :binary.decode_unsigned(rd(bin, at, 4), :little)
  defp i32(bin, at) do
    <<v::32-signed-little>> = rd(bin, at, 4)
    v
  end
  defp u16(bin, at), do: :binary.decode_unsigned(rd(bin, at, 2), :little)
  defp rd(bin, at, n) do
    if at < 0 or at + n > byte_size(bin), do: throw({:error, :bad_offset})
    binary_part(bin, at, n)
  end
  defp vtable(bin, tref) do
    vt = tref - i32(bin, tref)
    vs = u16(bin, vt)
    if vs < 4 or vt + vs > byte_size(bin), do: throw({:error, :bad_table})
    {vt, vs}
  end
  defp field_pos(bin, tref, vt, vs, id) do
    slot = 4 + 2 * id
    if vs >= slot + 2 do
      v = u16(bin, vt + slot)
      if v == 0, do: nil, else: tref + v
    else
      nil
    end
  end
  defp scalar_u8(bin, tref, vt, vs, id) do
    case field_pos(bin, tref, vt, vs, id) do
      nil -> 0
      p -> :binary.decode_unsigned(rd(bin, p, 1))
    end
  end
  defp scalar_i16(bin, tref, vt, vs, id) do
    case field_pos(bin, tref, vt, vs, id) do
      nil -> 0
      p -> :binary.decode_unsigned(rd(bin, p, 2), :little)
    end
  end
  defp scalar_i32(bin, tref, vt, vs, id) do
    case field_pos(bin, tref, vt, vs, id) do
      nil -> 0
      p -> :binary.decode_unsigned(rd(bin, p, 4), :little)
    end
  end
  defp scalar_i64(bin, tref, vt, vs, id) do
    case field_pos(bin, tref, vt, vs, id) do
      nil -> 0
      p -> rd(bin, p, 8) |> :binary.decode_unsigned(:little)
    end
  end
  defp follow_pos(bin, nil), do: throw({:error, :missing_header})
  defp follow_pos(bin, at) do
    p = u32(bin, at) + at
    if p >= byte_size(bin), do: throw({:error, :bad_offset})
    p
  end
  defp string_at(bin, nil), do: ""
  defp string_at(bin, at) do
    sp = follow_pos(bin, at)
    n = u32(bin, sp)
    if sp + 4 + n > byte_size(bin), do: throw({:error, :bad_offset})
    binary_part(bin, sp + 4, n)
  end
  defp voff_vec(bin, tref, vt, vs, id) do
    case field_pos(bin, tref, vt, vs, id) do
      nil -> {nil, 0}
      p ->
        vp = follow_pos(bin, p)
        n = u32(bin, vp)
        if vp + 4 + 4 * n > byte_size(bin) or n > @field_cap,
          do: throw({:error, :field_cap_or_bad_offset})
        {vp + 4, n}
    end
  end
  defp elem_table_ref(bin, base, 0), do: follow_pos(bin, base)
  defp elem_table_ref(bin, base, i), do: follow_pos(bin, base + 4 * i)
  defp table_at(bin, at), do: follow_pos(bin, at)


  defp decode_fields(bin, schema_tref, svt, svs, depth) do
    if depth <= 0, do: throw({:error, :depth_cap})
    {base, n} = voff_vec(bin, schema_tref, svt, svs, 1)
    for i <- 0..(n - 1) do
      fref = elem_table_ref(bin, base, i)
      {fvt, fvs} = vtable(bin, fref)
      decode_field(bin, fref, fvt, fvs, depth)
    end
  end

  defp decode_meta(bin, schema_tref, svt, svs) do
    {base, n} = voff_vec(bin, schema_tref, svt, svs, 2)
    0..(n - 1)
    |> Enum.map(fn i ->
      kref = elem_table_ref(bin, base, i)
      {kvt, kvs} = vtable(bin, kref)
      k = string_at(bin, field_pos(bin, kref, kvt, kvs, 0))
      v = string_at(bin, field_pos(bin, kref, kvt, kvs, 1))
      {k, v}
    end)
    |> Map.new()
  end

  defp decode_field(bin, fref, fvt, fvs, depth) do
    name = string_at(bin, field_pos(bin, fref, fvt, fvs, 0))
    nullable = scalar_u8(bin, fref, fvt, fvs, 1) != 0
    tag = scalar_u8(bin, fref, fvt, fvs, 2)
    ty_ref = field_pos(bin, fref, fvt, fvs, 3)
    if is_nil(ty_ref), do: throw({:error, {:bad_type_tag, tag}})
    ty = decode_type(bin, ty_ref, tag, fref, fvt, fvs, depth)
    dict_ref = field_pos(bin, fref, fvt, fvs, 4)
    ty =
      if dict_ref do
        dref = follow_pos(bin, dict_ref)
        {dvt, dvs} = vtable(bin, dref)
        idx_field_pos = field_pos(bin, dref, dvt, dvs, 1)
        idx_ref = follow_pos(bin, idx_field_pos)
        {ivt, ivs} = vtable(bin, idx_ref)
        idx_tag = scalar_u8(bin, idx_ref, ivt, ivs, 2)
        idx = index_atom(bin, idx_ref, ivt, ivs, idx_tag)
        bits = scalar_i32(bin, dref, dvt, dvs, 3)
        {:dictionary, idx, decode_value_type(bin, ty_ref, tag, depth - 1)}
      else
        ty
      end
    ty
    |> then(fn t ->
      Schema.field(name, t, nullable, decode_field_meta(bin, fref, fvt, fvs))
    end)
  end

  defp decode_field_meta(bin, fref, fvt, fvs) do
    case voff_vec(bin, fref, fvt, fvs, 6) do
      {nil, _} -> %{}
      {base, n} ->
        0..(n - 1)
        |> Enum.map(fn i ->
          kref = elem_table_ref(bin, base, i)
          {kvt, kvs} = vtable(bin, kref)
          k = string_at(bin, field_pos(bin, kref, kvt, kvs, 0))
          v = string_at(bin, field_pos(bin, kref, kvt, kvs, 1))
          {k, v}
        end)
        |> Map.new()
    end
  end

  defp decode_type(bin, ty_pos, tag, fref, fvt, fvs, depth) do
    {tref, tvt, tvs} = open_table(bin, follow_pos(bin, ty_pos))
    decode_type_table(bin, tref, tvt, tvs, tag, fref, fvt, fvs, depth)
  end

  defp open_table(bin, tref) do
    {vt, vs} = vtable(bin, tref)
    {tref, vt, vs}
  end

  defp decode_type_table(bin, tref, vt, vs, tag, fref, fvt, fvs, depth) do
    if depth <= 0, do: throw({:error, :depth_cap})
    case tag do
      6 -> :bool
      5 -> :utf8
      20 -> :large_utf8
      4 -> :binary
      19 -> :large_binary
      2 -> int_atom(scalar_i32(bin, tref, vt, vs, 0), scalar_u8(bin, tref, vt, vs, 1) != 0)
      3 -> float_type(bin, tref, vt, vs)
      8 -> date_type(bin, tref, vt, vs)
      9 -> time_type(bin, tref, vt, vs)
      10 -> ts_type(bin, tref, vt, vs)
      7 -> decimal_type(bin, tref, vt, vs)
      11 -> interval_type(bin, tref, vt, vs)
      12 -> list_type(bin, tref, vt, vs, fref, fvt, fvs, depth) |> elem(0)
      16 -> fsl_type(bin, tref, vt, vs, fref, fvt, fvs, depth)
      13 -> struct_type(bin, tref, vt, vs, fref, fvt, fvs, depth)
      17 -> map_type(bin, tref, vt, vs, fref, fvt, fvs, depth) |> elem(0)
      0 ->
        # pyarrow dictionary indexType quirk: absent tag -> i32 default
        :i32
      other -> throw({:error, {:bad_type_tag, other}})
    end
  end

  defp int_atom(32, false), do: :u32
  defp int_atom(64, false), do: :u64

  defp float_type(bin, tref, vt, vs) do
    case scalar_i16(bin, tref, vt, vs, 0) do
      0 -> :f16
      1 -> :f32
      2 -> :f64
      v -> throw({:error, {:bad_enum, v}})
    end
  end

  defp date_type(bin, tref, vt, vs) do
    case scalar_i16(bin, tref, vt, vs, 0) do
      0 -> :date32
      1 -> :date64
      v -> throw({:error, {:bad_enum, v}})
    end
  end

  defp time_type(bin, tref, vt, vs) do
    u = time_unit(scalar_i16(bin, tref, vt, vs, 0))
    bits = scalar_i32(bin, tref, vt, vs, 1)
    if bits == 32 or bits == 64 do
      {:time, u}
    else
      throw({:error, {:bad_enum, bits}})
    end
  end

  defp time_unit(0), do: :second
  defp time_unit(1), do: :millisecond
  defp time_unit(2), do: :microsecond
  defp time_unit(3), do: :nanosecond
  defp time_unit(v), do: throw({:error, {:bad_enum, v}})

  defp ts_type(bin, tref, vt, vs) do
    u = time_unit(scalar_i16(bin, tref, vt, vs, 0))
    tz_pos = field_pos(bin, tref, vt, vs, 1)
    tz = if tz_pos, do: string_at(bin, tz_pos), else: nil
    {:timestamp, u, tz}
  end

  defp decimal_type(bin, tref, vt, vs) do
    p = scalar_i32(bin, tref, vt, vs, 0)
    s = scalar_i32(bin, tref, vt, vs, 1)
    bits = scalar_i32(bin, tref, vt, vs, 2) || 128
    {:decimal128, p, s}
  end

  defp interval_type(bin, tref, vt, vs) do
    case scalar_i16(bin, tref, vt, vs, 0) do
      0 -> {:interval, :year_month}
      1 -> {:interval, :day_time}
      2 -> {:interval, :month_day_nano}
      v -> throw({:error, {:bad_enum, v}})
    end
  end

  defp kv_graph(pairs, objs, n) when pairs == [] do
    {0, objs, n}
  end

  defp kv_graph(pairs, objs, n) do
    {pairs_ids, {objs_a, n_a}} =
      Enum.map_reduce(pairs, {objs, n}, fn {k, v}, {objs_acc, n_acc} ->
        {k_id, objs_x, n_x} = add(objs_acc, n_acc, {:string, k})
        {v_id, objs_y, n_y} = add(objs_x, n_x, {:string, v})
        {{k_id, v_id}, {objs_y, n_y}}
      end)

    {kv_refs, {objs_b, n_b}} =
      Enum.map_reduce(pairs_ids, {objs_a, n_a}, fn {k_id, v_id}, {objs_acc, n_acc} ->
        {kv_id, objs_z, n_z} = add(objs_acc, n_acc, {:table, 2, [{0, {:off, k_id}}, {1, {:off, v_id}}]})
        {kv_id, {objs_z, n_z}}
      end)

    {kv_vec_id, objs_c, n_c} = add(objs_b, n_b, {:voff_vec, kv_refs})
    {kv_vec_id, objs_c, n_c}
  end

  defp decode_value_type(bin, ty_ref, tag, depth) do
    {tref, vt, vs} = open_table(bin, follow_pos(bin, ty_ref))
    decode_type_table(bin, tref, vt, vs, tag, nil, nil, nil, depth)
  end

  defp index_atom(bin, idx_ref, ivt, ivs, idx_tag) do
    if idx_tag == 0 do
      # pyarrow writes the dictionary indexType Field WITHOUT a type union
      # (tag 0): i32 is the recorded default (flatbuf.rs same law).
      :i32
    else
      case field_pos(bin, idx_ref, ivt, ivs, 3) do
        nil -> :i32
        p -> decode_type_table(bin, follow_pos(bin, p), 0, 0, idx_tag, nil, nil, nil, 32)
      end
    end
  end

  # Nested types: children ride the type table slot 5, with the
  # Field.children fallback (DIV-7 / pyarrow goldens law).
  defp children_of(bin, tref, vt, vs, fref, fvt, fvs) do
    case voff_vec(bin, tref, vt, vs, 5) do
      {nil, _} ->
        if is_nil(fref) do
          throw({:error, :children_missing})
        else
          voff_vec(bin, fref, fvt, fvs, 5)
        end
      found ->
        found
    end
  end

  defp list_type(bin, tref, vt, vs, fref, fvt, fvs, depth) do
    {base, n} = children_of(bin, tref, vt, vs, fref, fvt, fvs)
    if n != 1, do: throw({:error, {:children_count, n}})
    fpos = elem_table_ref(bin, base, 0)
    {efvt, efvs} = vtable(bin, fpos)
    name = string_at(bin, field_pos(bin, fpos, efvt, efvs, 0))
    nullable = scalar_u8(bin, fpos, efvt, efvs, 1) != 0
    tag = scalar_u8(bin, fpos, efvt, efvs, 2)
    ty_ref = field_pos(bin, fpos, efvt, efvs, 3)
    elem = decode_type(bin, ty_ref, tag, fpos, efvt, efvs, depth - 1)
    {{:list, elem, nullable}, name}
  end

  defp fsl_type(bin, tref, vt, vs, fref, fvt, fvs, depth) do
    n = scalar_i32(bin, tref, vt, vs, 0)
    {base, cnt} = children_of(bin, tref, vt, vs, fref, fvt, fvs)
    if cnt != 1, do: throw({:error, {:children_count, cnt}})
    fpos = elem_table_ref(bin, base, 0)
    {efvt, efvs} = vtable(bin, fpos)
    tag = scalar_u8(bin, fpos, efvt, efvs, 2)
    ty_ref = field_pos(bin, fpos, efvt, efvs, 3)
    elem = decode_type(bin, ty_ref, tag, fpos, efvt, efvs, depth - 1)
    {:fixed_size_list, elem, n}
  end

  defp struct_type(bin, tref, vt, vs, fref, fvt, fvs, depth) do
    {base, cnt} = children_of(bin, tref, vt, vs, fref, fvt, fvs)
    children =
      0..(cnt - 1)
      |> Enum.map(fn i ->
        fpos = elem_table_ref(bin, base, i)
        {cvt, cvs} = vtable(bin, fpos)
        decode_field(bin, fpos, cvt, cvs, depth - 1)
      end)

    {:struct, children}
  end

  defp map_type(bin, tref, vt, vs, fref, fvt, fvs, depth) do
    sorted = scalar_u8(bin, tref, vt, vs, 0) != 0
    {base, cnt} = children_of(bin, tref, vt, vs, fref, fvt, fvs)
    if cnt != 1, do: throw({:error, {:children_count, cnt}})
    entries_ref = elem_table_ref(bin, base, 0)
    {evt, evs} = vtable(bin, entries_ref)
    ent_name = string_at(bin, field_pos(bin, entries_ref, evt, evs, 0))
    ent_nullable = scalar_u8(bin, entries_ref, evt, evs, 1) != 0
    ent_ty_ref = field_pos(bin, entries_ref, evt, evs, 3)
    entries = decode_type(bin, ent_ty_ref, 13, entries_ref, evt, evs, depth - 1)
    {key_ty, value_ty} =
      case entries do
        {:struct, [kf, vf]} -> {elem_type_of(kf), elem_type_of(vf)}
        _ -> throw({:error, :map_entries_shape})
      end
    {{:map, key_ty, value_ty, sorted}, ent_name}
  end

  defp elem_type_of(%Schema.Field{type: t}), do: t


@doc """
  Encode a schema message: Message{version: 4 (V5), header_type: 1,
  header: Schema, bodyLength: 0}; schema custom_metadata carries
  `smalt:schema_id`. A direct port of the cgap-arrow flatbuf.rs backwards
  builder (off-from-end offsets; the Rust emitter is court-verified).
  """
@spec encode(Schema.t()) :: binary()
  def encode(%Schema{} = schema) do
    {root_off, st} = enc_schema(schema)
    {chunks, used} = st
    root_off = root_off
    # finish: push ident then root; root value = tref index from region
    # start = U_f - off(tref) where U_f = used() after ident push.
    {chunks1, used1} = push(chunks, used, @ident)
    u_f = used1
    root_val = u_f + 4 - root_off
    {chunks2, _} = push(chunks1, used1, <<root_val::32-little>>)
    chunks2 |> List.flatten() |> IO.iodata_to_binary()
  end

  # ---- backwards builder (Rust port) ----
  defp push(chunks, used, bytes) do
    {[[bytes] | chunks], used + byte_size(bytes)}
  end

  defp push_aligned(st, bytes) do
    {chunks, used} = st
    pad = rem(8 - rem(used, 8), 8)
    {c1, u1} = push(chunks, used, :binary.copy(<<0>>, pad))
    {b, u2, st2} = push2(c1, u1, bytes)
    {b, u2, st2}
  end

  defp push2(chunks, used, bytes), do: {bytes, used + byte_size(bytes), {[[bytes] | chunks], used + byte_size(bytes)}}
  defp push2(st, bytes) do
    {chunks, used} = st
    {bytes, used + byte_size(bytes), {[[bytes] | chunks], used + byte_size(bytes)}}
  end

  defp b_string(st, s) do
    {bytes, u1, {c, u}} = push2(st, <<0>>)
    {sbytes, u2, {c1, u2b}} = push_aligned({c, u1}, s)
    {_, u3, st3} = push2({c1, u2b}, <<byte_size(s)::32-little>>)
    {u3, st3}
  end

  defp b_vec(st, elem_offs) do
    {chunks, used} = st
    pad = rem(8 - rem(used, 8), 8)
    {_, u1, {c1, _}} = push2(st, zeros(pad))
    vec_off = u1 + 4 + 4 * length(elem_offs)
    rels =
      for {e, i} <- Enum.with_index(elem_offs) do
        {i, vec_off - 4 * (i + 1) - e}
      end
    {rel_bytes, u2, st2} =
      Enum.reduce(Enum.reverse(rels), {c1, u1}, fn {_i, rel}, stx ->
        push2(stx, <<rel::32-little>>)
      end)
    _ = rel_bytes
    {_, u3, st3} = push2(st2, <<length(elem_offs)::32-little>>)
    {u3, st3}
  end

  defp b_table(st, slots) do
    ordered = slots |> Enum.reject(fn {_, v} -> v == {:off, 0} end) |> Enum.sort_by(fn {fid, _} -> -fid end)
    n = length(ordered)
    max_id = ordered |> Enum.map(fn {fid, _} -> fid end) |> Enum.max(fn -> 0 end)
    # Pure pass 1: slot positions (pad depends only on running used).
    {slot_rows, used_end} =
      Enum.map_reduce(ordered, used_of(st), fn {fid, v}, u ->
        bytes = slot_bytes_for(v)
        sz = byte_size(bytes)
        {{fid, u + sz, bytes, 0}, u + sz}
      end)
    region_len = 8 + vt_bytes - 4 + pad_vt + Enum.sum(Enum.map(slot_rows, fn {_, _, bytes, pad} -> pad + byte_size(bytes) end))
    # Forward geometry rels: rel = (region end off - block offset) - elem off.
    slot_region =
      ordered
      |> Enum.map(fn {fid, v} ->
        {_, _, _, pad} = Enum.find(slot_rows, fn {f, _, _, _} -> f == fid end)
        case v do
          {:off, e} when is_integer(e) ->
            before =
              ordered
              |> Enum.take_while(fn {f2, _} -> f2 > fid end)
              |> Enum.map(fn {f2, _} ->
                {_, _, bytes, pad2} = Enum.find(slot_rows, fn {f3, _, _, _} -> f3 == f2 end)
                pad2 + byte_size(bytes)
              end)
              |> Enum.sum()

            block_off = 8 + vt_bytes - 4 + pad_vt + before + pad
            [zeros(pad), <<(used_of(st) + region_len - block_off - e)::32-little>>]
          {:u8, x} -> [zeros(pad), <<x>>]
          {:i16, x} -> [zeros(pad), <<x::16-little>>]
          {:i32, x} -> [zeros(pad), <<x::32-little>>]
          {:i64, x} -> [zeros(pad), <<x::64-little>>]
        end
      end)
    vt_bytes = 4 + 2 * n
    pad_vt = 0
    # Forward geometry: voff(id) = prefix + sum of block sizes of the slots
    # placed BEFORE id in the forward region (desc-id order) + its pad.
    prefix = 8 + vt_bytes - 4 + pad_vt
    voffs =
      for i <- 0..max_id do
        before =
          ordered
          |> Enum.take_while(fn {fid, _} -> fid > i end)
          |> Enum.map(fn {fid, _} ->
            {_, _, _, pad} = Enum.find(slot_rows, fn {f, _, _, _} -> f == fid end)
            _ = pad
            case Enum.find(slot_rows, fn {f, _, _, _} -> f == fid end) do
              {_, _, bytes, _} -> byte_size(bytes) + 0
            end
          end)
          |> Enum.sum()

        case Enum.find(slot_rows, fn {f, _, _, _} -> f == i end) do
          nil -> 0
          {_, off_start, _, pad} ->
            _ = off_start
            before + pad + prefix
        end
      end
    voff_bin = Enum.map(voffs, fn v -> <<v::16-little>> end)
    region =
      IO.iodata_to_binary([
        <<-4::32-little>>,
        <<(4 + 2 * n)::16-little, 0::16>>,
        voff_bin,
        zeros(pad_vt),
        slot_region
      ])
    tref = used_of(st) + IO.iodata_length(region)
    {_, tref, st2} = push2(st, region)
    {tref, st2}
  end

  defp slot_bytes_for({:off, _}), do: <<0::32-little>>
  defp slot_bytes_for({:u8, v}), do: <<v>>
  defp slot_bytes_for({:i16, v}), do: <<v::16-little>>
  defp slot_bytes_for({:i32, v}), do: <<v::32-little>>
  defp slot_bytes_for({:i64, v}), do: <<v::64-little>>

  defp zeros(0), do: <<>>
  defp zeros(n), do: :binary.copy(<<0>>, n)

  defp slot_data({:off, 0}, st), do: {<<>>, elem(st, 1), st}

  defp slot_data({:off, off}, st) do
    push_aligned(st, <<0::32-little>>)
  end

  defp slot_data({:u8, v}, st), do: push_aligned(st, <<v>>)

  defp slot_data({:i16, v}, st), do: push_aligned(st, <<v::16-little>>)

  defp slot_data({:i32, v}, st), do: push_aligned(st, <<v::32-little>>)

  defp slot_data({:i64, v}, st), do: push_aligned(st, <<v::64-little>>)

  defp slot_value_bytes({:off, 0}), do: <<>>
  defp slot_value_bytes({:off, _}), do: <<0::32-little>>
  defp slot_value_bytes({:u8, v}), do: <<v>>
  defp slot_value_bytes({:i16, v}), do: <<v::16-little>>
  defp slot_value_bytes({:i32, v}), do: <<v::32-little>>
  defp slot_value_bytes({:i64, v}), do: <<v::64-little>>

  defp chunks_of({c, _u}), do: c
  defp used_of({_c, u}), do: u

  defp used({_chunks, u}), do: u

  # ---- schema/field/type graph (backwards) ----
  defp enc_schema(%Schema{} = schema) do
    st0 = {[], 0}
    {field_offs, st1} =
      Enum.map_reduce(schema.fields, st0, fn f, st -> enc_field(f, st) end)

    {vec_off, st2} = b_vec(st1, field_offs)
    meta_pairs = [{"smalt:schema_id", to_string(schema.schema_id)}]
    {kv_off, st3} = enc_kv_vec(meta_pairs, st2)
    {schema_off, st4} =
      b_table(st3, [{0, {:i16, 0}}, {1, {:off, vec_off}}, {2, {:off, kv_off}}])
    {msg_off, st5} =
      b_table(st4, [
        {0, {:i16, @version_v5}},
        {1, {:u8, 1}},
        {2, {:off, schema_off}},
        {3, {:i64, 0}}
      ])
    {msg_off, st5}
  end

  defp enc_kv_vec([], st), do: {0, st}
  defp enc_kv_vec(pairs, st) do
    {kv_offs, st1} = Enum.map_reduce(pairs, st, fn {k, v}, st ->
      {k_off, st1} = b_string(st, k)
      {v_off, st2} = b_string(st1, v)
      {kv_t_off, st3} = b_table(st2, [{0, {:off, k_off}}, {1, {:off, v_off}}])
      {kv_t_off, st3}
    end)
    b_vec(st1, kv_offs)
  end

  defp enc_field(f, st) do
    {name_off, st1} = b_string(st, f.name)
    {ty_off, dict_off, st2} = enc_type(f.type, st1)
    md = f.metadata || %{}
    {kv_off, st3} = enc_kv_vec(Enum.to_list(md), st2)
    base_slots = [
      {0, {:off, name_off}},
      {1, {:u8, bool_byte(f.nullable)}},
      {2, {:u8, field_tag(f.type)}},
      {3, {:off, ty_off}}
    ]
    slots =
      if dict_off != 0 do
        base_slots ++ [{4, {:off, dict_off}}]
      else
        base_slots
      end
    slots =
      if kv_off != 0 do
        slots ++ [{6, {:off, kv_off}}]
      else
        slots
      end
    b_table(st3, slots)
  end

  defp enc_type({:dictionary, idx, value}, st) do
    {v_ty_off, st1} = plain_ty(value, st)
    {idx_field_off, st2} = enc_index_field(idx, st1)
    {dict_off, st3} =
      b_table(st2, [
        {0, {:i64, 0}},
        {1, {:off, idx_field_off}},
        {2, {:u8, 1}},
        {3, {:i32, index_bits(idx)}}
      ])
    {v_ty_off, dict_off, st3}
  end

  defp enc_type(ty, st) do
    {ty_off, st1} = plain_ty(ty, st)
    {ty_off, 0, st1}
  end

  defp plain_ty({:list, elem, _nl}, st) do
    {elem_f_off, st1} = enc_elem_field(elem, 1, st)
    b_table(st1, [{5, {:off, elem_f_off}}])
  end

  defp plain_ty({:fixed_size_list, elem, n}, st) do
    {elem_f_off, st1} = enc_elem_field(elem, 1, st)
    b_table(st1, [{0, {:i32, n}}, {5, {:off, elem_f_off}}])
  end

  defp plain_ty({:struct, children}, st) do
    {child_offs, st1} = Enum.map_reduce(children, st, &enc_field(&1, &2))
    {vec_off, st2} = b_vec(st1, child_offs)
    b_table(st2, [{5, {:off, vec_off}}])
  end

  defp plain_ty({:map, key, value, sorted}, st) do
    {k_ty_off, st1} = plain_ty(key, st)
    {v_ty_off, st2} = plain_ty(value, st1)
    kf_slots = [
      {0, {:off, 0}},
      {1, {:u8, 0}},
      {2, {:u8, type_tag(key)}},
      {3, {:off, k_ty_off}}
    ]
    {kf_off, st3} = b_table(st2, kf_slots)
    vf_slots = [
      {0, {:off, 0}},
      {1, {:u8, 1}},
      {2, {:u8, type_tag(value)}},
      {3, {:off, v_ty_off}}
    ]
    {vf_off, st4} = b_table(st3, vf_slots)
    {kv_vec, st5} = b_vec(st4, [kf_off, vf_off])
    {entries_f, st6} = b_table(st5, [{5, {:off, kv_vec}}])
    {entries_vec, st7} = b_vec(st6, [entries_f])
    b_table(st7, [{0, {:u8, bool_byte(sorted)}}, {5, {:off, entries_vec}}])
  end

  defp plain_ty({:timestamp, u, tz}, st) when tz != nil do
    {tz_off, st1} = b_string(st, tz)
    b_table(st1, [{0, {:i16, unit_short(u)}}, {1, {:off, tz_off}}])
  end

  defp plain_ty(ty, st) do
    case leaf_spec(ty) do
      nil -> b_table(st, [])
      spec -> b_table(st, spec_slots(spec))
    end
  end

  defp spec_slots({:table, _n, slots}), do: slots
  defp spec_slots(nil), do: []

  defp enc_elem_field(elem_type, nullable, st) do
    {ty_off, st1} = plain_ty(elem_type, st)
    b_table(st1, [
      {1, {:u8, bool_byte(nullable)}},
      {2, {:u8, type_tag(elem_type)}},
      {3, {:off, ty_off}}
    ])
  end

  defp enc_index_field(idx, st) do
    {ty_off, st1} = plain_ty(index_atom(idx), st)
    b_table(st1, [
      {1, {:u8, 0}},
      {2, {:u8, 2}},
      {3, {:off, ty_off}}
    ])
  end

  defp index_atom(:i8), do: :i8
  defp index_atom(:i16), do: :i16
  defp index_atom(:i32), do: :i32
  defp index_atom(:i64), do: :i64
  defp index_atom(:u8), do: :u8
  defp index_atom(:u16), do: :u16
  defp index_atom(:u32), do: :u32
  defp index_atom(:u64), do: :u64
 
  defp field_tag({:dictionary, _, v}), do: type_tag(v)
  defp field_tag(t), do: type_tag(t)

  defp type_tag(:bool), do: 6
  defp type_tag(t) when t in [:i8, :i16, :i32, :i64, :u8, :u16, :u32, :u64], do: 2
  defp type_tag(t) when t in [:f16, :f32, :f64], do: 3
  defp type_tag(:utf8), do: 5
  defp type_tag(:large_utf8), do: 20
  defp type_tag(:binary), do: 4
  defp type_tag(:large_binary), do: 19
  defp type_tag(:date32), do: 8
  defp type_tag(:date64), do: 8
  defp type_tag({:time, _}), do: 9
  defp type_tag({:timestamp, _, _}), do: 10
  defp type_tag({:decimal128, _, _}), do: 7
  defp type_tag({:interval, _}), do: 11
  defp type_tag({:list, _, _}), do: 12
  defp type_tag({:fixed_size_list, _, _}), do: 16
  defp type_tag({:struct, _}), do: 13
  defp type_tag({:map, _, _, _}), do: 17
  defp type_tag({:dictionary, _, _}), do: 5

  defp bool_byte(true), do: 1
  defp bool_byte(false), do: 0

  defp unit_short(:second), do: 0
  defp unit_short(:millisecond), do: 1
  defp unit_short(:microsecond), do: 2
  defp unit_short(:nanosecond), do: 3

  defp index_bits(idx), do: elem(int_of_index(idx), 1)

  defp int_of_index(:i8), do: {:int, 8, true}
  defp int_of_index(:i16), do: {:int, 16, true}
  defp int_of_index(:i32), do: {:int, 32, true}
  defp int_of_index(:i64), do: {:int, 64, true}
  defp int_of_index(:u8), do: {:int, 8, false}
  defp int_of_index(:u16), do: {:int, 16, false}
  defp int_of_index(:u32), do: {:int, 32, false}
  defp int_of_index(:u64), do: {:int, 64, false}

  defp leaf_spec(:bool), do: {:table, 0, []}
  defp leaf_spec(t) when t in [:i8, :i16, :i32, :i64], do: int_spec(t, true)
  defp leaf_spec(t) when t in [:u8, :u16, :u32, :u64], do: int_spec(t, false)
  defp leaf_spec(:f16), do: {:table, 1, [{0, {:i16, 0}}]}
  defp leaf_spec(:f32), do: {:table, 1, [{0, {:i16, 1}}]}
  defp leaf_spec(:f64), do: {:table, 1, [{0, {:i16, 2}}]}
  defp leaf_spec(t) when t in [:utf8, :large_utf8, :binary, :large_binary] do
    {:table, 0, []}
  end

  defp leaf_spec(:date32), do: {:table, 1, [{0, {:i16, 0}}]}
  defp leaf_spec(:date64), do: {:table, 1, [{0, {:i16, 1}}]}
  defp leaf_spec({:time, u}) when u in [:second, :millisecond] do
    {:table, 2, [{0, {:i16, unit_short(u)}}, {1, {:i32, 32}}]}
  end

  defp leaf_spec({:time, u}) do
    {:table, 2, [{0, {:i16, unit_short(u)}}, {1, {:i32, 64}}]}
  end

  defp leaf_spec({:timestamp, u, nil}) do
    {:table, 1, [{0, {:i16, unit_short(u)}}]}
  end

  defp leaf_spec({:decimal128, p, s}) do
    {:table, 3, [{0, {:i32, p}}, {1, {:i32, s}}, {2, {:i32, 128}}]}
  end

  defp leaf_spec({:interval, k}) do
    {:table, 1, [{0, {:i16, interval_short(k)}}]}
  end

  defp leaf_spec(_), do: nil

  defp int_spec(t, signed) do
    bits = t |> Atom.to_string() |> String.slice(1, 2) |> String.to_integer()
    {:table, 2, [{0, {:i32, bits}}, {1, {:u8, bool_byte(signed)}}]}
  end

  defp interval_short(:year_month), do: 0
  defp interval_short(:day_time), do: 1
  defp interval_short(:month_day_nano), do: 2

end
